// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TSVHookV1, ITSVLPUnwindContext} from "tsv-v1/core/TSVHookV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

contract TSVHookInitializationTest is Test {
    using PoolIdLibrary for PoolKey;

    TSVHookV1 private hook;
    TSVRegistryV1 private registry;
    address private manager;
    address private lpManager;
    PoolKey private key;

    function setUp() public {
        manager = makeAddr("pool-manager");
        lpManager = makeAddr("lp-manager");
        vm.etch(manager, hex"00");
        vm.etch(lpManager, hex"00");
        vm.mockCall(lpManager, abi.encodeCall(ITSVLPUnwindContext.isUnwindActive, ()), abi.encode(false));
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook.initialize(manager, address(registry), address(this), address(this), lpManager);
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, IHooks(address(hook)));
    }

    function testBeforeInitializeKeepsCallerInitiatorAndRegistrationChecks() public {
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeInitialize(lpManager, key, uint160(1 << 96));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeInitialize(lpManager, key, uint160(1 << 96));
    }

    function testAfterInitializeDoesNotReadRegistryAgain() public {
        vm.mockCallRevert(address(registry), abi.encodeWithSelector(TSVRegistryV1.getPool.selector), "unexpected read");
        vm.prank(manager);
        assertEq(hook.afterInitialize(lpManager, key, uint160(1 << 96), 0), IHooks.afterInitialize.selector);
    }

    function testAfterInitializeStillRequiresPoolManager() public {
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterInitialize(lpManager, key, uint160(1 << 96), 0);
    }

    function testRemovalRequiresRegisteredAllowedPool() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, -1, bytes32(uint256(1)));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");

        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isKnownPool, (poolId)), abi.encode(true));
        assertFalse(registry.isLPAllowed(poolId));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");

        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(true));
        vm.prank(manager);
        assertEq(hook.beforeRemoveLiquidity(lpManager, key, params, ""), IHooks.beforeRemoveLiquidity.selector);

        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isPaused, ()), abi.encode(true));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
    }

    function _allowLP() private {
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isKnownPool, (poolId)), abi.encode(true));
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(true));
    }

    function testAuthorizedUnwindBypassesOrdinaryLPGateButNotGlobalPause() public {
        _allowLP();
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(false));
        vm.mockCall(lpManager, abi.encodeCall(ITSVLPUnwindContext.isUnwindActive, ()), abi.encode(true));
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, -1, bytes32(uint256(1)));
        vm.prank(manager);
        assertEq(hook.beforeRemoveLiquidity(lpManager, key, params, ""), IHooks.beforeRemoveLiquidity.selector);
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isPaused, ()), abi.encode(true));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
    }

    function testOrdinaryLPOnlyRequiresTrustedManagerAndRegistryPool() public {
        _allowLP();
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(uint256(7)));
        vm.startPrank(manager);
        assertEq(hook.beforeAddLiquidity(lpManager, key, params, ""), IHooks.beforeAddLiquidity.selector);
        params.liquidityDelta = -1;
        assertEq(hook.beforeRemoveLiquidity(lpManager, key, params, ""), IHooks.beforeRemoveLiquidity.selector);
        params.liquidityDelta = 0;
        assertEq(hook.beforeAddLiquidity(lpManager, key, params, ""), IHooks.beforeAddLiquidity.selector);
        assertEq(hook.beforeRemoveLiquidity(lpManager, key, params, ""), IHooks.beforeRemoveLiquidity.selector);
        vm.stopPrank();
    }

    function testLPRejectsDirectCallsAndOtherInitiators() public {
        _allowLP();
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(uint256(1)));
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeAddLiquidity(lpManager, key, params, "");
        vm.prank(manager);
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
        params.liquidityDelta = -1;
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
        vm.prank(manager);
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
    }

    function testLPRejectsUnknownOrDifferentHookKey() public {
        _allowLP();
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(uint256(1)));
        PoolKey memory other = key;
        other.fee++;
        vm.startPrank(manager);
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeAddLiquidity(lpManager, other, params, "");
        other.hooks = IHooks(address(1));
        vm.mockCall(
            address(registry),
            abi.encodeCall(TSVRegistryV1.isKnownPool, (PoolId.unwrap(other.toId()))),
            abi.encode(true)
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeAddLiquidity(lpManager, other, params, "");
        vm.stopPrank();
    }

    function testOrdinaryLPAndZeroDeltaCollectRespectPoolAndGlobalGates() public {
        _allowLP();
        bytes32 poolId = PoolId.unwrap(key.toId());
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(uint256(1)));
        for (uint256 i; i < 2; ++i) {
            vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(i == 1));
            vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isPaused, ()), abi.encode(i == 1));
            vm.startPrank(manager);
            params.liquidityDelta = 1;
            vm.expectRevert(TSVHookV1.InvalidPool.selector);
            hook.beforeAddLiquidity(lpManager, key, params, "");
            params.liquidityDelta = -1;
            vm.expectRevert(TSVHookV1.InvalidPool.selector);
            hook.beforeRemoveLiquidity(lpManager, key, params, "");
            params.liquidityDelta = 0;
            vm.expectRevert(TSVHookV1.InvalidPool.selector);
            hook.beforeAddLiquidity(lpManager, key, params, "");
            vm.expectRevert(TSVHookV1.InvalidPool.selector);
            hook.beforeRemoveLiquidity(lpManager, key, params, "");
            vm.stopPrank();
        }
    }

    function testPoolGateAppliesToEveryPositionAndAction() public {
        _allowLP();
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(false));
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, -1, bytes32(uint256(2)));
        vm.startPrank(manager);
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
        params.salt = bytes32(uint256(1));
        PoolKey memory other = key;
        other.fee++;
        vm.mockCall(
            address(registry),
            abi.encodeCall(TSVRegistryV1.isKnownPool, (PoolId.unwrap(other.toId()))),
            abi.encode(true)
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeRemoveLiquidity(lpManager, other, params, "");
        params.liquidityDelta = 0;
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
        params.liquidityDelta = 1;
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        hook.beforeAddLiquidity(lpManager, key, params, "");
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");
        params.liquidityDelta = -1;
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        hook.beforeAddLiquidity(lpManager, key, params, "");
        vm.stopPrank();
    }
}
