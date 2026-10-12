// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";

contract TSVComponentUpgradeRolesTest is Test {
    TSVRegistryV1 private registry;
    TSVHookV1 private hook;
    TSVSwapRouterV1 private router;
    PermissionsAdapterFactory private factory;
    TSVDataInboxV1 private inbox;
    TSVVolumeLedgerV1 private ledger;
    address[4] private components;
    address[4] private implementations;
    bytes[4] private initialization;

    function setUp() public {
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        factory = new PermissionsAdapterFactory(address(this));
        implementations = [
            address(new TSVHookV1()),
            address(new TSVDataInboxV1()),
            address(new TSVVolumeLedgerV1()),
            address(new TSVSwapRouterV1(address(this), address(factory)))
        ];
        initialization[2] = abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), uint32(14_400)));
        ledger = TSVVolumeLedgerV1(address(new TSVERC1967Proxy(implementations[2], initialization[2])));
        initialization[1] = abi.encodeCall(TSVDataInboxV1.initialize, (address(registry), address(ledger)));
        inbox = TSVDataInboxV1(address(new TSVERC1967Proxy(implementations[1], initialization[1])));
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(implementations[0])))
        );
        initialization[0] = abi.encodeCall(
            TSVHookV1.initialize, (address(this), address(registry), address(ledger), address(this), address(this))
        );
        (bool ok,) = address(hook).call(initialization[0]);
        assertTrue(ok);
        initialization[3] = abi.encodeCall(TSVSwapRouterV1.initialize, (address(this), address(registry)));
        router = TSVSwapRouterV1(address(new TSVERC1967Proxy(implementations[3], initialization[3])));
        components = [address(hook), address(inbox), address(ledger), address(router)];
    }

    function testRegistryUpgradeGrantAndRevocationApplyToEveryComponent() public {
        address operator = makeAddr("upgrade-operator");
        bytes32 role = registry.UPGRADE_ADMIN_ROLE();
        registry.grantRole(registry.HALT_REPORTER_ROLE(), operator);
        address[4] memory next = [
            address(new TSVHookV1()),
            address(new TSVDataInboxV1()),
            address(new TSVVolumeLedgerV1()),
            address(new TSVSwapRouterV1(address(this), address(factory)))
        ];
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert(TSVHookV1.UnauthorizedUpgrade.selector);
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
        }
        registry.grantRole(role, operator);
        registry.revokeRole(role, address(this));
        for (uint256 i; i < components.length; ++i) {
            // Registry DEFAULT_ADMIN_ROLE alone does not bypass upgrade authorization.
            vm.expectRevert(TSVHookV1.UnauthorizedUpgrade.selector);
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
            assertEq(TSVERC1967Proxy(payable(components[i])).tsvImplementation(), next[i]);
        }
        assertEq(address(hook.registry()), address(registry));
        assertEq(address(hook.ledger()), address(ledger));
        assertEq(address(hook.poolManager()), address(this));
        assertEq(address(inbox.registry()), address(registry));
        assertEq(address(inbox.ledger()), address(ledger));
        assertEq(address(ledger.registry()), address(registry));
        assertEq(ledger.initialDayStartOffsetSeconds(), 14_400);
        assertEq(address(router.registry()), address(registry));
        assertEq(address(router.poolManager()), address(this));
        assertEq(address(router.PERMISSIONS_ADAPTER_FACTORY()), address(factory));
        registry.revokeRole(role, operator);
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert(TSVHookV1.UnauthorizedUpgrade.selector);
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(implementations[i], "");
        }
    }

    function testComponentsDoNotExposeLocalAccessControl() public {
        bytes32 role = registry.UPGRADE_ADMIN_ROLE();
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert();
            IAccessControl(components[i]).grantRole(role, address(this));
            (bool ok,) = components[i].staticcall(abi.encodeCall(IAccessControl.hasRole, (bytes32(0), address(this))));
            assertFalse(ok);
        }
    }

    function testImplementationAndProxyInitializationRemainLocked() public {
        for (uint256 i; i < components.length; ++i) {
            (bool ok, bytes memory reason) = implementations[i].call(initialization[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
            (ok, reason) = components[i].call(initialization[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
            vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
            UUPSUpgradeable(implementations[i]).upgradeToAndCall(implementations[i], "");
            vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
            UUPSUpgradeable(components[i]).proxiableUUID();
        }
    }

    function testLedgerConfigurationTracksRegistryDefaultAdmin() public {
        address nextAdmin = makeAddr("next-admin");
        registry.grantRole(bytes32(0), nextAdmin);
        registry.revokeRole(bytes32(0), address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        ledger.bindWriters(address(hook), address(inbox));
        vm.prank(nextAdmin);
        ledger.bindWriters(address(hook), address(inbox));
        assertEq(ledger.hook(), address(hook));
        assertEq(ledger.dataInbox(), address(inbox));
    }

    function testRouterAdapterConfigurationTracksRegistryAdmin() public {
        address nextAdmin = makeAddr("router-admin");
        registry.grantRole(bytes32(0), nextAdmin);
        registry.revokeRole(bytes32(0), address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        router.setAdapterAllowed(address(inbox), true);
        vm.prank(nextAdmin);
        router.setAdapterAllowed(address(inbox), true);
        assertTrue(router.isAdapterAllowed(address(inbox)));
        vm.prank(nextAdmin);
        router.setAdapterAllowed(address(inbox), false);
        assertFalse(router.isAdapterAllowed(address(inbox)));
    }

    function testRouterUpgradeStillRejectsChangedImmutableDependencies() public {
        PermissionsAdapterFactory otherFactory = new PermissionsAdapterFactory(address(this));
        TSVSwapRouterV1 changedFactory = new TSVSwapRouterV1(address(this), address(otherFactory));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(changedFactory), "");
        PermissionsAdapterFactory otherManagerFactory = new PermissionsAdapterFactory(address(ledger));
        TSVSwapRouterV1 changedManager = new TSVSwapRouterV1(address(ledger), address(otherManagerFactory));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(changedManager), "");
        assertEq(TSVERC1967Proxy(payable(address(router))).tsvImplementation(), implementations[3]);
    }
}
