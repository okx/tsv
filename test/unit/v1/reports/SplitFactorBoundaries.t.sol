// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {AdtvReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";
import {ReportValidationLib} from "tsv-v1/libraries/ReportValidationLib.sol";
import {SplitFactorFixture} from "../../../helpers/v1/SplitFactorFixture.sol";

/// @dev Authorization, malformed reports, locked history, arithmetic limits and failure-state preservation.
contract TSVSplitFactorBoundariesTest is SplitFactorFixture {
    function testScheduleCorrectionAndCancellationEventsCarryReportedFactorsAndReportIds() public {
        SplitFactorReport memory first = _factor(20261002, 2, 10, 1, keccak256("event-first"));
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorScheduled(SECURITY, 202609, 20261002, 2, 10, first.reportId);
        inbox.submitSplitFactor(first);
        SplitFactorReport memory correction = _factor(20261002, 3, 1, 2, keccak256("event-correction"));
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorScheduled(SECURITY, 202609, 20261002, 3, 1, correction.reportId);
        inbox.submitSplitFactor(correction);
        SplitFactorReport memory cancelled = _factor(20261002, 0, 0, 3, keccak256("event-cancellation"));
        cancelled.action = 2;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorCancelled(SECURITY, 202609, 20261002, correction.reportId, cancelled.reportId);
        inbox.submitSplitFactor(cancelled);
    }

    function testDelistedSecurityCannotReceiveNewFactorReports() public {
        registry.delistSecurity(SECURITY);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("delisted-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(report);
        assertEq(_factorState(report), beforeState);
    }

    function testOnlyVolumeReporterCanScheduleOrCancelAndRevocationTakesEffectImmediately() public {
        address outsider = makeAddr("factor-outsider");
        address haltReporter = makeAddr("factor-halt-reporter");
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), haltReporter);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("factor-role"));
        address[2] memory callers = [outsider, haltReporter];
        for (uint256 i; i < callers.length; ++i) {
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(callers[i]);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
        inbox.revokeRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitSplitFactor(report); // The Governor is not implicitly a reporter.
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        inbox.submitSplitFactor(report);
        report = _factor(20261002, 0, 0, 2, keccak256("factor-cancel-role"));
        report.action = 2;
        inbox.revokeRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitSplitFactor(report);
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        inbox.submitSplitFactor(report);
        _assertFactor(20261002, 1, 1);
    }

    function testLedgerFactorWriterIsOnlyTheBoundInbox() public {
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("direct-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptSplitFactor(report);
        assertEq(_factorState(report), beforeState);
    }

    function testInvalidBusinessFieldsDoNotConsumeReportMetadataAndTheSameIdCanBeRetried() public {
        for (uint8 fault; fault < 10; ++fault) {
            SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256(abi.encode("invalid-factor", fault)));
            if (fault == 0) report.securityId = 0;
            else if (fault == 1) report.securityId = keccak256("unknown-security");
            else if (fault == 2) report.sourceMonth = 202613;
            else if (fault == 3) report.sourceMonth = 202608;
            else if (fault == 4) report.effectiveTradeDayId = DAY;
            else if (fault == 5) report.effectiveTradeDayId = 20261032;
            else if (fault == 6) report.numerator = 0;
            else if (fault == 7) report.denominator = 0;
            else if (fault == 8) report.action = 0;
            else report.action = 3;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(fault == 5 ? TradeDayLib.InvalidPeriod.selector : TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
            assertFalse(inbox.reportIdUsed(report.reportId));
        }
        SplitFactorReport memory retry = _factor(20261002, 2, 1, 1, keccak256(abi.encode("invalid-factor", 6)));
        inbox.submitSplitFactor(retry);
        assertTrue(inbox.reportIdUsed(retry.reportId));
        _assertFactor(20261002, 2, 1);
    }

    function testInvalidIngressMetadataAndReplayLeaveAllFactorStateUnchanged() public {
        _setFactor(20261002, 2, 1, 1);
        for (uint8 fault; fault < 7; ++fault) {
            SplitFactorReport memory report = _factor(20261003, 3, 1, 2, keccak256(abi.encode("factor-ingress", fault)));
            if (fault == 0) report.reportId = 0;
            else if (fault == 1) report.sequence = 0;
            else if (fault == 2) report.sequence = 1;
            else if (fault == 3) report.sourceTimestamp = uint64(block.timestamp - 1);
            else if (fault == 4) report.sourceTimestamp = uint64(block.timestamp + 1);
            else if (fault == 5) report.submitDeadline = uint64(block.timestamp - 1);
            else report.reportId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 0).reportId;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(
                fault == 4 || fault == 5
                    ? ReportValidationLib.Expired.selector
                    : ReportValidationLib.InvalidReport.selector
            );
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
    }

    function testSplitReportIdsAreGlobalButSequenceScopesRemainIndependent() public {
        _submitAdtv(1000e18);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("adtv"));
        vm.expectRevert(ReportValidationLib.InvalidReport.selector);
        inbox.submitSplitFactor(report);
        assertEq(inbox.lastSequence(3, SECURITY), 0);
        report.reportId = keccak256("distinct-factor-id");
        report.sequence = 7; // Gaps are permitted, but source ordering is independent from ADTV.
        inbox.submitSplitFactor(report);
        assertEq(inbox.lastSequence(1, SECURITY), 1);
        assertEq(inbox.lastSequence(3, SECURITY), 7);
    }

    function testSourceTimeAndSubmissionDeadlineCannotSelectAnIntradayActivationTime() public {
        _submitAdtv(1000e18);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("timestamp-fields"));
        report.submitDeadline = uint64(block.timestamp); // Inclusive acceptance; not a factor expiry.
        inbox.submitSplitFactor(report);
        vm.warp(block.timestamp + 1000);
        uint32 day = ledger.currentTradeDay();
        assertEq(day, DAY);
        _assertFactor(day, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, day);
        assertEq(left, 2.5e18);
        vm.warp(ledger.dayStartUTC(20261002));
        _assertFactor(20261002, 2, 1);
    }

    function testCancellationRequiresTheLatestPendingDayAndZeroFactorComponents() public {
        SplitFactorReport memory empty = _factor(20261002, 0, 0, 1, keccak256("cancel-empty"));
        empty.action = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(empty);
        _setFactor(20261002, 2, 1, 1);
        _setFactor(20261005, 3, 1, 2);
        for (uint8 fault; fault < 3; ++fault) {
            SplitFactorReport memory report = _factor(20261005, 0, 0, 3, keccak256(abi.encode("invalid-cancel", fault)));
            report.action = 2;
            if (fault == 0) report.effectiveTradeDayId = 20261002;
            else if (fault == 1) report.numerator = 1;
            else report.denominator = 1;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
    }

    function testCancellationOneSecondBeforeStartSucceedsButAtStartIsLocked() public {
        _setFactor(20261002, 2, 1, 1);
        uint256 snapshot = vm.snapshotState();
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        _cancelFactor(20261002, 2);
        _assertFactor(20261002, 1, 1);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(start);
        SplitFactorReport memory locked = _factor(20261002, 0, 0, 2, keccak256("cancel-at-start"));
        locked.action = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(locked);
        _assertFactor(20261002, 2, 1);
    }

    function testFactorOverflowRejectsScheduleOrAdtvCorrectionWithoutPoisoningFutureCaps() public {
        _submitAdtv(type(uint256).max);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, keccak256("overflow-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitSplitFactor(report);
        assertEq(_factorState(report), beforeState);

        inbox.submitAdtv(_adtv(SECURITY, type(uint256).max / 2, 2, keccak256("safe-large-basis")));
        inbox.submitSplitFactor(report); // Reuse the rejected report ID after fixing the basis.
        registry.setTierPolicy(1, 10000, 10);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, type(uint256).max - 1);

        AdtvReport memory correction = _adtv(SECURITY, type(uint256).max, 3, keccak256("overflow-correction"));
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitAdtv(correction);
        assertFalse(inbox.reportIdUsed(correction.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)), type(uint256).max / 2);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, type(uint256).max - 1);
    }

    function testScheduledFactorBeforeAdtvAlsoGuardsTheFirstReportAgainstOverflow() public {
        _setFactor(20261002, 2, 1, 1);
        AdtvReport memory first = _adtv(SECURITY, type(uint256).max, 1, keccak256("first-basis-overflow"));
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitAdtv(first);
        assertFalse(inbox.reportIdUsed(first.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)), 0);
        first.adtvWad = type(uint256).max / 2;
        inbox.submitAdtv(first);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)), type(uint256).max / 2);
    }

    function testMaximumEqualFractionIsPreservedAndAllMonthDaysRemainQueryable() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, type(uint128).max, type(uint128).max, 1);
        _assertFactor(20261002, type(uint128).max, type(uint128).max);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 2.5e18);
        for (uint32 day = 20261003; day <= 20261031; ++day) {
            _setFactor(day, uint128(day - 20261000), 1, uint64(day - DAY));
        }
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 30);
        for (uint32 day = 20261003; day <= 20261031; ++day) {
            _assertFactor(day, uint128(day - 20261000), 1);
        }
        _assertFactor(20261101, 1, 1);
    }

    function testFuzzAdjustedCapMatchesIndependentBoundedIntegerFormula(uint160 value, uint64 n, uint64 d, uint16 bps)
        public
    {
        value = uint160(bound(value, 1, type(uint160).max));
        n = uint64(bound(n, 1, type(uint64).max));
        d = uint64(bound(d, 1, type(uint64).max));
        bps = uint16(bound(bps, 1, 10000));
        registry.setTierPolicy(1, bps, 10);
        _submitAdtv(value);
        _setFactor(20261002, n, d, 1);
        // This oracle uses ordinary integer multiplication in a proven < 238-bit input range.
        uint256 expected = uint256(value) * n * bps / (uint256(d) * 10000);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(valid, expected != 0);
        assertEq(left, expected);
    }
}
