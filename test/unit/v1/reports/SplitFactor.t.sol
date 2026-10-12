// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {SplitFactorFixture} from "../../../helpers/v1/SplitFactorFixture.sol";

/// @dev Default, activation, source-month basis, ordering and cancellation behavior.
contract TSVSplitFactorTest is SplitFactorFixture {
    function testDefaultFactorKeepsExistingAdtvTierAndMissingReportRules() public {
        _assertFactor(DAY, 1, 1);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertFalse(valid);
        assertEq(left, 0);
        _submitAdtv(1000e18);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 0);
    }

    function testSplitActivatesExactlyAtDayStartWithoutAnotherTransactionAndKeepsOldUsed() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        _setFactor(20261002, 2, 1, 1);
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        uint32 day = ledger.currentTradeDay();
        assertEq(day, DAY);
        (, uint256 left) = ledger.remaining(SECURITY, day);
        assertEq(left, 1.5e18);
        vm.warp(start);
        day = ledger.currentTradeDay();
        assertEq(day, 20261002);
        (, left) = ledger.remaining(SECURITY, day);
        assertEq(left, 5e18);
        assertEq(ledger.used(SECURITY, day), 0);
        _charge(5e18);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, day));
        _charge(1);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)), 1000e18);
    }

    function testReverseSplitUsesAnExactFractionAndCanReduceTheCapToZero() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 10, 1);
        _assertFactor(20261002, 2, 10);
        vm.warp(ledger.dayStartUTC(20261002));
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 5e17);
        _charge(5e17);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, 20261002));
        _charge(1);

        _setFactor(20261003, 1, type(uint128).max, 2);
        vm.warp(ledger.dayStartUTC(20261003));
        (bool valid, uint256 zeroCap) = ledger.remaining(SECURITY, 20261003);
        assertFalse(valid);
        assertEq(zeroCap, 0);
        vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
        _charge(1);
    }

    function testSeveralAbsoluteFactorsUseTheLatestApplicableCheckpointInsteadOfMultiplyingAgain() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1);
        _setFactor(20261005, 6, 1, 2); // Two-for-one followed by three-for-one = absolute six.
        _setFactor(20261009, 6, 5, 3);
        _setFactor(20261010, 1, 1, 4);
        for (uint32 date = DAY; date <= 20261031; ++date) {
            uint128 numerator = date < 20261002 ? 1 : date < 20261005 ? 2 : date < 20261010 ? 6 : 1;
            uint128 denominator = date == 20261009 ? 5 : 1;
            _assertFactor(date, numerator, denominator);
            (, uint256 left) = ledger.remaining(SECURITY, date);
            assertEq(left, uint256(25e17) * numerator / denominator);
        }
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 4);
    }

    function testNewAdtvSourceMonthStartsAtOneAndDoesNotApplyPreviousMonthsSplitAgain() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1);
        AdtvReport memory next = _adtv(SECURITY, 2000e18, 2, keccak256("new-month-basis"));
        next.sourceMonth = 202610;
        inbox.submitAdtv(next);
        _assertFactor(20261031, 2, 1);
        _assertFactor(20261101, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261101);
        assertEq(left, 5e18); // October ADTV is already in October's closing units.
        _setFactor(20261105, 1, 5, 2);
        _assertFactor(20261105, 1, 5);
        (, left) = ledger.remaining(SECURITY, 20261105);
        assertEq(left, 1e18);
    }

    function testFactorsAreIndependentAcrossSecurities() public {
        bytes32 second = keccak256("SEC_FACTOR_B");
        _admitAdditionalSecurity(second);
        _submitAdtv(1000e18);
        inbox.submitAdtv(_adtv(second, 1000e18, 1, keccak256("second-adtv")));
        _setFactor(20261002, 2, 1, 1);
        SplitFactorReport memory other = _factor(20261002, 3, 1, 1, keccak256("second-factor"));
        other.securityId = second;
        inbox.submitSplitFactor(other);
        (, uint256 firstLeft) = ledger.remaining(SECURITY, 20261002);
        (, uint256 secondLeft) = ledger.remaining(second, 20261002);
        assertEq(firstLeft, 5e18);
        assertEq(secondLeft, 7.5e18);
    }

    function testFactorCanBeScheduledBeforeMonthlyReportButDoesNotSubstituteForMissingAdtv() public {
        _setFactor(20261002, 2, 1, 1);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertFalse(valid);
        assertEq(left, 0);
        vm.warp(ledger.dayStartUTC(20261002));
        vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
        _charge(1);
        _submitAdtv(1000e18);
        (valid, left) = ledger.remaining(SECURITY, 20261002);
        assertTrue(valid);
        assertEq(left, 5e18);
    }

    function testOnlyLatestPendingCheckpointCanBeCorrectedAndItsOldReportRemainsConsumed() public {
        _setFactor(20261002, 2, 1, 1);
        _setFactor(20261005, 3, 1, 2);
        bytes32 oldId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 1).reportId;
        SplitFactorReport memory earlier = _factor(20261002, 4, 1, 3, keccak256("earlier-correction"));
        bytes32 beforeState = _factorState(earlier);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(earlier);
        assertEq(_factorState(earlier), beforeState);
        _setFactor(20261005, 4, 2, 3);
        _assertFactor(20261005, 4, 2);
        assertTrue(inbox.reportIdUsed(oldId));
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 2);
    }

    function testCancelLatestPendingFactorRestoresEarlierFactorWithoutOrderCounters() public {
        _setFactor(20261002, 2, 1, 1);
        _setFactor(20261005, 6, 1, 2);
        bytes32 oldId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 1).reportId;
        _cancelFactor(20261005, 3);
        _assertFactor(20261005, 2, 1);
        assertTrue(inbox.reportIdUsed(oldId));
        _setFactor(20261005, 3, 1, 4);
        _assertFactor(20261005, 3, 1);
        _cancelFactor(20261005, 5);
        _cancelFactor(20261002, 6);
        _assertFactor(20261005, 1, 1);
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 0);
    }

    function testActivatedFactorCannotBeEditedCancelledOrReplayed() public {
        _setFactor(20261002, 2, 1, 1);
        vm.warp(ledger.dayStartUTC(20261002));
        for (uint8 action = 1; action <= 2; ++action) {
            SplitFactorReport memory report =
                _factor(20261002, action == 1 ? 3 : 0, action == 1 ? 1 : 0, 2, keccak256(abi.encode("locked", action)));
            report.action = action;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
        _assertFactor(20261002, 2, 1);
    }

    function testTwentyAndTwentyEightHourTransitionsActivateAtTheConfiguredDayStart() public {
        _submitAdtv(1000e18);
        for (uint8 variant; variant < 2; ++variant) {
            uint256 snapshot = vm.snapshotState();
            _setFactor(20261004, 2, 1, 1);
            ledger.scheduleDayStart(variant == 0 ? 0 : 28800, 20261004);
            uint256 start = ledger.dayStartUTC(20261004);
            vm.warp(start - 1);
            uint32 day = ledger.currentTradeDay();
            assertEq(day, 20261003);
            _assertFactor(day, 1, 1);
            vm.warp(start);
            day = ledger.currentTradeDay();
            assertEq(day, 20261004);
            _assertFactor(day, 2, 1);
            (, uint256 left) = ledger.remaining(SECURITY, day);
            assertEq(left, 5e18);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testQuotaRemainsAnAbsoluteTargetDayOverrideAndIsClampedByTheAdjustedHardCap() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1);
        // The quota is stated in the target day's units; it is not multiplied again.
        _submitFutureQuota(20261002, 4e18, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 4e18);
        _setFactor(20261002, 1, 5, 2);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 5e17);
        vm.warp(ledger.dayStartUTC(20261002));
        _charge(5e17);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, 20261002));
        _charge(1);
    }

    function testTierAndAdtvCorrectionsStillParticipateInTheAdjustedCap() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1);
        registry.setTierPolicy(1, 50, 10, bytes32("TEST"));
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 10e18);
        inbox.submitAdtv(_adtv(SECURITY, 2000e18, 2, keccak256("same-basis-correction")));
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 20e18);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)), 2000e18);
    }

    function testCapUsesOneFinalFloorInsteadOfFlooringBeforeApplyingTheFactor() public {
        registry.setTierPolicy(1, 5000, 10, bytes32("TEST"));
        _submitAdtv(3);
        _setFactor(20261002, 2, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 3); // floor(3 × 1/2 × 2), not floor(3 × 1/2) × 2.
    }

    function _submitFutureQuota(uint32 day, uint256 amount, uint64 label) private {
        bytes32 id = keccak256(abi.encode("factor-quota", day, label));
        inbox.submitQuota(_futureQuota(day, amount, label, id));
    }

    function _futureQuota(uint32 day, uint256 amount, uint64 label, bytes32 id)
        private
        view
        returns (QuotaReport memory report)
    {
        report = _quota(amount, 1, label, id);
        report.tradeDayId = day;
    }
}
