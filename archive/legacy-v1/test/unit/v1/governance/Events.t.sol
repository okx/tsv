// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Observable governance records used by incident tracking and proposal indexing.
contract TSVGovernanceEventsTest is SixProxyFixture {
    function _bindInSetUp() internal pure override returns (bool) {
        return false;
    }

    function testBindingAndBatchEventsIdentifyActualProxiesAndGovernor() public {
        vm.expectEmit(false, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.ProxiesBound(businessProxies);
        anchor.bindProxies(businessProxies);
        UpgradePlan memory plan = _currentPlan(2);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.BatchUpgraded(address(this), 2);
        _execute(plan);
    }

    function testFreezeAndUnfreezeEventsIdentifyIncidentAndGuardian() public {
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(anchor), uint64(1), guardian));
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.UpgradesFrozen(expectedId, guardian);
        vm.prank(guardian);
        assertEq(anchor.freezeUpgrades(), expectedId);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.UpgradesUnfrozen(expectedId, guardian);
        vm.prank(guardian);
        anchor.unfreezeUpgrades(expectedId);
    }

    function testProposalApprovalRevocationAndCancellationEvents() public {
        address next = makeAddr("next-governor");
        bytes32 salt = keccak256("event-salt");

        bytes32 expectedId =
            keccak256(abi.encode(block.chainid, address(anchor), uint64(0), uint64(0), next, guardian, salt));
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryProposed(expectedId, next, guardian);
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, salt);
        assertEq(id, expectedId);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryApprovalChanged(id, true);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryApprovalChanged(id, false);
        vm.prank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryCancelled(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
    }

    function testRecoveryEventsContainOldAndNewIdentitiesAndGuardianEpoch() public {
        address nextGovernor = makeAddr("next-governor");
        address nextGuardian = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(nextGovernor, nextGuardian, "events");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.GuardianSynced(guardian, nextGuardian, 1);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.AuthoritiesRecovered(address(this), nextGovernor, nextGuardian);
        anchor.executeRecovery(id);
    }
}
