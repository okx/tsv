// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketReport, AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {ReportValidationLib} from "tsv-v1/libraries/ReportValidationLib.sol";

/// @notice Validates signed-off market and volume reports before forwarding them to TSV state contracts.
contract TSVDataInboxV1 is TSVGoverned {
    /// @dev Reverts when the caller is not an authorized report submitter.
    error UnauthorizedReporter();
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();

    /// @dev Bounded to keep a monthly report submission within block gas limits.
    uint256 public constant MAX_ADTV_BATCH_SIZE = 100;

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    mapping(bytes32 => bool) public reportIdUsed;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSequence;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSourceTimestamp;

    /// @notice Initializes governance and binds the Registry and Volume Ledger.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param registry_ Registry that receives market-status transitions.
    /// @param ledger_ Volume Ledger that stores ADTV and quota reports.
    function initialize(address anchor, address registry_, address ledger_) external initializer {
        __TSVGoverned_init(anchor);
        if (registry_ == address(0) || ledger_ == address(0)) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    /// @notice Validates and records the next market-state report for a listed security.
    /// @param report Market action, reason code, source timestamps, ordering fields and report ID.
    function submitMarketStatus(MarketReport calldata report) external {
        _accept(
            0,
            report.securityId,
            HALT_REPORTER_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId
        );
        if (report.securityId == 0 || report.mode == PauseMode.NONE || report.reasonCode == 0) revert InvalidReport();
        registry.applyMarketStatus(report.securityId, report.action, report.mode, report.sequence, report.reportId);
    }

    /// @notice Validates and accepts one monthly ADTV report.
    /// @param report Security, source month, ADTV value, and source metadata.
    function submitAdtv(AdtvReport calldata report) external {
        _submitAdtv(report);
    }

    /// @notice Atomically accepts the monthly ADTV reports for multiple securities.
    /// @dev Reports must use the same source month and be sorted by unique securityId.
    /// @param reports Reports to accept; the whole batch reverts if any entry is invalid.
    function submitAdtvBatch(AdtvReport[] calldata reports) external {
        if (reports.length == 0 || reports.length > MAX_ADTV_BATCH_SIZE) {
            revert InvalidReport();
        }

        uint32 sourceMonth = reports[0].sourceMonth;
        bytes32 previousSecurityId;
        for (uint256 i; i < reports.length; i++) {
            AdtvReport calldata report = reports[i];
            if (
                report.securityId == 0 || report.sourceMonth != sourceMonth
                    || (i != 0 && uint256(report.securityId) <= uint256(previousSecurityId))
            ) {
                revert InvalidReport();
            }
            _submitAdtv(report);
            previousSecurityId = report.securityId;
        }
    }

    /// @dev Applies common ingress checks and forwards one ADTV report to the Ledger.
    /// @param report ADTV report being accepted.
    function _submitAdtv(AdtvReport calldata report) private {
        _accept(
            1,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId
        );
        ledger.acceptAdtv(report);
    }

    /// @notice Validates and accepts a quota override for one security and trade day.
    /// @param report Quota action, target day, and source metadata.
    function submitQuota(QuotaReport calldata report) external {
        _accept(
            2,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId
        );
        ledger.acceptQuota(report);
    }

    /// @notice Schedules, corrects or cancels a split factor at a future trade-day start.
    /// @param report Source-month-relative factor and the announcement's effective trade day.
    function submitSplitFactor(SplitFactorReport calldata report) external {
        _accept(
            3,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId
        );
        ledger.acceptSplitFactor(report);
    }

    /// @dev Enforces reporter authorization and shared report freshness and uniqueness rules.
    /// @param kind Report category used to maintain independent ordering state.
    /// @param key Security identifier whose reports are being ordered.
    /// @param role Role required from the submitting address.
    /// @param sourceTimestamp Time at which the source data was produced.
    /// @param submitDeadline Last timestamp at which the report may be submitted.
    /// @param sequence Monotonically increasing sequence for this category and security.
    /// @param reportId Globally unique nonzero report identifier.
    function _accept(
        uint8 kind,
        bytes32 key,
        bytes32 role,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId
    ) private {
        if (!hasRole(role, msg.sender)) revert UnauthorizedReporter();
        ReportValidationLib.validate(
            lastSequence[kind][key],
            lastSourceTimestamp[kind][key],
            reportIdUsed[reportId],
            sourceTimestamp,
            submitDeadline,
            sequence,
            reportId,
            block.timestamp
        );
        lastSequence[kind][key] = sequence;
        lastSourceTimestamp[kind][key] = sourceTimestamp;
        reportIdUsed[reportId] = true;
    }
}
