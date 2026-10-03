// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OperationsHandler} from "../../../helpers/v1/OperationsHandler.sol";

contract TSVStatefulOperationsTest is Test {
    OperationsHandler internal handler;

    function setUp() public {
        handler = new OperationsHandler();
        handler.initializeModel();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.submitAdtv.selector;
        selectors[1] = handler.submitQuota.selector;
        selectors[2] = handler.charge.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.schedule.selector;
        selectors[5] = handler.cancel.selector;
        selectors[6] = handler.toggleReporter.selector;
        selectors[7] = handler.submitFactor.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantCalendarMatchesIndependentModelAndHistoryIsStable() public view {
        handler.assertCalendarModel();
    }

    function invariantReportsCapsReplayProtectionAndUsedMatchModel() public view {
        handler.assertReportModel();
    }

    function testModelTraversesReportCorrectionsRoleFailuresAndLongShortDayChanges() public {
        handler.submitAdtv(0, 1000e18, 0);
        handler.charge(1e18);
        handler.submitQuota(0, 5e17, false, 0);
        handler.charge(1);
        handler.submitQuota(0, 0, true, 0);
        handler.submitAdtv(0, 400e18, 0);
        handler.charge(1);
        handler.toggleReporter();
        handler.submitAdtv(1, 1000e18, 0);
        handler.toggleReporter();
        handler.submitAdtv(1, 1000e18, 0);
        handler.submitAdtv(2, 1000e18, 6); // Cross-period duplicate ID.
        handler.schedule(28800, 3, false);
        handler.cancel(false);
        handler.schedule(0, 3, false);
        handler.advanceTime(3 days);
        handler.cancel(false); // Transition has started; cancellation must fail.
        handler.advanceTime(3 days);
        handler.schedule(14400, 3, false);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // November uses the already supplied October ADTV.
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // December fails closed before November ADTV arrives.
        handler.submitAdtv(2, 1000e18, 0);
        handler.charge(1);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // January requires December ADTV, including across the year boundary.
        handler.submitAdtv(3, 1000e18, 0);
        handler.charge(1);
        handler.assertCalendarModel();
        handler.assertReportModel();
        assertGt(handler.successfulReports(), 0);
        assertGt(handler.rejectedReports(), 0);
        assertGt(handler.successfulCharges(), 0);
        assertGt(handler.rejectedCharges(), 0);
    }

    function testModelCombinesFutureFactorsCorrectionsCancellationsDayStartsAndMonthRollover() public {
        handler.submitAdtv(0, 1000e18, 0);
        handler.charge(1e18);
        handler.submitFactor(1, 1, 0, false, 0); // 2/1, October 2.
        handler.submitFactor(4, 5, 0, false, 0); // 6/1, October 5.
        handler.submitFactor(1, 2, 0, false, 0); // Cannot correct an intermediate checkpoint.
        handler.submitFactor(4, 0, 0, true, 0);
        handler.schedule(28800, 3, false);
        handler.advanceTime(1 days);
        handler.submitFactor(1, 0, 0, true, 0); // Activated checkpoint is locked.
        handler.charge(3e18);
        handler.submitQuota(1, 4e18, false, 0);
        handler.charge(2e18); // Absolute quota 4, not automatically doubled to 8.
        handler.submitFactor(4, 0, 4, false, 0); // Reverse split 1/5.
        handler.toggleReporter();
        handler.submitFactor(5, 2, 0, false, 0);
        handler.toggleReporter();
        handler.submitFactor(5, 2, 0, false, 6); // Replay a report ID across streams.
        handler.advanceTime(4 days);
        handler.charge(5e17);
        handler.submitAdtv(1, 2000e18, 0);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(3e18); // November uses a new ADTV basis and default factor 1.
        handler.assertCalendarModel();
        handler.assertReportModel();
    }
}
