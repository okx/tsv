// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

/// @dev TSVRecoveryTest scenarios; inherited fixtures contain no test functions.
contract TSVRecoveryTest is GovernanceFixture {
    function testGovernorRecoveryPreservesFreezeUntilGuardianExplicitlyUnfreezes() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 next = new TSVRegistryV1();
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("compromised-governor"));
        address nextGovernor = makeAddr("recovered-governor");
        bytes32 recovery = _proposeRecovery(nextGovernor, guardian, "frozen-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(recovery);
        anchor.executeRecovery(recovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        assertEq(anchor.freezeEpoch(), 1);
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(next), "");
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(guardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(nextGovernor);
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(next), "");
        assertEq(proxy.tsvImplementation(), address(next));
    }

    function testGuardianRecoveryPreservesFreezeAndTransfersUnfreezeControl() public {
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("incident"));
        address nextGuardian = makeAddr("recovered-guardian");
        bytes32 recovery = _proposeRecovery(address(this), nextGuardian, "guardian-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(recovery);
        anchor.executeRecovery(recovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(nextGuardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        assertFalse(anchor.upgradesFrozen());
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.freezeUpgrades(keccak256("incident"));
        vm.prank(nextGuardian);
        anchor.freezeUpgrades(keccak256("incident"));
    }

    function testRecoveryRequiresCurrentGuardianApprovalAndRevocationIsEffective() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address nextGovernor = makeAddr("next-governor");
        address nextGuardian = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(nextGovernor, nextGuardian, "recovery");
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), nextGovernor);
        assertEq(anchor.guardian(), nextGuardian);
        assertEq(anchor.guardianEpoch(), 1);
        assertEq(anchor.epoch(), 1);
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, nextGovernor));
        TSVRegistryV1 next = new TSVRegistryV1();
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        registry.upgradeToAndCall(address(next), "");
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(address(next), "");
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testCancelledRecoveryCannotChangeIdentitiesOrFreeze() public {
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("incident"));
        bytes32 id = _proposeRecovery(makeAddr("new-governor"), makeAddr("new-guardian"), "cancelled");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.guardianEpoch(), 0);
        assertEq(anchor.epoch(), 0);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }

    function testRecoveryRotationInvalidatesOtherApprovals() public {
        bytes32 first = _proposeRecovery(address(this), makeAddr("guardian1"), "first");
        bytes32 second = _proposeRecovery(address(this), makeAddr("guardian2"), "second");
        vm.prank(guardian);
        anchor.approveRecovery(first);
        vm.prank(guardian);
        anchor.approveRecovery(second);
        anchor.executeRecovery(first);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(second);
        vm.prank(makeAddr("guardian1"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(second);
    }

    function testRecoveryProposalRejectsUnauthorizedOrConflictingIdentities() public {
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.proposeRecovery(makeAddr("new-governor"), guardian, keccak256("salt"), keccak256("evidence"));
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(council, guardian, keccak256("salt"), keccak256("evidence"));
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(guardian, makeAddr("new-guardian"), keccak256("salt"), keccak256("evidence"));
    }

    function testRecoveryCannotBeApprovedByGovernorCouncilOrOutsider() public {
        bytes32 id = _proposeRecovery(makeAddr("new-governor"), guardian, "approval");
        address[3] memory callers = [address(this), council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.approveRecovery(id);
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
            anchor.executeRecovery(id);
        }
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.epoch(), 0);
    }
}
