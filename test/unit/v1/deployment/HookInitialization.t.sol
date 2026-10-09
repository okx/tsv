// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVHookV1, IActiveLPContextV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
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
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
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
        hook.initialize(address(anchor), manager, address(registry), address(this), address(this), lpManager);
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

    function testForceExitRequiresRegistrationAndBypassesOrdinaryLPAdmission() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, -1, bytes32(uint256(1)));
        LPHookContext memory ctx = LPHookContext(
            poolId, params.tickLower, params.tickUpper, LPOperationMode.FORCE_EXIT, params.salt, params.liquidityDelta
        );
        vm.mockCall(lpManager, abi.encodeCall(IActiveLPContextV1.activeLPContext, ()), abi.encode(ctx));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lpManager, key, params, "");

        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isKnownPool, (poolId)), abi.encode(true));
        assertFalse(registry.isLPAllowed(poolId));
        vm.prank(manager);
        assertEq(hook.beforeRemoveLiquidity(lpManager, key, params, ""), IHooks.beforeRemoveLiquidity.selector);
    }
}
