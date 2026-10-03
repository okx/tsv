// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {RegistryV2, LedgerV2, GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Each test starts from a fresh fixture and checks one batch rule.
contract TSVBatchUpgradeTest is SixProxyFixture {
    function testTwoProxyMigrationRollsBackAndCanRetryWithAnchorCaller() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, true));
        vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        _execute(plan);
        _assertImplementations(old);
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (99, false));
        _execute(plan);
        _assertImplementations(plan);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationMarker(), 99);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationCaller(), address(anchor));
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(ledger.registry()), address(registry));
    }

    function testApprovedRecoveryCannotExecuteDuringBatchMigration() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        bytes32 id = _proposeRecovery(address(this), makeAddr("next-guardian"), "batch-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        plan.calls[1] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(anchor), abi.encodeCall(TSVGovernanceAnchor.executeRecovery, (id)))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        _execute(plan);
        _assertImplementations(old);
        assertEq(anchor.epoch(), 0);
        assertEq(anchor.guardian(), guardian);
        (,,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertTrue(approved);
        anchor.executeRecovery(id);
        assertEq(anchor.epoch(), 1);
    }

    function testOnlyGovernorCanStartBatch() public {
        UpgradePlan memory plan = _twoProxyMigration();
        UpgradePlan memory old = _currentPlan(2);
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            _execute(plan);
        }
        _assertImplementations(old);
    }

    function testBatchRejectsDuplicateTarget() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.targets[1] = plan.targets[0];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(old);
    }

    function testBatchRejectsUnboundTarget() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.targets[1] = plan.implementations[1];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(old);
    }

    function testBatchRejectsMismatchedImplementationArrayLength() public {
        UpgradePlan memory old = _currentPlan(2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(old.targets, new address[](1), old.calls);
        _assertImplementations(old);
    }

    function testAnchorCannotUpgradeOutsideActiveBatch() public {
        UpgradePlan memory old = _currentPlan(1);
        RegistryV2 next = new RegistryV2();
        vm.prank(address(anchor));
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        registry.upgradeToAndCall(address(next), "");
        _assertImplementations(old);
    }

    function _twoProxyMigration() private returns (UpgradePlan memory plan) {
        plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        plan.implementations[1] = address(new LedgerV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
    }
}
