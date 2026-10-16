// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {UnderlyingRecord} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @notice Read-only XLayer preflight for a TSV V4 pool.
contract InspectTSV is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external view {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        address routerAddress = vm.envAddress("TSV_ROUTER");
        address currency0Address = vm.envAddress("TSV_CURRENCY0");
        address currency1Address = vm.envAddress("TSV_CURRENCY1");
        address hookAddress = vm.envAddress("TSV_HOOK");
        uint256 feeRaw = vm.envUint("TSV_FEE");
        int256 tickSpacingRaw = vm.envInt("TSV_TICK_SPACING");

        require(routerAddress.code.length != 0, "TSV_ROUTER has no code");
        require(currency0Address != address(0) && currency0Address < currency1Address, "pool currencies must be sorted");
        require(hookAddress != address(0) && hookAddress.code.length != 0, "TSV_HOOK has no code");
        require(feeRaw <= type(uint24).max, "TSV_FEE exceeds uint24");
        require(tickSpacingRaw > 0 && tickSpacingRaw <= type(int24).max, "invalid TSV_TICK_SPACING");

        PoolKey memory key = PoolKey(
            Currency.wrap(currency0Address),
            Currency.wrap(currency1Address),
            uint24(feeRaw),
            int24(tickSpacingRaw),
            IHooks(hookAddress)
        );
        TSVSwapRouterV1 router = TSVSwapRouterV1(routerAddress);
        TSVRegistryV1 registry = router.registry();
        require(address(registry).code.length != 0, "router registry has no code");

        bytes32 poolId = PoolId.unwrap(key.toId());
        address underlying0 = registry.getCurrencyUnderlying(currency0Address);
        address underlying1 = registry.getCurrencyUnderlying(currency1Address);
        require((underlying0 == address(0)) != (underlying1 == address(0)), "pool must contain one TSV stock currency");
        address underlying = underlying0 == address(0) ? underlying1 : underlying0;
        UnderlyingRecord memory underlyingConfig = registry.getUnderlying(underlying);
        uint256 multiplier;
        if (underlyingConfig.legalShareAdapter.code.length != 0) {
            multiplier = IDirectLegalShareAdapter(underlyingConfig.legalShareAdapter).currentMultiplier(underlying);
        }

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Router:", routerAddress);
        console2.log("Registry:", address(registry));
        console2.log("Pool ID:");
        console2.logBytes32(poolId);
        console2.log("Hook matches registry:", registry.hook() == hookAddress);
        console2.log("Registry paused:", registry.isPaused());
        console2.log("Pool tradable:", registry.isTradable(poolId));
        console2.log("Stock currency:", underlying0 == address(0) ? currency1Address : currency0Address);
        console2.log("Underlying token:", underlying);
        console2.log("Legal-share adapter:", underlyingConfig.legalShareAdapter);
        console2.log("Current multiplier:", multiplier);
    }
}
