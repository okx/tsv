// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsAdtvBatchTest is OperationsFixture {
    function testBatchRejectsEmptyAndAboveMaximumBeforeAnyWrite() public {
        AdtvReport[] memory reports = new AdtvReport[](0);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        reports = new AdtvReport[](101);
        reports[0] = _adtv(SECURITY, 1000e18, 1, 1, keccak256("too-many"));
        bytes32 beforeState = _reportState(reports[0].reportId);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_reportState(reports[0].reportId), beforeState);
        assertEq(inbox.MAX_ADTV_BATCH_SIZE(), 100);
    }

    function testSingleElementBatchUsesSameRulesAsSingleReport() public {
        AdtvReport[] memory reports = new AdtvReport[](1);
        reports[0] = _adtv(SECURITY, 1000e18, 1, 1, keccak256("one"));
        inbox.submitAdtvBatch(reports);
        reports[0] = _adtv(SECURITY, 500e18, 2, 2, keccak256("one-correction"));
        inbox.submitAdtvBatch(reports);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).value, 500e18);
        assertEq(inbox.lastSequence(1, SECURITY), 2);
    }

    function testMaximumBatchLastFailureRollsBackAllReportsThenRetrySucceeds() public {
        AdtvReport[] memory reports = _batch(100);
        reports[99].version = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        for (uint256 i; i < reports.length; ++i) {
            assertFalse(inbox.reportIdUsed(reports[i].reportId));
            assertEq(inbox.lastSequence(1, reports[i].securityId), 0);
            assertEq(inbox.lastSourceTimestamp(1, reports[i].securityId), 0);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).version, 0);
        }
        reports[99].version = 1;
        inbox.submitAdtvBatch(reports);
        for (uint256 i; i < reports.length; ++i) {
            assertTrue(inbox.reportIdUsed(reports[i].reportId));
            assertEq(inbox.lastSequence(1, reports[i].securityId), 1);
            assertEq(inbox.lastSourceTimestamp(1, reports[i].securityId), reports[i].sourceTimestamp);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).value, reports[i].adtvWad);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).reportId, reports[i].reportId);
        }
    }

    function testBatchRejectsZeroDuplicateDescendingAndMixedMonthAtomically() public {
        AdtvReport[] memory good = _batch(3);
        for (uint8 fault; fault < 4; ++fault) {
            AdtvReport[] memory bad = abi.decode(abi.encode(good), (AdtvReport[]));
            if (fault == 0) {
                bad[1].securityId = 0;
            } else if (fault == 1) {
                bad[1].securityId = bad[0].securityId;
            } else if (fault == 2) {
                AdtvReport memory tmp = bad[1];
                bad[1] = bad[0];
                bad[0] = tmp;
            } else {
                bad[1].sourceMonth = 202610;
            }
            bytes32 beforeState = _batchState(good);
            vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
            inbox.submitAdtvBatch(bad);
            assertEq(_batchState(good), beforeState);
        }
        inbox.submitAdtvBatch(good);
    }

    function testBatchDuplicateReportIdAcrossSecuritiesRollsBackAndCanRetry() public {
        AdtvReport[] memory reports = _batch(3);
        bytes32 originalId = reports[2].reportId;
        reports[2].reportId = reports[0].reportId;
        bytes32 beforeState = _batchState(reports);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_batchState(reports), beforeState);
        reports[2].reportId = originalId;
        inbox.submitAdtvBatch(reports);
        assertTrue(inbox.reportIdUsed(originalId));
    }

    function testFuzzBatchFailureAtEverySmallBatchPositionIsAtomic(uint8 position, bool ingressFault) public {
        position = uint8(bound(position, 0, 2));
        AdtvReport[] memory reports = _batch(3);
        bytes32 beforeState = _batchState(reports);
        if (ingressFault) reports[position].submitDeadline = uint64(block.timestamp - 1);
        else reports[position].adtvWad = 0;
        vm.expectRevert(ingressFault ? TSVDataInboxV1.Expired.selector : TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_batchState(reports), beforeState);
    }

    function _batch(uint256 size) private returns (AdtvReport[] memory reports) {
        registry.setTierPolicy(1, 25, uint32(size + 1), keccak256("batch-capacity"));
        reports = new AdtvReport[](size);
        for (uint256 i; i < size; ++i) {
            bytes32 security = bytes32(i + 1);
            _admitAdditionalSecurity(security, keccak256(abi.encode("batch-symbol", i)));
            reports[i] = _adtv(security, (i + 1) * 1000e18, 1, 1, keccak256(abi.encode("batch-id", i)));
        }
    }

    function _batchState(AdtvReport[] memory reports) private view returns (bytes32 digest) {
        for (uint256 i; i < reports.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest, _reportState(reports[i].securityId, reports[i].sourceMonth, DAY, reports[i].reportId)
                )
            );
        }
    }
}
