// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsCapCorrectionsTest is OperationsFixture {
    function testAdtvCorrectionClampsExistingQuotaAndPreservesConsumedVolume() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        inbox.submitAdtv(_adtv(SECURITY, 400e18, 2, keccak256("lower-adtv")));
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        assertEq(ledger.quotaOf(SECURITY, DAY), 2e18);
        bytes32 beforeState = _reportState(keccak256("unrelated"));
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _charge(1);
        assertEq(_reportState(keccak256("unrelated")), beforeState);
        inbox.submitAdtv(_adtv(SECURITY, 2000e18, 3, keccak256("raise-adtv")));
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1e18); // Quota 2, not the raised hard cap 5.
        inbox.submitQuota(_quota(0, 2, 2, keccak256("clear")));
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 4e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function testTierPolicyCorrectionImmediatelyChangesCapWithoutResettingUsedOrQuota() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        registry.setTierPolicy(1, 5, 10);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _charge(1);
        registry.setTierPolicy(1, 100, 10);
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.quotaOf(SECURITY, DAY), 2e18);
    }

    function testAcceptedReportsDoNotExpireWithSubmissionDeadline() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        vm.warp(block.timestamp + 101);
        _charge(1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1e18);
    }

    function testFuzzHardCapUsesFloorAndExactLimitIsAllowed(uint192 adtv, uint16 bps) public {
        adtv = uint192(bound(adtv, 1, 1e24));
        bps = uint16(bound(bps, 1, 10000));
        registry.setTierPolicy(1, bps, 10);
        _submitAdtv(adtv);
        uint256 expected = uint256(adtv) * bps / 10000;
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertEq(valid, expected != 0);
        assertEq(left, expected);
        if (expected == 0) {
            vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
            _charge(1);
        } else {
            _charge(expected);
            assertEq(ledger.used(SECURITY, DAY), expected);
            vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
            _charge(1);
            assertEq(ledger.used(SECURITY, DAY), expected);
        }
    }

    function testFutureDayQuotaDoesNotChangeCurrentDayAndRequiresApplicableMonth() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        QuotaReport memory r = _quota(1e18, 1, 1, keccak256("future-quota"));
        r.tradeDayId = 20261002;
        inbox.submitQuota(r);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1.5e18);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 1e18);
        (valid, left) = ledger.remaining(SECURITY, 20261101);
        assertFalse(valid);
        assertEq(left, 0);
        AdtvReport memory nextMonth = _adtv(SECURITY, 1000e18, 2, keccak256("next-adtv"));
        nextMonth.sourceMonth = 202610;
        inbox.submitAdtv(nextMonth);
        (valid, left) = ledger.remaining(SECURITY, 20261101);
        assertTrue(valid);
        assertEq(left, 2.5e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }
}
