// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MarketAction, PauseScope, PauseMode, LPOperationMode, LPHookContext} from "tsv-v1/types/TSVTypes.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVPausesLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testEmergencyTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, false);
    }

    function testEmergencyLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, false);
    }

    function testEmergencyAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, false);
    }

    function testMarketTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, true);
    }

    function testMarketLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, true);
    }

    function testMarketAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, true);
    }

    function testMarketAndEmergencyPausesRecoverSeparatelyWithRealV4() public {
        _seedPauseTestFees();
        _submitLocalMarket(MarketAction.HALT, PauseMode.LP);
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        _submitLocalMarket(MarketAction.RESUME, PauseMode.LP);
        _assertTradingBlocked();
        _exerciseAllowedLPLifecycle();
        registry.clearEmergencyPause(id, keccak256("resume"));
        vm.prank(alice);
        positionId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
        _exerciseAllowedTrading();
    }

    function testHookIndependentlyChecksTradingAndLPPauses() public {
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, swapParams, "");
        registry.clearEmergencyPause(id, keccak256("resume"));
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.LP);
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(router), key, swapParams, "");
        assertEq(selector, IHooks.beforeSwap.selector);

        LPHookContext memory ctx = LPHookContext(
            PoolId.unwrap(key.toId()), -600, 600, LPOperationMode.INCREASE, bytes32(positionId), int256(1e18)
        );
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-600, 600, int256(1e18), bytes32(positionId));
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(lpManager), key, params, "");
        ctx.mode = LPOperationMode.COLLECT;
        ctx.liquidityDelta = 0;
        params.liquidityDelta = 0;
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(address(lpManager), key, params, "");
    }

    function testPoolInitializationRemainsAllowedDuringAllPauses() public {
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.ALL);
        _submitLocalMarket(MarketAction.HALT, PauseMode.ALL);
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("paused-price"));
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        assertTrue(registry.isKnownPool(otherPoolId));
        assertFalse(registry.isTradable(otherPoolId));
        assertFalse(registry.isLPAllowed(otherPoolId));
    }
}
