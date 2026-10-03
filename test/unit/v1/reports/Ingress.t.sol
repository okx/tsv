// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsIngressTest is OperationsFixture {
    function testEveryReportRejectsInvalidMetadataWithoutConsumingState() public {
        for (uint8 kind; kind < 3; ++kind) {
            uint256 fixture = vm.snapshotState();
            if (kind == 2) _submitAdtv(1000e18);
            ReportMetadata memory accepted = _metadata(1, 1, keccak256(abi.encode("accepted", kind)));
            _callInbox(_reportPayload(kind, accepted));
            for (uint8 fault; fault < 9; ++fault) {
                ReportMetadata memory good = _metadata(3, 2, keccak256(abi.encode("candidate", kind, fault)));
                ReportMetadata memory bad = abi.decode(abi.encode(good), (ReportMetadata));
                bytes4 expected = TSVDataInboxV1.InvalidReport.selector;
                if (fault == 0) {
                    bad.id = 0;
                } else if (fault == 1) {
                    bad.source = 0;
                } else if (fault == 2) {
                    bad.id = accepted.id;
                } else if (fault == 3) {
                    bad.sequence = 0;
                } else if (fault == 4) {
                    bad.sequence = 1;
                } else if (fault == 5) {
                    bad.timestamp = accepted.timestamp - 1;
                } else if (fault == 6) {
                    bad.timestamp = uint64(block.timestamp + 1);
                    expected = TSVDataInboxV1.Expired.selector;
                } else if (fault == 7) {
                    bad.deadline = uint64(block.timestamp - 1);
                    expected = TSVDataInboxV1.Expired.selector;
                } else {
                    bad.timestamp = type(uint64).max;
                    expected = TSVDataInboxV1.Expired.selector;
                }
                bytes32 beforeState = _reportState(bad.id);
                vm.expectRevert(expected);
                _callInbox(_reportPayload(kind, bad));
                assertEq(_reportState(bad.id), beforeState);
            }
            // Equal source time, skipped sequence numbers and deadline equality are valid.
            ReportMetadata memory next = _metadata(3, 2, keccak256(abi.encode("retry", kind)));
            next.deadline = uint64(block.timestamp);
            _callInbox(_reportPayload(kind, next));
            assertEq(inbox.lastSequence(kind, SECURITY), 3);
            assertEq(inbox.lastSourceTimestamp(kind, SECURITY), next.timestamp);
            assertTrue(inbox.reportIdUsed(next.id));
            assertTrue(vm.revertToState(fixture));
        }
    }

    function testReportRolesAreIndependentAndRevocationAppliesToEveryEntry() public {
        address haltReporter = makeAddr("halt-only");
        address volumeReporter = makeAddr("volume-only");
        bytes32 haltRole = inbox.HALT_REPORTER_ROLE();
        bytes32 volumeRole = inbox.VOLUME_ORACLE_ROLE();
        inbox.grantRole(haltRole, haltReporter);
        inbox.grantRole(volumeRole, volumeReporter);
        _submitAdtv(1000e18);
        for (uint8 kind; kind < 4; ++kind) {
            bytes memory payload;
            if (kind == 3) {
                AdtvReport[] memory reports = new AdtvReport[](1);
                reports[0] = _adtv(SECURITY, 1000e18, 2, 2, keccak256("batch-role"));
                payload = abi.encodeCall(TSVDataInboxV1.submitAdtvBatch, (reports));
            } else {
                payload = _reportPayload(
                    kind, _metadata(kind == 1 ? 2 : 1, kind == 1 ? 2 : 1, keccak256(abi.encode("role", kind)))
                );
            }
            address authorized = kind == 0 ? haltReporter : volumeReporter;
            address wrongRole = kind == 0 ? volumeReporter : haltReporter;
            bytes32 role = kind == 0 ? haltRole : volumeRole;
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(wrongRole);
            _callInbox(payload);
            inbox.revokeRole(role, authorized);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(authorized);
            _callInbox(payload);
            inbox.grantRole(role, authorized);
            uint256 snapshot = vm.snapshotState();
            vm.prank(authorized);
            _callInbox(payload);
            assertTrue(vm.revertToState(snapshot));
            vm.prank(authorized);
            inbox.renounceRole(role, authorized);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(authorized);
            _callInbox(payload);
            inbox.grantRole(role, authorized);
        }
    }

    function testReportIdsAreGlobalWhileOrderingIsPerKindAndSecurity() public {
        bytes32 second = keccak256("second-report-security");
        _admitAdditionalSecurity(second, keccak256("SECOND"));
        bytes32 id = keccak256("global-report-id");
        MarketReport memory market = _market(MarketAction.HALT, 10, id);
        inbox.submitMarketStatus(market);
        AdtvReport memory adtv = _adtv(second, 1000e18, 1, 1, id);
        bytes32 beforeState = _reportState(second, uint32(MONTH), DAY, id);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtv(adtv);
        assertEq(_reportState(second, uint32(MONTH), DAY, id), beforeState);
        adtv.reportId = keccak256("second-adtv");
        inbox.submitAdtv(adtv);
        adtv = _adtv(SECURITY, 1000e18, 1, 1, keccak256("first-adtv"));
        inbox.submitAdtv(adtv);
        QuotaReport memory quota = _quota(2e18, 1, 1, 1, adtv.reportId);
        beforeState = _reportState(quota.reportId);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitQuota(quota);
        assertEq(_reportState(quota.reportId), beforeState);
        quota.reportId = keccak256("first-quota");
        inbox.submitQuota(quota);
        assertEq(inbox.lastSequence(0, SECURITY), 10);
        assertEq(inbox.lastSequence(1, SECURITY), 1);
        assertEq(inbox.lastSequence(1, second), 1);
        assertEq(inbox.lastSequence(2, SECURITY), 1);
    }

    function testDirectWritersCannotBypassInboxAuthorization() public {
        AdtvReport memory adtv = _adtv(SECURITY, 1000e18, 1, 1, keccak256("direct"));
        QuotaReport memory quota = _quota(2e18, 1, 1, 1, keccak256("direct-quota"));
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptAdtv(adtv);
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptQuota(quota);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applyMarketStatus(SECURITY, MarketAction.HALT, PauseMode.ALL, 1, keccak256("direct-market"));
        assertFalse(inbox.reportIdUsed(adtv.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).version, 0);
    }
}
