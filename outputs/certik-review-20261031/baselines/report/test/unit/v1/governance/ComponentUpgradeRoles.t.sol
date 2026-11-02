// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";

contract TSVComponentUpgradeRolesTest is Test {
    TSVRegistryV1 private registry;
    TSVHookV1 private hook;
    TSVVolumeLedgerV1 private ledger;
    TSVSwapRouterV1 private router;
    PermissionsAdapterFactory private factory;
    address[3] private components;
    address[3] private implementations;
    bytes[3] private initialization;

    function setUp() public {
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        factory = new PermissionsAdapterFactory(address(this));
        implementations = _implementations();
        initialization[1] = abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry)));
        ledger = TSVVolumeLedgerV1(address(new TSVERC1967Proxy(implementations[1], initialization[1])));
        initialization[2] = abi.encodeCall(TSVSwapRouterV1.initialize, (address(this), address(registry)));
        router = TSVSwapRouterV1(address(new TSVERC1967Proxy(implementations[2], initialization[2])));
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(implementations[0])))
        );
        initialization[0] = abi.encodeCall(
            TSVHookV1.initialize, (address(this), address(registry), address(ledger), address(router), address(this))
        );
        (bool ok,) = address(hook).call(initialization[0]);
        assertTrue(ok);
        components = [address(hook), address(ledger), address(router)];
    }

    function testRegistryUpgradeGrantAndRevocationApplyToHookLedgerAndRouter() public {
        address operator = makeAddr("upgrade-operator");
        bytes32 role = registry.UPGRADE_ADMIN_ROLE();
        registry.grantRole(registry.HALT_REPORTER_ROLE(), operator);
        address[3] memory next = _implementations();
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert(_unauthorized(i));
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
        }
        registry.grantRole(role, operator);
        registry.revokeRole(role, address(this));
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert(_unauthorized(i));
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(next[i], "");
            assertEq(TSVERC1967Proxy(payable(components[i])).tsvImplementation(), next[i]);
        }
        assertEq(address(hook.registry()), address(registry));
        assertEq(address(hook.ledger()), address(ledger));
        assertEq(hook.router(), address(router));
        assertEq(address(ledger.registry()), address(registry));
        assertEq(address(router.registry()), address(registry));
        registry.revokeRole(role, operator);
        for (uint256 i; i < components.length; ++i) {
            vm.expectRevert(_unauthorized(i));
            vm.prank(operator);
            UUPSUpgradeable(components[i]).upgradeToAndCall(implementations[i], "");
        }
    }

    function testLedgerUpgradePreservesQuotaUsageAndRegistry() public {
        bytes32 security = keccak256("upgrade-security");
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        ledger.setQuota(security, 100e18, bytes32("TEST"));
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](1);
        values[0] = TSVVolumeLedgerV1.DailyQuota(20738, 40e18);
        ledger.setUsedWad(security, values, bytes32("TEST"));
        ledger.upgradeToAndCall(address(new TSVVolumeLedgerV1()), "");
        assertEq(address(ledger.registry()), address(registry));
        assertEq(ledger.Quota(security), 100e18);
        assertEq(ledger.usedWad(security, 20738), 40e18);
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

    function testImplementationsAndProxiesCannotBeInitializedAgain() public {
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

    function testRouterAdapterConfigurationTracksRegistryAdmin() public {
        address nextAdmin = makeAddr("next-admin");
        registry.grantRole(bytes32(0), nextAdmin);
        registry.revokeRole(bytes32(0), address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        router.setAdapterAllowed(address(ledger), true);
        vm.prank(nextAdmin);
        router.setAdapterAllowed(address(ledger), true);
        assertTrue(router.isAdapterAllowed(address(ledger)));
        vm.prank(nextAdmin);
        router.setAdapterAllowed(address(ledger), false);
        assertFalse(router.isAdapterAllowed(address(ledger)));
    }

    function testRouterUpgradeRejectsChangedImmutableDependencies() public {
        PermissionsAdapterFactory changedFactory = new PermissionsAdapterFactory(address(this));
        address next = address(new TSVSwapRouterV1(address(this), address(changedFactory)));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(next, "");
        changedFactory = new PermissionsAdapterFactory(address(ledger));
        next = address(new TSVSwapRouterV1(address(ledger), address(changedFactory)));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(next, "");
        assertEq(TSVERC1967Proxy(payable(address(router))).tsvImplementation(), implementations[2]);
    }

    function _implementations() private returns (address[3] memory) {
        return [
            address(new TSVHookV1()),
            address(new TSVVolumeLedgerV1()),
            address(new TSVSwapRouterV1(address(this), address(factory)))
        ];
    }

    function _unauthorized(uint256 i) private pure returns (bytes4) {
        return i == 1 ? TSVVolumeLedgerV1.Unauthorized.selector : TSVHookV1.UnauthorizedUpgrade.selector;
    }
}
