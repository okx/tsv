// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    PoolKey,
    Currency,
    IHooks
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PermissionedPositionManager} from "tsv-v1/vendor/permissionedPools/PermissionedPositionManager.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {ITokenApproveProxy} from "tsv-v1/interfaces/ITokenApproveProxy.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

contract TSVLPInitializationTest is Test {
    TSVLPManagerV1 private lp;
    address private factory;
    address private manager;
    address private registry;
    PoolKey private key;

    function setUp() public {
        factory = makeAddr("factory");
        manager = makeAddr("manager");
        registry = makeAddr("registry");
        address approveProxy = makeAddr("approve-proxy");
        vm.etch(factory, hex"00");
        vm.etch(manager, hex"00");
        vm.etch(registry, hex"00");
        vm.etch(approveProxy, hex"00");
        vm.mockCall(approveProxy, abi.encodeCall(ITokenApproveProxy.tokenApprove, ()), abi.encode(approveProxy));
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
        TSVLPManagerV1 implementation = new TSVLPManagerV1(
            IPoolManager(manager),
            IAllowanceTransfer(address(0)),
            0,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(factory),
            100_000,
            ITSVPermissionedRegistry(registry),
            ITokenApproveProxy(approveProxy)
        );
        lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), ITSVPermissionedRegistry(registry)))
                    )
                ))
        );
        lp.grantRole(lp.POOL_CREATOR_ROLE(), address(this));
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, IHooks(address(3)));
        _setVerified(key.currency0, address(0));
        _setVerified(key.currency1, address(0));
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.registerPool, (key)), abi.encode(bytes32(0)));
        vm.mockCall(manager, abi.encodeCall(IPoolManager.initialize, (key, uint160(1 << 96))), abi.encode(int24(0)));
    }

    function testRejectsPoolWithoutVerifiedAdapterBeforeRegistration() public {
        vm.expectCall(registry, abi.encodeCall(ITSVPermissionedRegistry.registerPool, (key)), uint64(0));
        vm.expectCall(manager, abi.encodeCall(IPoolManager.initialize, (key, uint160(1 << 96))), uint64(0));
        vm.expectRevert(PermissionedPositionManager.NoVerifiedAdapter.selector);
        lp.initializePool(key, uint160(1 << 96));
    }

    function testAcceptsVerifiedAdapterAsCurrency0() public {
        _setVerified(key.currency0, address(4));
        _initialize();
    }

    function testAcceptsVerifiedAdapterAsCurrency1() public {
        _setVerified(key.currency1, address(4));
        _initialize();
    }

    function _initialize() private {
        vm.expectCall(registry, abi.encodeCall(ITSVPermissionedRegistry.registerPool, (key)));
        vm.expectCall(manager, abi.encodeCall(IPoolManager.initialize, (key, uint160(1 << 96))));
        assertEq(lp.initializePool(key, uint160(1 << 96)), 0);
    }

    function _setVerified(Currency currency, address underlying) private {
        vm.mockCall(
            factory,
            abi.encodeCall(IPermissionsAdapterFactory.verifiedPermissionsAdapterOf, (Currency.unwrap(currency))),
            abi.encode(underlying)
        );
    }
}
