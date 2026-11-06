// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Currency as CoreCurrency} from "v4-core/types/Currency.sol";
import {PoolKey as CorePoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks as CoreHooks} from "v4-core/interfaces/IHooks.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {Currency, PoolKey as LPManagerPoolKey, IHooks, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {QuoteTokenRecord, UnderlyingRecord, SecurityRecord} from "tsv-v1/types/TSVTypes.sol";

/// @notice Registers and initializes a configured list of TSV W/Q pools atomically, one pool per transaction.
/// @dev The current LP Manager ABI has no reasonCode parameter for initializePool.
contract InitializeTSVPools is Script {
    using PoolIdLibrary for CorePoolKey;

    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address creator = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        TSVLPManagerV1 lpManager = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        uint256 count = vm.envUint("TSV_POOL_COUNT");

        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");
        require(address(lpManager).code.length != 0, "TSV_LP_MANAGER has no code");
        require(address(lpManager.registry()) == address(registry), "LP Manager is bound to another Registry");
        require(count != 0, "TSV_POOL_COUNT is zero");
        require(registry.hasRole(registry.POOL_CREATOR_ROLE(), creator), "signer lacks POOL_CREATOR_ROLE");
        require(!registry.isPaused(), "TSV Registry is paused");

        CorePoolKey[] memory keys = new CorePoolKey[](count);
        uint160[] memory prices = new uint160[](count);
        bytes32[] memory poolIds = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            address currency0 = vm.envAddress(string.concat("TSV_POOL_CURRENCY0_", suffix));
            address currency1 = vm.envAddress(string.concat("TSV_POOL_CURRENCY1_", suffix));
            uint256 feeRaw = vm.envUint(string.concat("TSV_POOL_FEE_", suffix));
            uint256 tickSpacingRaw = vm.envUint(string.concat("TSV_POOL_TICK_SPACING_", suffix));
            address hook = vm.envAddress(string.concat("TSV_POOL_HOOK_", suffix));
            uint256 sqrtPriceRaw = vm.envUint(string.concat("TSV_POOL_SQRT_PRICE_X96_", suffix));

            require(currency0 != address(0) && currency0 < currency1, "pool currencies must be sorted and nonzero");
            require(feeRaw < 1_000_000 && feeRaw <= type(uint24).max, "invalid pool fee");
            require(tickSpacingRaw > 0 && tickSpacingRaw <= 32767, "invalid pool tick spacing");
            require(hook == registry.hook() && hook.code.length != 0, "pool hook does not match Registry");
            require(sqrtPriceRaw > 0 && sqrtPriceRaw <= type(uint160).max, "invalid initial sqrt price");

            address underlying0 = registry.getCurrencyUnderlying(currency0);
            address underlying1 = registry.getCurrencyUnderlying(currency1);
            require((underlying0 == address(0)) != (underlying1 == address(0)), "pool must contain exactly one W");
            address wrapped = underlying0 == address(0) ? currency1 : currency0;
            address underlying = underlying0 == address(0) ? underlying1 : underlying0;
            address quote = underlying0 == address(0) ? currency0 : currency1;

            UnderlyingRecord memory underlyingRecord = registry.getUnderlying(underlying);
            require(underlyingRecord.registered, "underlying is not enabled for new pools");
            SecurityRecord memory security = registry.getSecurity(underlyingRecord.securityId);
            require(security.listed, "stock security is not listed");
            QuoteTokenRecord memory quoteRecord = registry.getQuoteToken(quote);
            require(quoteRecord.registered, "quote token is not enabled for new pools");

            CorePoolKey memory key = CorePoolKey(
                CoreCurrency.wrap(currency0),
                CoreCurrency.wrap(currency1),
                _toUint24(feeRaw),
                _toInt24(tickSpacingRaw),
                CoreHooks(hook)
            );
            bytes32 poolId = PoolId.unwrap(key.toId());
            require(!registry.isKnownPool(poolId), "pool key is already registered");
            for (uint256 j; j < i; ++j) {
                require(poolIds[j] != poolId, "duplicate pool key in list");
            }

            // forge-lint: disable-next-line(unsafe-typecast)
            prices[i] = uint160(sqrtPriceRaw);
            keys[i] = key;
            poolIds[i] = poolId;
            console2.log("Pool ID:");
            console2.logBytes32(poolId);
            console2.log("W:", wrapped);
            console2.log("U:", underlying);
            console2.log("Q:", quote);
            console2.log("Initial sqrt price X96:", sqrtPriceRaw);
        }

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("LP Manager:", address(lpManager));
        console2.log("Pool creator:", creator);
        vm.startBroadcast(privateKey);
        for (uint256 i; i < count; ++i) {
            lpManager.initializePool(_toLPManagerKey(keys[i]), prices[i]);
        }
        vm.stopBroadcast();
    }

    function _toLPManagerKey(CorePoolKey memory key) private pure returns (LPManagerPoolKey memory) {
        return LPManagerPoolKey(
            Currency.wrap(CoreCurrency.unwrap(key.currency0)),
            Currency.wrap(CoreCurrency.unwrap(key.currency1)),
            key.fee,
            key.tickSpacing,
            IHooks(address(key.hooks))
        );
    }

    function _toUint24(uint256 value) private pure returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(value);
    }

    function _toInt24(uint256 value) private pure returns (int24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 unsignedValue = uint24(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(unsignedValue);
    }
}
