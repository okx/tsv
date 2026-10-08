// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Independently verifies hook callback caller, context, operation mode, and zero return deltas.
contract TSVLPHookCallbacksTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testDirectHookLiquidityCallbacksRequirePoolManager() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeAddLiquidity(address(lpManager), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeRemoveLiquidity(address(lpManager), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterAddLiquidity(address(lpManager), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterRemoveLiquidity(address(lpManager), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function testLiquidityHookRejectsForeignSenderAndNonemptyHookData() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(alice, key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(lpManager), key, p, hex"01");
    }

    function testHookRejectsEveryMismatchedLPContextField() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        for (uint8 i; i < 6; i++) {
            LPHookContext memory ctx = _context(1, LPOperationMode.INCREASE);
            if (i == 0) ctx.poolId = 0;
            if (i == 1) ctx.poolId = keccak256("another-pool");
            if (i == 2) ctx.salt = bytes32(uint256(999));
            if (i == 3) ctx.tickLower = -660;
            if (i == 4) ctx.tickUpper = 660;
            if (i == 5) ctx.liquidityDelta = 2;
            _mockContext(ctx);
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            vm.prank(address(manager));
            hook.beforeAddLiquidity(address(lpManager), key, p, "");
        }
        vm.clearMockedCalls();
    }

    function testHookRejectsWrongModeAndLiquiditySign() public {
        for (uint8 i; i < 4; i++) {
            int256 delta = i == 0 ? int256(0) : i == 1 ? int256(-1) : int256(1);
            LPOperationMode mode = i < 2 ? LPOperationMode.INCREASE : LPOperationMode.COLLECT;
            _mockContext(_context(delta, mode));
            IPoolManager.ModifyLiquidityParams memory p =
                IPoolManager.ModifyLiquidityParams(-600, 600, delta, bytes32(positionId));
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            vm.prank(address(manager));
            if (i < 3) hook.beforeAddLiquidity(address(lpManager), key, p, "");
            else hook.beforeRemoveLiquidity(address(lpManager), key, p, "");
        }
        _mockContext(_context(0, LPOperationMode.FORCE_EXIT));
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(
            address(lpManager), key, IPoolManager.ModifyLiquidityParams(-600, 600, 0, bytes32(positionId)), ""
        );
        vm.clearMockedCalls();
    }

    function testAfterLiquidityCallbacksReturnZeroDelta() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.prank(address(manager));
        (bytes4 selector, BalanceDelta delta) =
            hook.afterAddLiquidity(address(lpManager), key, p, BalanceDelta.wrap(1), BalanceDelta.wrap(2), "");
        assertEq(selector, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), 0);
        vm.prank(address(manager));
        (selector, delta) =
            hook.afterRemoveLiquidity(address(lpManager), key, p, BalanceDelta.wrap(1), BalanceDelta.wrap(2), "");
        assertEq(selector, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), 0);
    }

    function testHookInitializationRejectsEveryDependencyWithoutCodeAndCanRetry() public {
        TSVHookV1 isolated = TSVHookV1(address(uint160(0x7FFF)));
        _installProxy(address(isolated), address(new TSVHookV1()));
        for (uint256 i; i < 5; i++) {
            address[5] memory deps =
                [address(manager), address(registry), address(ledger), address(router), address(lpManager)];
            deps[i] = address(0);
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            isolated.initialize(address(anchor), deps[0], deps[1], deps[2], deps[3], deps[4]);
        }
        isolated.initialize(
            address(anchor), address(manager), address(registry), address(ledger), address(router), address(lpManager)
        );
        assertEq(isolated.router(), address(router));
    }

    function testInitializeHookCallbacksRejectAlreadyActivePool() public {
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(lpManager), key, uint160(1 << 96));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterInitialize(address(lpManager), key, uint160(1 << 96), 0);
    }

    function _context(int256 delta, LPOperationMode mode) internal view returns (LPHookContext memory) {
        return LPHookContext(PoolId.unwrap(key.toId()), -600, 600, mode, bytes32(positionId), delta);
    }

    function _mockContext(LPHookContext memory ctx) internal {
        vm.mockCall(address(lpManager), abi.encodeCall(TSVLPManagerV1.activeLPContext, ()), abi.encode(ctx));
    }
}
