// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {V1RegistryUpgradeMock} from "../../../helpers/v1/DirectUpgradeMock.sol";

/// @dev TSVDirectUpgradeTest scenarios; inherited fixtures contain no test functions.
contract TSVDirectUpgradeTest is GovernanceFixture {
    function testUpgradeInitializationFailureRollsBackImplementationAndStorage() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address oldImplementation = proxy.tsvImplementation();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        vm.expectRevert(V1RegistryUpgradeMock.UpgradeInitFailed.selector);
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, true)));
        assertEq(proxy.tsvImplementation(), oldImplementation);
        assertFalse(registry.emergencyPauseEnable());
        assertTrue(registry.hasRole(0, address(this)));
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (99, false)));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 99);
    }

    function testUnrelatedRolesCannotUpgrade() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        TSVRegistryV1 next = new TSVRegistryV1();
        address operator = makeAddr("operator");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), operator);
        address[4] memory callers = [guardian, council, operator, makeAddr("outsider")];
        address oldImplementation = proxy.tsvImplementation();
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
            registry.upgradeToAndCall(address(next), "");
            assertEq(proxy.tsvImplementation(), oldImplementation);
        }
    }

    function testInvalidImplementationDoesNotChangeProxy() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address oldImplementation = proxy.tsvImplementation();
        vm.expectRevert();
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(this), "");
        assertEq(proxy.tsvImplementation(), oldImplementation);
        vm.expectRevert();
        TSVRegistryV1(address(proxy)).upgradeToAndCall(makeAddr("no-code"), "");
        assertEq(proxy.tsvImplementation(), oldImplementation);
    }

    function testUpgradeAdminCanUpgradeAndInitializeInOneCall() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        uint256 timestamp = block.timestamp;
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, false)));
        assertEq(proxy.tsvImplementation(), address(next));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 42);
        assertFalse(registry.emergencyPauseEnable());
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
        assertEq(block.timestamp, timestamp);
    }

    function testUpgradeRoleIsIndependentOfDefaultAdminAndRevocationIsImmediate() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        bytes32 role = registry.UPGRADE_ADMIN_ROLE();
        address operator = makeAddr("upgrade-admin");
        registry.grantRole(role, operator);
        registry.revokeRole(role, address(this));
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        registry.upgradeToAndCall(address(next), "");
        vm.prank(operator);
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (7, false)));
        assertEq(proxy.tsvImplementation(), address(next));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 7);
        registry.revokeRole(role, operator);
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        vm.prank(operator);
        registry.upgradeToAndCall(address(next), "");
    }
}
