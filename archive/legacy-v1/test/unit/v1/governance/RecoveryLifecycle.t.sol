// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Invalid inputs, competing proposals and authority changes around recovery.
contract TSVRecoveryLifecycleTest is GovernanceFixture {
    bytes32 internal constant SALT = keccak256("recovery-salt");

    function testProposalRequiresNonzeroSalt() public {
        address next = makeAddr("next-governor");
        vm.startPrank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.proposeRecovery(next, guardian, bytes32(0));
        anchor.proposeRecovery(next, guardian, SALT);
        vm.stopPrank();
        assertEq(anchor.epoch(), 0);
    }

    function testRecoveryRejectsZeroAndEqualIdentities() public {
        _rejectIdentities(address(0), guardian);
        _rejectIdentities(makeAddr("next-governor"), address(0));
        _rejectIdentities(makeAddr("same-identity"), makeAddr("same-identity"));
    }

    function testRecoveryCannotAssignCouncilToEitherOtherRole() public {
        _rejectIdentities(council, guardian);
        _rejectIdentities(makeAddr("next-governor"), council);
    }

    function testRecoveryCannotSwapExistingGovernorAndGuardianRoles() public {
        _rejectIdentities(guardian, makeAddr("next-guardian"));
        _rejectIdentities(makeAddr("next-governor"), address(this));
    }

    function testRecoveryMustChangeAtLeastOneIdentity() public {
        _rejectIdentities(address(this), guardian);
    }

    function testOnlyCouncilCanProposeAndCancel() public {
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), guardian, "pending");
        address[3] memory callers = [address(this), guardian, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.proposeRecovery(makeAddr("another-governor"), guardian, SALT);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.cancelRecovery(id);
            vm.stopPrank();
        }
        (,,,, bool active,) = anchor.recoveries(id);
        assertTrue(active);
    }

    function testUnknownProposalCannotBeApprovedRevokedCancelledOrExecuted() public {
        bytes32 id = keccak256("unknown");
        vm.startPrank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        vm.stopPrank();
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testActiveDuplicateProposalIsRejectedWithoutLosingApproval() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "duplicate");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.proposeRecovery(next, guardian, keccak256("duplicate"));
        (,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertTrue(approved);
    }

    function testReproposingCancelledProposalRequiresFreshGuardianApproval() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "reused-salt");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        assertEq(_proposeRecovery(next, guardian, "reused-salt"), id);
        (,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertFalse(approved);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), next);
    }

    function testGovernorOnlyRecoveryInvalidatesCompetingApproval() public {
        bytes32 first = _proposeRecovery(makeAddr("governor-one"), guardian, "first");
        bytes32 second = _proposeRecovery(makeAddr("governor-two"), guardian, "second");
        vm.startPrank(guardian);
        anchor.approveRecovery(first);
        anchor.approveRecovery(second);
        vm.stopPrank();
        anchor.executeRecovery(first);
        assertEq(anchor.epoch(), 1);
        assertEq(anchor.guardianEpoch(), 0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(second);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(second);
    }

    function testGuardianCandidateCannotApproveItsOwnRecovery() public {
        address next = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(address(this), next, "guardian");
        vm.prank(next);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.approveRecovery(id);
        (,,,,, bool approved) = anchor.recoveries(id);
        assertFalse(approved);
    }

    function testOldGuardianCannotApproveOrRevokeNewProposal() public {
        address next = makeAddr("next-guardian");
        bytes32 rotate = _proposeRecovery(address(this), next, "rotate");
        vm.prank(guardian);
        anchor.approveRecovery(rotate);
        anchor.executeRecovery(rotate);
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), next, "new-proposal");
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.approveRecovery(id);
        vm.prank(next);
        anchor.approveRecovery(id);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        (,,,,, bool approved) = anchor.recoveries(id);
        assertTrue(approved);
    }

    function testAnyoneCanExecuteApprovedRecoveryButItCannotBeReplayed() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "permissionless-execution");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.startPrank(makeAddr("executor"));
        anchor.executeRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.stopPrank();
        assertEq(anchor.governor(), next);
        (,,,, bool active, bool approved) = anchor.recoveries(id);
        assertFalse(active);
        assertFalse(approved);
    }

    function testCancelledApprovalCanBeCleanedUpWithoutReactivatingProposal() public {
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), guardian, "cancel");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.startPrank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(id);
        vm.stopPrank();
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testProposalIdsAreSeparatedByAnchorAndChain() public {
        address next = makeAddr("next-governor");
        bytes32 first = _proposeRecovery(next, guardian, "domain");
        TSVGovernanceAnchor other = new TSVGovernanceAnchor(address(this), guardian, council);
        vm.prank(council);
        bytes32 differentAnchor = other.proposeRecovery(next, guardian, keccak256("domain"));
        vm.chainId(block.chainid + 1);
        bytes32 differentChain = _proposeRecovery(next, guardian, "domain");
        assertNotEq(first, differentAnchor);
        assertNotEq(first, differentChain);
    }

    function _rejectIdentities(address nextGovernor, address nextGuardian) private {
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(nextGovernor, nextGuardian, SALT);
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.epoch(), 0);
    }
}
