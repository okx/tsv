// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketStatus, MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVReportsTest scenarios; inherited fixtures contain no test functions.
contract TSVReportsTest is FoundationFixture {
    /// @dev Verifies one ADTV batch can include multiple securities.
    function testAdtvBatchAcceptsMultipleSecuritiesInOneSubmission() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        _admitAdditionalSecurity(secondSecurity);

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-batch-a"));
        reports[1] = _adtv(lastSecurity, 2000e18, 1, 1, keccak256("adtv-batch-b"));

        inbox.submitAdtvBatch(reports);

        TSVVolumeLedgerV1.AdtvValue memory first = ledger.adtvOf(firstSecurity, uint32(MONTH));
        TSVVolumeLedgerV1.AdtvValue memory last = ledger.adtvOf(lastSecurity, uint32(MONTH));
        assertEq(first.value, 1000e18);
        assertEq(last.value, 2000e18);
        assertEq(first.version, 1);
        assertEq(last.version, 1);
    }

    /// @dev Verifies an ADTV batch reverts atomically when one report is invalid.
    function testAdtvBatchIsAtomicWhenOneReportIsInvalid() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        _admitAdditionalSecurity(secondSecurity);

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-atomic-a"));
        // Version 2 is invalid because this security has no accepted version 1.
        reports[1] = _adtv(lastSecurity, 2000e18, 2, 1, keccak256("adtv-atomic-b"));

        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);

        assertFalse(inbox.reportIdUsed(reports[0].reportId));
        assertFalse(inbox.reportIdUsed(reports[1].reportId));
        assertEq(ledger.adtvOf(firstSecurity, uint32(MONTH)).version, 0);
        assertEq(ledger.adtvOf(lastSecurity, uint32(MONTH)).version, 0);
    }

    /// @dev Verifies daily quota overrides are optional and clearing one restores the hard cap.
    function testDailyQuotaIsOptionalAndClearRestoresTheHardCap() public {
        _submitAdtv(1000e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);

        QuotaReport memory setReport = _quota(2e18, 1, 1, 1, keccak256("quota-set"));
        inbox.submitQuota(setReport);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2e18);

        QuotaReport memory clearReport = _quota(0, 2, 2, 2, keccak256("quota-clear"));
        inbox.submitQuota(clearReport);
        TSVVolumeLedgerV1.QuotaOverride memory quota = ledger.quotaOf(SECURITY, DAY);
        assertFalse(quota.active);
        assertEq(quota.version, 2);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);
    }

    /// @dev Verifies invalid clears and above-cap quota values revert atomically.
    function testQuotaRejectsInvalidClearAndValuesAboveHardCapAtomically() public {
        _submitAdtv(1000e18);
        QuotaReport memory report = _quota(0, 2, 1, 1, keccak256("clear-without-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(0, 1, 1, 1, keccak256("zero-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(3e18, 1, 1, 1, keccak256("over-hard-cap"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));
        assertEq(inbox.lastSequence(2, SECURITY), 0);
    }

    /// @dev Verifies market reports do not require a heartbeat and cannot be replayed.
    function testMarketReportDoesNotNeedHeartbeatAndReplayFails() public {
        _submitMarket(MarketAction.HALT, 1, keccak256("market-1"));
        vm.warp(block.timestamp + 30 days);
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.HALTED));
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("market-2"));
        report.submitDeadline = uint64(block.timestamp + 1);
        inbox.submitMarketStatus(report);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitMarketStatus(report);
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.OPEN));
    }

    /// @dev Verifies report submission requires a caller with the direct reporter role.
    function testReportsRequireDirectRoleCaller() public {
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("unauthorized"));
        vm.prank(makeAddr("unregistered-reporter"));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitMarketStatus(report);
    }

    function testMarketReportsRejectNoneNoopsAndInvalidActionsAtomically() public {
        _assertMarketPause(PauseMode.NONE, true, true);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.ALL, 1, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.HALT, PauseMode.NONE, 1, TSVDataInboxV1.InvalidReport.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.NONE, 1, TSVDataInboxV1.InvalidReport.selector);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 1);
        _rejectMarketMode(MarketAction.HALT, PauseMode.TRADE, 2, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.LP, 2, TSVRegistryV1.InvalidStatus.selector);
        _assertMarketPause(PauseMode.TRADE, false, true);
        MarketReport memory report = _market(MarketAction.HALT, 2, keccak256("invalid-action"));
        bytes memory payload = abi.encodeCall(TSVDataInboxV1.submitMarketStatus, (report));
        // The action is the second ABI word after the selector. Values outside the new enum must revert.
        assembly ("memory-safe") {
            mstore(add(payload, 68), 2)
        }
        (bool success,) = address(inbox).call(payload);
        assertFalse(success);
        assertFalse(inbox.reportIdUsed(report.reportId));
        assertEq(inbox.lastSequence(0, SECURITY), 1);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 2);
        _assertMarketPause(PauseMode.NONE, true, true);
    }
}
