// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SecurityOperationType, SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsPayloadTest is OperationsFixture {
    function testMarketFieldsRejectAndSameIdCanBeCorrected() public {
        for (uint8 fault; fault < 5; ++fault) {
            uint256 snapshot = vm.snapshotState();
            MarketReport memory r = _market(SecurityOperationType.HALT, 1, keccak256(abi.encode("market-field", fault)));
            bytes32 id = r.reportId;
            bytes4 expected = TSVDataInboxV1.InvalidReport.selector;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.mode = SecurityPauseMode.NONE;
            } else if (fault == 2) {
                r.reasonCode = 0;
            } else {
                expected = TSVRegistryV1.InvalidStatus.selector;
                if (fault == 3) {
                    r.securityId = keccak256("absent");
                } else {
                    _delistPrimarySecurity();
                }
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, uint32(MONTH), DAY, id);
            vm.expectRevert(expected);
            inbox.submitMarketStatus(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, uint32(MONTH), DAY, id), targetBefore);
            if (fault == 4) registry.relistSecurity(SECURITY);
            r = _market(SecurityOperationType.HALT, 1, id);
            inbox.submitMarketStatus(r);
            assertTrue(inbox.reportIdUsed(id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testAdtvFieldsRejectAndSameIdCanBeCorrected() public {
        uint32[5] memory invalidMonths = [uint32(0), 196912, 202600, 202613, 1000001];
        for (uint8 fault; fault < 9; ++fault) {
            uint256 snapshot = vm.snapshotState();
            AdtvReport memory r = _adtv(SECURITY, 1000e18, 1, keccak256(abi.encode("adtv-field", fault)));
            bytes32 id = r.reportId;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.securityId = keccak256("absent");
            } else if (fault == 2) {
                r.adtvWad = 0;
            } else if (fault < 8) {
                r.sourceMonth = invalidMonths[fault - 3];
            } else {
                _delistPrimarySecurity();
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, r.sourceMonth, DAY, id);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitAdtv(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, r.sourceMonth, DAY, id), targetBefore);
            if (fault == 8) registry.relistSecurity(SECURITY);
            inbox.submitAdtv(_adtv(SECURITY, 1000e18, 1, id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testQuotaFieldsRejectAndSameIdCanBeCorrected() public {
        _submitAdtv(1000e18);
        for (uint8 fault; fault < 10; ++fault) {
            uint256 snapshot = vm.snapshotState();
            QuotaReport memory r = _quota(2e18, 1, 1, keccak256(abi.encode("quota-field", fault)));
            bytes32 id = r.reportId;
            bytes4 expected = TSVVolumeLedgerV1.InvalidReport.selector;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.securityId = keccak256("absent");
            } else if (fault == 2) {
                r.action = 0;
            } else if (fault == 3) {
                r.action = 3;
            } else if (fault == 4) {
                r.quotaWad = 0;
            } else if (fault == 5) {
                r.quotaWad = 2.5e18 + 1;
            } else if (fault == 6) {
                r.tradeDayId = 20261101;
                expected = TSVVolumeLedgerV1.InvalidReport.selector;
            } else if (fault == 7) {
                r.tradeDayId = 20260229;
                expected = TSVVolumeLedgerV1.InvalidPeriod.selector;
            } else if (fault == 8) {
                r.action = 2; // CLEAR without an active SET, even with nonzero amount.
            } else {
                _delistPrimarySecurity();
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, uint32(MONTH), r.tradeDayId, id);
            vm.expectRevert(expected);
            inbox.submitQuota(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, uint32(MONTH), r.tradeDayId, id), targetBefore);
            if (fault == 9) registry.relistSecurity(SECURITY);
            inbox.submitQuota(_quota(2e18, 1, 1, id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testCorrectionsRequireIncreasingSequencesAcrossPeriods() public {
        _submitAdtv(1000e18);
        AdtvReport memory correction = _adtv(SECURITY, 500e18, 2, keccak256("correction"));
        for (uint64 sequence; sequence < 2; ++sequence) {
            correction.sequence = sequence;
            bytes32 beforeState = _reportState(correction.reportId);
            vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
            inbox.submitAdtv(correction);
            assertEq(_reportState(correction.reportId), beforeState);
        }
        correction.sequence = 2;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.AdtvAccepted(SECURITY, uint32(MONTH), 500e18, correction.reportId);
        inbox.submitAdtv(correction);
        AdtvReport memory nextMonth = _adtv(SECURITY, 500e18, 3, keccak256("next-month"));
        nextMonth.sourceMonth = 202610;
        inbox.submitAdtv(nextMonth);
        assertEq(ledger.adtvOf(SECURITY, 202609), 500e18);
        assertEq(ledger.adtvOf(SECURITY, 202610), 500e18);
        assertEq(inbox.lastSequence(1, SECURITY), 3);
        // A fresh ID/sequence may report the same positive value; value equality is not replay protection.
        nextMonth.sequence = 4;
        nextMonth.reportId = keccak256("same-value-new-sequence");
        inbox.submitAdtv(nextMonth);
        assertEq(ledger.adtvOf(SECURITY, 202610), 500e18);
    }

    function testQuotaClearMustBeZeroAndKeepsSequenceAndUsage() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        QuotaReport memory r = _quota(1, 2, 2, keccak256("clear"));
        bytes32 beforeState = _reportState(r.reportId);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(r);
        assertEq(_reportState(r.reportId), beforeState);
        r.quotaWad = 0;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.QuotaAccepted(SECURITY, DAY, 2, 0, r.reportId);
        inbox.submitQuota(r);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(inbox.lastSequence(2, SECURITY), 2);
        assertEq(ledger.quotaOf(SECURITY, DAY), 0);
        r.sequence = 3;
        r.reportId = keccak256("second-clear");
        beforeState = _reportState(r.reportId);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(r);
        assertEq(_reportState(r.reportId), beforeState);
        r.action = 1;
        r.quotaWad = 1.5e18;
        inbox.submitQuota(r);
        assertEq(inbox.lastSequence(2, SECURITY), 3);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0.5e18);
    }
}
