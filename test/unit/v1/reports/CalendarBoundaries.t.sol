// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsCalendarTest is OperationsFixture {
    function testCalendarBoundariesMatchIndependentUtcVectors() public {
        // Unix timestamps generated independently with Python datetime(timezone.utc).
        uint32[8] memory dates =
            [uint32(20261001), 20261003, 20261004, 20261101, 20270101, 20280229, 20280301, 21000301];
        uint32[8] memory previous =
            [uint32(20260930), 20261002, 20261003, 20261031, 20261231, 20280228, 20280229, 21000228];
        uint64[8] memory midnights =
            [uint64(1790812800), 1790985600, 1791072000, 1793491200, 1798761600, 1835395200, 1835481600, 4107542400];
        for (uint256 i; i < dates.length; ++i) {
            uint64 start = midnights[i] + 14400;
            assertEq(ledger.dayStartUTC(dates[i]), start);
            vm.warp(start - 1);
            uint32 day = ledger.currentTradeDay();
            assertEq(day, previous[i]);
            vm.warp(start);
            day = ledger.currentTradeDay();
            assertEq(day, dates[i]);
            vm.warp(start + 1);
            day = ledger.currentTradeDay();
            assertEq(day, dates[i]);
        }
        assertEq(ledger.dayStartUTC(20000229), 951782400 + 14400);
    }

    function testFuzzInitialOffsetAssignsEverySecondToExactlyOneDay(uint32 offset, uint32 second) public {
        offset = uint32(bound(offset, 0, 86399));
        second = uint32(bound(second, 0, 86399));
        TSVVolumeLedgerV1 custom = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), offset))
                )
            )
        );
        vm.warp(1791072000 + second); // 2026-10-04 00:00 UTC + independently selected second.
        uint32 day = custom.currentTradeDay();
        assertEq(day, second >= offset ? 20261004 : 20261003);
        assertEq(custom.dayStartUTC(20261004), 1791072000 + offset);
    }

    function testInvalidGregorianDatesAreRejected() public {
        uint32[11] memory invalid = [
            uint32(0),
            19691231,
            20260001,
            20261301,
            20261000,
            20260431,
            20260229,
            21000229,
            20260230,
            100000101,
            20260132
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
            ledger.dayStartUTC(invalid[i]);
        }
    }

    function testShortestTransitionHasNoOverlapAndOneTradeDay() public {
        ledger.scheduleDayStart(0, 20261004);
        assertEq(ledger.dayStartUTC(20261004) - ledger.dayStartUTC(20261003), 20 hours);
        vm.warp(1791072000 - 1);
        uint32 day = ledger.currentTradeDay();
        assertEq(day, 20261003);
        vm.warp(1791072000);
        day = ledger.currentTradeDay();
        assertEq(day, 20261004);
        assertEq(ledger.dayStartUTC(DAY), 1790827200);
    }

    function testPendingScheduleAndCancellationBoundsKeepHistoricalUsage() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        uint64 historicalStart = ledger.dayStartUTC(DAY);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart();
        uint32[4] memory badOffsets = [uint32(86400), 14400, 28801, type(uint32).max];
        for (uint256 i; i < badOffsets.length; ++i) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
            ledger.scheduleDayStart(badOffsets[i], 20261004);
            assertEq(ledger.dayStartCheckpointCount(), 0);
        }

        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.DayStartScheduled(20261004, 20261003, 14400, 18000, 1791090000, address(this));
        ledger.scheduleDayStart(18000, 20261004);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(21600, 20261005);
        assertEq(ledger.dayStartCheckpointCount(), 1);
        vm.warp(1791000000 - 1); // Last second before transition day 2026-10-03 begins.
        vm.expectEmit(true, true, false, true, address(ledger));
        emit TSVVolumeLedgerV1.DayStartCancelled(20261004, address(this));
        ledger.cancelPendingDayStart();
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(DAY), historicalStart);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function testScheduleLocksExactlyAtTransitionStartAndCannotCancelAfterActivation() public {
        ledger.scheduleDayStart(18000, 20261004);
        uint64 transitionStart = ledger.dayStartUTC(20261003);
        vm.warp(transitionStart);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart();
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(21600, 20261005);
        vm.warp(ledger.dayStartUTC(20261004));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart();
        assertEq(ledger.dayStartCheckpointCount(), 1);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(14400, 20261004);
        assertEq(ledger.dayStartCheckpointCount(), 1);
    }

    function testCheckpointLookupPreservesEarlierOffsetsAfterMultipleChanges() public {
        ledger.scheduleDayStart(18000, 20261004);
        vm.warp(1791090000);
        ledger.scheduleDayStart(3600, 20261007);
        vm.warp(1791334800); // 2026-10-07 01:00 UTC.
        ledger.scheduleDayStart(14400, 20261010);
        assertEq(ledger.dayStartCheckpointCount(), 3);
        assertEq(ledger.dayStartUTC(20261001), 1790827200);
        assertEq(ledger.dayStartUTC(20261004), 1791090000);
        assertEq(ledger.dayStartUTC(20261007), 1791334800);
        assertEq(ledger.dayStartUTC(20261010), 1791604800);
        assertEq(ledger.dayStartUTC(20261011), 1791691200);
    }
}
