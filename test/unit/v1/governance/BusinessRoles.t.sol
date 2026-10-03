// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {GovernedRoleHarness} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev TSVBusinessRolesTest scenarios; inherited fixtures contain no test functions.
contract TSVBusinessRolesTest is FoundationFixture {
    /// @dev Verifies business Governor recovery updates the dynamically resolved admin.
    function testBusinessGovernorRecoveryChangesDynamicAdmin() public {
        address next = makeAddr("new-governor");
        assertTrue(registry.hasRole(0, address(this)));
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, keccak256("foundation-recovery"), keccak256("recovery"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, next));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
    }

    function testDefaultAdminCannotBeGranted() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.grantRole(bytes32(0), council);
        assertFalse(registry.hasRole(bytes32(0), council));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
    }

    function testDefaultAdminCannotBeRevoked() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.revokeRole(bytes32(0), address(this));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
    }

    function testDefaultAdminCannotBeRenounced() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.renounceRole(bytes32(0), address(this));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
        assertFalse(registry.hasRole(bytes32(0), address(0)));
    }

    function testInternalRolePathsAlsoProtectDefaultAdmin() public {
        GovernedRoleHarness implementation = new GovernedRoleHarness();
        GovernedRoleHarness harness = GovernedRoleHarness(
            address(
                new TSVERC1967Proxy(
                    address(implementation), abi.encodeCall(GovernedRoleHarness.initialize, (address(anchor)))
                )
            )
        );
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        harness.internalGrant(bytes32(0), council);
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        harness.internalRevoke(bytes32(0), address(this));
        bytes32 role = keccak256("TEST_BUSINESS_ROLE");
        harness.internalGrant(role, council);
        assertTrue(harness.hasRole(role, council));
        harness.internalRevoke(role, council);
        assertFalse(harness.hasRole(role, council));
    }

    function testBusinessRolesCanBeGrantedRevokedAndRenounced() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        assertTrue(registry.hasRole(role, council));
        registry.revokeRole(role, council);
        assertFalse(registry.hasRole(role, council));
        registry.grantRole(role, council);
        vm.prank(council);
        registry.renounceRole(role, council);
        assertFalse(registry.hasRole(role, council));
    }

    function testBusinessRoleRenunciationCannotRemoveSomeoneElse() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        vm.prank(guardian);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        registry.renounceRole(role, council);
        assertTrue(registry.hasRole(role, council));
    }

    function testOnlyGovernorCanGrantOrRevokeBusinessRoles() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        registry.grantRole(role, council);
        for (uint256 i; i < callers.length; ++i) {
            bytes memory errorData = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], bytes32(0)
            );
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.grantRole(role, guardian);
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.revokeRole(role, council);
        }
        assertFalse(registry.hasRole(role, guardian));
        assertTrue(registry.hasRole(role, council));
    }

    function testRecoveryTransfersRoleManagementAndGovernorConfiguration() public {
        address next = makeAddr("new-governor");
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, keccak256("roles"), keccak256("evidence"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0));
        vm.expectRevert(denied);
        registry.grantRole(role, guardian);
        vm.expectRevert(denied);
        registry.revokeRole(role, council);
        vm.expectRevert(denied);
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
        vm.startPrank(next);
        registry.grantRole(role, guardian);
        registry.revokeRole(role, council);
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
        vm.stopPrank();
        assertTrue(registry.hasRole(role, guardian));
        assertFalse(registry.hasRole(role, council));
        // An explicitly granted business role survives identity recovery independently.
        assertTrue(registry.hasRole(role, address(this)));
    }
}
