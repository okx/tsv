// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketReport, AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {ReportValidationLib} from "tsv-v1/libraries/ReportValidationLib.sol";

/// @notice Validates signed-off market and volume reports before forwarding them to TSV state contracts.
/// @dev DataInbox owns the ingress layer: reporter roles, report-ID replay protection and source-time freshness
///      checks. Registry owns security operation pause state. VolumeLedger owns ADTV, quota, split-factor and
///      volume-limit
///      state. DataInbox reads roles from Registry instead of duplicating AccessControl, and Ledger accept
///      functions only allow DataInbox to write so callers cannot bypass ingress validation.
contract TSVDataInboxV1 is Initializable, UUPSUpgradeable {
    error UnauthorizedUpgrade();

    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");
    bytes32 public constant HALT_REPORTER_ROLE = keccak256("HALT_REPORTER_ROLE");
    bytes32 public constant VOLUME_ORACLE_ROLE = keccak256("VOLUME_ORACLE_ROLE");

    /// @dev Reverts when the caller is not an authorized report submitter.
    error UnauthorizedReporter();
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();

    /// @dev Bounded to keep a monthly report submission within block gas limits.
    uint256 public constant MAX_ADTV_BATCH_SIZE = 100;
    /// @dev Independent source-time stream for market status reports.
    uint8 private constant REPORT_KIND_MARKET_STATUS = 0;
    /// @dev Independent source-time stream for monthly ADTV reports.
    uint8 private constant REPORT_KIND_ADTV = 1;
    /// @dev Independent source-time stream for daily quota override reports.
    uint8 private constant REPORT_KIND_QUOTA = 2;
    /// @dev Independent source-time stream for split-factor reports.
    uint8 private constant REPORT_KIND_SPLIT_FACTOR = 3;

    /// @notice Registry used for reporter roles and market-status transitions.
    TSVRegistryV1 public registry;
    /// @notice VolumeLedger used for ADTV, quota and split-factor storage.
    TSVVolumeLedgerV1 public ledger;
    /// @notice Whether a globally unique report ID has already been consumed.
    mapping(bytes32 => bool) public reportIdUsed;
    /// @notice Last accepted source timestamp by report kind and security.
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSourceTimestamp;

    /// @dev Locks the implementation; proxy storage is initialized separately.
    constructor() {
        _disableInitializers();
    }

    /// @dev Upgrade authorization is managed exclusively by the Registry.
    function _authorizeUpgrade(address) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
    }

    /// @notice Binds the Registry for permissions and the Volume Ledger for report storage.
    /// @param registry_ Registry that receives market-status transitions.
    /// @param ledger_ Volume Ledger that stores ADTV and quota reports.
    function initialize(address registry_, address ledger_) external initializer {
        if (registry_.code.length == 0 || ledger_.code.length == 0) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    /// @notice Validates and records the next security operation report for a listed security.
    /// @dev Flow: cheap payload checks, _accept with REPORT_KIND_MARKET_STATUS and HALT_REPORTER_ROLE, then
    ///      Registry.applySecurityStatus. Registry checks that msg.sender is DataInbox, the security is listed,
    ///      and the pause mode actually changes. Report order is checked by source timestamp in DataInbox.
    /// @param report Market action, reason code, source timestamps and report ID.
    function submitMarketStatus(MarketReport calldata report) external {
        if (report.securityId == 0 || report.mode == SecurityPauseMode.NONE || report.reasonCode == 0) {
            revert InvalidReport();
        }
        _accept(
            REPORT_KIND_MARKET_STATUS,
            report.securityId,
            HALT_REPORTER_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.reportId
        );
        registry.applySecurityStatus(report.securityId, report.action, report.mode, report.reportId);
    }

    /// @notice Validates and accepts one monthly ADTV report.
    /// @dev Flow: _submitAdtv, _accept with REPORT_KIND_ADTV and VOLUME_ORACLE_ROLE, then
    ///      Ledger.acceptAdtv. Ledger performs business validation such as listed security, valid month and
    ///      nonzero ADTV before storing the value.
    /// @param report Security, source month, ADTV value, and source metadata.
    function submitAdtv(AdtvReport calldata report) external {
        _submitAdtv(report);
    }

    /// @notice Atomically accepts the monthly ADTV reports for multiple securities.
    /// @dev Reports must use the same source month, each securityId must be nonzero, and securityId values must
    ///      be strictly ascending to avoid duplicates and unordered batches. Each item still reuses _submitAdtv,
    ///      so every report has its own reportId and sourceTimestamp checks. Any failure reverts the
    ///      whole batch, including entries already processed earlier in the loop.
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
    ///      Used by both single-report and batch ADTV entry points.
    /// @param report ADTV report being accepted.
    function _submitAdtv(AdtvReport calldata report) private {
        _accept(
            REPORT_KIND_ADTV,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.reportId
        );
        ledger.acceptAdtv(report);
    }

    /// @notice Validates and accepts a quota override for one security and trade day.
    /// @dev Flow: _accept with REPORT_KIND_QUOTA and VOLUME_ORACLE_ROLE, then Ledger.acceptQuota. Ledger performs
    ///      the quota-specific business checks, including listed security and hard-cap constraints.
    /// @param report Quota action, target day, and source metadata.
    function submitQuota(QuotaReport calldata report) external {
        _accept(
            REPORT_KIND_QUOTA,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.reportId
        );
        ledger.acceptQuota(report);
    }

    /// @notice Schedules, corrects or cancels a split factor at a future trade-day start.
    /// @dev Flow: _accept with REPORT_KIND_SPLIT_FACTOR and VOLUME_ORACLE_ROLE, then Ledger.acceptSplitFactor.
    ///      Ledger validates split-factor semantics, including that the effective trade day is in the future.
    /// @param report Source-month-relative factor and the announcement's effective trade day.
    function submitSplitFactor(SplitFactorReport calldata report) external {
        _accept(
            REPORT_KIND_SPLIT_FACTOR,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.reportId
        );
        ledger.acceptSplitFactor(report);
    }

    /// @dev Enforces reporter authorization and shared report freshness and uniqueness rules.
    ///      The common ingress checks are:
    ///      1. msg.sender must have the required role in Registry.
    ///      2. reportId must be nonzero and unused.
    ///      3. sourceTimestamp must not move backwards for this kind and security.
    ///      4. sourceTimestamp must not be in the future.
    ///      5. block.timestamp must not exceed submitDeadline.
    ///      6. lastSourceTimestamp and reportIdUsed are written.
    ///      If the later Registry or Ledger call reverts, these writes are reverted with the whole transaction.
    /// @param kind Report category used to maintain independent ordering state.
    /// @param key Security identifier whose reports are being ordered.
    /// @param role Role required from the submitting address.
    /// @param sourceTimestamp Time at which the source data was produced.
    /// @param submitDeadline Last timestamp at which the report may be submitted.
    /// @param reportId Globally unique nonzero report identifier.
    function _accept(
        uint8 kind,
        bytes32 key,
        bytes32 role,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        bytes32 reportId
    ) private {
        if (!registry.hasRole(role, msg.sender)) revert UnauthorizedReporter();
        ReportValidationLib.validate(
            lastSourceTimestamp[kind][key],
            reportIdUsed[reportId],
            sourceTimestamp,
            submitDeadline,
            reportId,
            block.timestamp
        );
        lastSourceTimestamp[kind][key] = sourceTimestamp;
        reportIdUsed[reportId] = true;
    }
}
