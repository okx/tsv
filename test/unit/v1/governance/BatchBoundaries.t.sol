// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {
    GovernanceMigrationV2,
    RegistryV2,
    LedgerV2,
    MigrationJournal,
    WrongUUIDImplementation,
    GovernorExecutor
} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGovernanceAnchor, IAnchoredProxyV1} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Batch input validation, migration authorization, atomic rollback and callback boundaries.
contract TSVBatchBoundariesTest is SixProxyFixture {
    function testBatchRejectsEmptyAndOversizedPlans() public {
        UpgradePlan memory empty = _currentPlan(0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(empty);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(new address[](7), new address[](7), new bytes[](7));
        assertFalse(anchor.upgradeContextActive());
    }

    function testBatchRejectsMismatchedInitializationDataLength() public {
        UpgradePlan memory plan = _currentPlan(2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(plan.targets, plan.implementations, new bytes[](1));
        _assertImplementations(plan);
    }

    function testBatchRejectsImplementationWithoutCode() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory invalid = _currentPlan(2);
        invalid.implementations[1] = makeAddr("no-code");
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(invalid);
        _assertImplementations(old);
    }

    function testBatchRejectsNonUUPSImplementationAndRollsBackEarlierUpgrade() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory invalid = _currentPlan(2);
        invalid.implementations[0] = address(new RegistryV2());
        invalid.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        invalid.implementations[1] = address(anchor);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(anchor)));
        _execute(invalid);
        _assertImplementations(old);
    }

    function testBatchRejectsWrongProxiableUUID() public {
        UpgradePlan memory old = _currentPlan(1);
        UpgradePlan memory invalid = _currentPlan(1);
        invalid.implementations[0] = address(new WrongUUIDImplementation());
        vm.expectRevert(
            abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(uint256(1)))
        );
        _execute(invalid);
        _assertImplementations(old);
    }

    function testSixProxiesUpgradeToDistinctV2ImplementationsAndMigrateOnce() public {
        UpgradePlan memory old = _currentPlan(6);
        UpgradePlan memory plan = _v2Plan();
        _execute(plan);
        _assertImplementations(plan);
        for (uint256 i; i < 6; ++i) {
            assertNotEq(plan.implementations[i], old.implementations[i]);
            GovernanceMigrationV2 migrated = GovernanceMigrationV2(plan.targets[i]);
            assertEq(migrated.migrationMarker(), 42);
            assertEq(migrated.migrationCaller(), address(anchor));
            assertTrue(TSVGoverned(plan.targets[i]).hasRole(bytes32(0), address(this)));
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            migrated.initializeV2(99, false);
        }
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(ledger.registry()), address(registry));
        assertEq(lp.nextPositionId(), 1);
    }

    function testFuzzFailureAtAnyBatchPositionRollsBackExternalWritesAndAllowsRetry(uint8 failurePosition) public {
        failurePosition = uint8(bound(failurePosition, 0, 5));
        UpgradePlan memory old = _currentPlan(6);
        UpgradePlan memory plan = _v2Plan();
        MigrationJournal journal = new MigrationJournal();
        for (uint256 i; i < 6; ++i) {
            plan.calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeAndRecord, (journal, 42));
        }
        plan.calls[failurePosition] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, true));
        vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        _execute(plan);
        _assertImplementations(old);
        assertEq(journal.entries(), 0, "external writes survived failed batch");
        plan.calls[failurePosition] = abi.encodeCall(GovernanceMigrationV2.initializeAndRecord, (journal, 99));
        _execute(plan);
        _assertImplementations(plan);
        assertEq(journal.entries(), 6);
        assertEq(GovernanceMigrationV2(plan.targets[failurePosition]).migrationMarker(), 99);
    }

    function testBatchAuthorityTransfersToRecoveredGovernor() public {
        address next = makeAddr("next-governor");
        _recoverGovernor(next);
        UpgradePlan memory plan = _currentPlan(1);
        plan.implementations[0] = address(new RegistryV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        address[4] memory callers = [address(this), guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            _execute(plan);
        }
        vm.prank(next);
        _execute(plan);
        _assertImplementations(plan);
    }

    function testUninitializedV2MigrationRequiresGovernorOrActiveAnchorBatch() public {
        RegistryV2 next = new RegistryV2();
        registry.upgradeToAndCall(address(next), "");
        GovernanceMigrationV2 migrated = GovernanceMigrationV2(address(registry));
        address[4] memory callers = [guardian, council, makeAddr("outsider"), address(anchor)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(GovernanceMigrationV2.UnauthorizedMigration.selector);
            migrated.initializeV2(42, false);
            assertEq(migrated.migrationMarker(), 0);
        }
        migrated.initializeV2(99, false);
        assertEq(migrated.migrationMarker(), 99);
        assertEq(migrated.migrationCaller(), address(this));
    }

    function testContractGovernorCanUpgradeDirectlyAndExecuteBatch() public {
        GovernorExecutor executor = new GovernorExecutor(address(this));
        _recoverGovernor(address(executor));
        RegistryV2 next = new RegistryV2();
        executor.execute(
            address(registry),
            abi.encodeCall(
                IAnchoredProxyV1.upgradeToAndCall,
                (address(next), abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false)))
            )
        );
        assertEq(GovernanceMigrationV2(address(registry)).migrationCaller(), address(executor));
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[1] = address(new LedgerV2());
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (99, false));
        executor.execute(
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (plan.targets, plan.implementations, plan.calls))
        );
        _assertImplementations(plan);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationCaller(), address(anchor));
    }

    function testNestedBatchFromGovernorCallbackIsRejectedAndOuterBatchRollsBack() public {
        GovernorExecutor executor = new GovernorExecutor(address(this));
        _recoverGovernor(address(executor));
        executor.armCallback(address(ledger));
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        plan.implementations[1] = address(new LedgerV2());
        bytes memory nestedBatch =
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (old.targets, old.implementations, old.calls));
        plan.calls[1] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(executor), abi.encodeCall(GovernorExecutor.execute, (address(anchor), nestedBatch)))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        executor.execute(
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (plan.targets, plan.implementations, plan.calls))
        );
        _assertImplementations(old);
    }

    function testGuardianFreezeDuringMigrationRejectsRemainingUpgradeAndRollsBackEntireTransaction() public {
        GovernorExecutor guardianContract = new GovernorExecutor(address(this));
        bytes32 id = _proposeRecovery(address(this), address(guardianContract), "guardian-contract");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        guardianContract.armCallback(address(registry));
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        bytes memory freeze = abi.encodeCall(TSVGovernanceAnchor.freezeUpgrades, ());
        plan.calls[0] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(guardianContract), abi.encodeCall(GovernorExecutor.execute, (address(anchor), freeze)))
        );
        plan.implementations[1] = address(new LedgerV2());
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        _execute(plan);
        _assertImplementations(old);
        assertFalse(anchor.upgradesFrozen());
        assertEq(anchor.freezeEpoch(), 0);
        assertEq(anchor.freezeId(), bytes32(0));
    }

    function _v2Plan() private returns (UpgradePlan memory plan) {
        plan = _currentPlan(6);
        address[6] memory implementations = UpgradeDeployment.deployV2();
        for (uint256 i; i < 6; ++i) {
            plan.implementations[i] = implementations[i];
            plan.calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        }
    }

    function _recoverGovernor(address next) private {
        bytes32 id = _proposeRecovery(next, guardian, "contract-or-new-governor");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
    }
}
