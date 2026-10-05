// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVTradeDayTest scenarios; inherited fixtures contain no test functions.
contract TSVTradeDayTest is FoundationFixture {
    /// @dev Verifies automatic trade-day calculations use Gregorian dates and the previous month.
    function testAutomaticTradeDayUsesGregorianDatesAndPreviousMonth() public {
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, DAY);
        assertEq(ledger.dayStartUTC(DAY), 1_790_827_200);
        assertEq(ledger.dayStartUTC(20280229), ledger.dayStartUTC(20280228) + 86_400);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.dayStartUTC(20260229);
    }

    /// @dev Verifies a day-start change schedules the transition and locks at its start.
    function testDayStartScheduleCreatesLongTransitionAndLocksAtTransitionStart() public {
        uint32 effectiveDay = 20261004;
        uint64 oldTransitionStart = ledger.dayStartUTC(20261003);
        ledger.scheduleDayStart(28_800, effectiveDay);
        assertEq(ledger.dayStartCheckpointCount(), 1);
        TSVVolumeLedgerV1.DayStartCheckpoint memory checkpoint = ledger.dayStartCheckpoint(0);
        assertEq(checkpoint.effectiveDayId, effectiveDay);
        assertEq(checkpoint.offsetSeconds, 28_800);
        assertEq(ledger.dayStartUTC(effectiveDay) - oldTransitionStart, 100_800);
        vm.warp(oldTransitionStart);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart();
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, 20261003);
        uint64 effectiveStart = ledger.dayStartUTC(effectiveDay);
        vm.warp(effectiveStart - 1);
        (, day) = ledger.currentTradeDay();
        assertEq(day, 20261003);
        vm.warp(effectiveStart);
        (, day) = ledger.currentTradeDay();
        assertEq(day, effectiveDay);
    }

    /// @dev Verifies a day-start change can be cancelled before transition without retaining a checkpoint.
    function testDayStartCanBeCancelledBeforeTransitionWithoutRetainingCheckpoint() public {
        ledger.scheduleDayStart(3_600, 20261004);
        ledger.cancelPendingDayStart();
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(20261004), ledger.dayStartUTC(20261001) + 3 * 86_400);
    }

    /// @dev Verifies another day-start change can be scheduled after the prior checkpoint takes effect.
    function testCanScheduleAnotherDayStartAfterPriorCheckpointTakesEffect() public {
        ledger.scheduleDayStart(20_000, 20261004);
        vm.warp(ledger.dayStartUTC(20261004));
        ledger.scheduleDayStart(14_400, 20261010);
        assertEq(ledger.dayStartCheckpointCount(), 2);
        assertEq(ledger.dayStartUTC(20261009), ledger.dayStartUTC(20261001) + 8 * 86_400 + 5_600);
        assertEq(ledger.dayStartUTC(20261010), ledger.dayStartUTC(20261001) + 9 * 86_400);
        assertEq(ledger.dayStartUTC(20261010) - ledger.dayStartUTC(20261009), 80_800);
    }

    /// @dev Verifies day-start scheduling rejects past boundaries, invalid dates, and shifts above four hours.
    function testDayStartRejectsPastBoundaryInvalidDateAndShiftAboveFourHours() public {
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20261002);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(28_801, 20261004);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20260229);
        assertEq(ledger.dayStartCheckpointCount(), 0);
    }
}
