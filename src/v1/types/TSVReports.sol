// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SecurityOperationType, SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";

/// @notice Source-backed security operation transition submitted through DataInbox.
struct MarketReport {
    /// @notice Listed security affected by the operation-state report.
    bytes32 securityId;
    /// @notice Halt or resume action; newly registered securities default to open.
    SecurityOperationType action;
    /// @notice Operations paused or resumed: TRADE, LP, or ALL.
    SecurityPauseMode mode;
    /// @notice Nonzero operational reason code included for audit.
    bytes32 reasonCode;
    /// @notice Time when the source produced this market information.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's market reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
}

/// @notice Monthly average-daily-volume input for one listed security.
struct AdtvReport {
    /// @notice Listed security whose hard volume cap uses this report.
    bytes32 securityId;
    /// @notice Calendar month from which the ADTV data was sourced, encoded as YYYYMM.
    uint32 sourceMonth;
    /// @notice Average daily volume converted to legal-share WAD units.
    uint256 adtvWad;
    /// @notice Time when the source produced this ADTV value.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's ADTV reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
}

/// @notice Optional quota override for one security and TSV trade day.
struct QuotaReport {
    /// @notice Listed security whose daily cap is overridden.
    bytes32 securityId;
    /// @notice TSV trade day affected, encoded as YYYYMMDD.
    uint32 tradeDayId;
    /// @notice Ledger action: set an override or clear an active override.
    uint8 action;
    /// @notice Override value in legal-share WAD; zero when clearing.
    uint256 quotaWad;
    /// @notice Time when the source produced this quota instruction.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's quota reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
}

/// @notice Schedules or cancels an absolute split factor relative to one month's ADTV units.
struct SplitFactorReport {
    /// @notice Listed security whose ADTV-derived cap is adjusted.
    bytes32 securityId;
    /// @notice Unchanged ADTV source month, encoded as YYYYMM.
    uint32 sourceMonth;
    /// @notice First YYYYMMDD trade day using the factor; only future day starts are allowed.
    uint32 effectiveTradeDayId;
    /// @notice Schedule/update = 1, cancel the latest pending checkpoint = 2.
    uint8 action;
    /// @notice Absolute cumulative factor numerator relative to the source-month units.
    uint128 numerator;
    /// @notice Absolute cumulative factor denominator; both components are zero when cancelling.
    uint128 denominator;
    /// @notice Time when the source produced this instruction.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's split-factor report stream.
    uint64 sequence;
    /// @notice Globally unique nonzero report identifier.
    bytes32 reportId;
}
