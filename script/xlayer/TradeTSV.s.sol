// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {SwapRequest, UnderlyingRecord, QuoteTokenRecord} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

interface IERC20XLayer {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Preflights and optionally broadcasts one exact-input TSV swap on XLayer mainnet.
/// @dev No transaction is sent unless Foundry is run with --broadcast.
contract TradeTSV is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address trader = vm.addr(privateKey);
        address routerAddress = vm.envAddress("TSV_ROUTER");
        address currency0Address = vm.envAddress("TSV_CURRENCY0");
        address currency1Address = vm.envAddress("TSV_CURRENCY1");
        address hookAddress = vm.envAddress("TSV_HOOK");
        uint256 feeRaw = vm.envUint("TSV_FEE");
        int256 tickSpacingRaw = vm.envInt("TSV_TICK_SPACING");
        bool zeroForOne = vm.envBool("TSV_ZERO_FOR_ONE");
        uint256 amountRaw = vm.envUint("TSV_AMOUNT_IN");
        uint256 minAmountOutRaw = vm.envUint("TSV_MIN_AMOUNT_OUT");
        uint256 deadlineSeconds = vm.envOr("TSV_DEADLINE_SECONDS", uint256(300));

        require(routerAddress.code.length != 0, "TSV_ROUTER has no code");
        require(currency0Address != address(0) && currency0Address < currency1Address, "pool currencies must be sorted");
        require(hookAddress != address(0) && hookAddress.code.length != 0, "TSV_HOOK has no code");
        require(feeRaw <= type(uint24).max, "TSV_FEE exceeds uint24");
        require(tickSpacingRaw > 0 && tickSpacingRaw <= type(int24).max, "invalid TSV_TICK_SPACING");
        require(amountRaw > 0 && amountRaw <= uint256(uint128(type(int128).max)), "invalid TSV_AMOUNT_IN");
        require(minAmountOutRaw > 0 && minAmountOutRaw <= type(uint128).max, "invalid TSV_MIN_AMOUNT_OUT");
        require(deadlineSeconds > 0 && deadlineSeconds <= type(uint64).max - block.timestamp, "invalid deadline");

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
        require(registry.hook() == hookAddress, "pool hook does not match registry");
        require(!registry.isPaused(), "TSV registry is paused");

        bytes32 poolId = PoolId.unwrap(key.toId());
        require(registry.isTradable(poolId), "TSV pool is not tradable");
        require(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, trader), "trader lacks TSV swap permission");

        address underlying0 = registry.getCurrencyUnderlying(currency0Address);
        address underlying1 = registry.getCurrencyUnderlying(currency1Address);
        require((underlying0 == address(0)) != (underlying1 == address(0)), "pool must contain one TSV stock currency");

        address underlying = underlying0 == address(0) ? underlying1 : underlying0;
        UnderlyingRecord memory underlyingConfig = registry.getUnderlying(underlying);
        require(underlyingConfig.registered, "stock underlying is not registered");
        require(underlyingConfig.legalShareAdapter.code.length != 0, "legal-share adapter has no code");
        uint256 expectedMultiplier =
            IDirectLegalShareAdapter(underlyingConfig.legalShareAdapter).currentMultiplier(underlying);
        require(expectedMultiplier != 0, "invalid stock multiplier");

        address inputCurrency = zeroForOne ? currency0Address : currency1Address;
        address inputUnderlying = registry.getCurrencyUnderlying(inputCurrency);
        address inputToken = inputUnderlying == address(0) ? inputCurrency : inputUnderlying;
        if (inputUnderlying == address(0)) {
            QuoteTokenRecord memory quoteConfig = registry.getQuoteToken(inputCurrency);
            require(quoteConfig.registered, "input quote token is not registered");
        }

        uint128 amountIn = uint128(amountRaw);
        require(IERC20XLayer(inputToken).balanceOf(trader) >= amountIn, "insufficient input-token balance");
        uint64 deadline = uint64(block.timestamp + deadlineSeconds);
        SwapRequest memory request = SwapRequest({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            limitAmount: uint128(minAmountOutRaw),
            deadline: deadline,
            expectedMultiplier: expectedMultiplier
        });

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Trader:", trader);
        console2.log("Router:", routerAddress);
        console2.log("Pool ID:");
        console2.logBytes32(poolId);
        console2.log("Input token:", inputToken);
        console2.log("Input amount (raw):", amountIn);
        console2.log("Minimum output (raw):", minAmountOutRaw);
        console2.log("Expected stock multiplier:", expectedMultiplier);
        console2.log("Deadline:", deadline);

        vm.startBroadcast(privateKey);
        uint256 currentAllowance = IERC20XLayer(inputToken).allowance(trader, routerAddress);
        if (currentAllowance < amountIn) {
            if (currentAllowance != 0) _approve(inputToken, routerAddress, 0);
            _approve(inputToken, routerAddress, amountIn);
        }
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        vm.stopBroadcast();

        console2.log("Actual input (raw):", actualIn);
        console2.log("Actual output (raw):", actualOut);
        (uint160 postSwapSqrtPriceX96,,,) = StateLibrary.getSlot0(router.poolManager(), PoolId.wrap(poolId));
        console2.log("Post-swap sqrtPriceX96:", uint256(postSwapSqrtPriceX96));
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool success, bytes memory result) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(success, "token approval call failed");
        require(result.length == 0 || abi.decode(result, (bool)), "token approval returned false");
    }
}
