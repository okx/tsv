// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";

contract TSVDataInboxV1 is TSVGoverned {
    error UnauthorizedReporter();
    error InvalidReport();
    error Expired();

    /// @dev Bounded to keep a monthly report submission within block gas limits.
    uint256 public constant MAX_ADTV_BATCH_SIZE = 100;

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    mapping(bytes32 => bool) public reportIdUsed;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSequence;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSourceTimestamp;

    function initialize(address authority, address timelock, address controller, address registry_, address ledger_)
        external
        initializer
    {
        __TSVGoverned_init(authority, timelock, controller);
        if (registry_ == address(0) || ledger_ == address(0)) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    function submitMarketStatus(MarketReport calldata report) external {
        _accept(
            0,
            report.securityId,
            HALT_REPORTER_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        if (report.securityId == 0 || report.reasonCode == 0 || report.exchangeHash == 0) revert InvalidReport();
        registry.applyMarketStatus(report.securityId, report.action, report.sequence, report.reportId);
    }

    function submitAdtv(AdtvReport calldata report) external {
        _submitAdtv(report);
    }

    /// @notice Atomically accepts the monthly ADTV reports for multiple securities.
    /// @dev Reports must use the same source month and be sorted by unique securityId.
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

    function _submitAdtv(AdtvReport calldata report) private {
        _accept(
            1,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        ledger.acceptAdtv(report);
    }

    function submitQuota(QuotaReport calldata report) external {
        _accept(
            2,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        ledger.acceptQuota(report);
    }

    function _accept(
        uint8 kind,
        bytes32 key,
        bytes32 role,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        bytes32 sourceHash
    ) private {
        if (!hasRole(role, msg.sender)) revert UnauthorizedReporter();
        if (
            reportId == 0 || sourceHash == 0 || reportIdUsed[reportId]
                || sequence <= lastSequence[kind][key] || sourceTimestamp < lastSourceTimestamp[kind][key]
        ) {
            revert InvalidReport();
        }
        if (sourceTimestamp > block.timestamp || block.timestamp > submitDeadline) revert Expired();
        lastSequence[kind][key] = sequence;
        lastSourceTimestamp[kind][key] = sourceTimestamp;
        reportIdUsed[reportId] = true;
    }
}
