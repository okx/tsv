// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction} from "tsv-v1/types/TSVTypes.sol";

/// @notice Source-backed market-state transition submitted through DataInbox.
struct MarketReport {
    /// @notice Listed security affected by the market-state report.
    bytes32 securityId;
    /// @notice Initial state or subsequent halt/resume action.
    MarketAction action;
    /// @notice Nonzero operational reason code included for audit.
    bytes32 reasonCode;
    /// @notice Nonzero digest identifying the exchange or market source.
    bytes32 exchangeHash;
    /// @notice Time when the source produced this market information.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's market reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}

/// @notice Versioned monthly average-daily-volume input for one listed security.
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
    /// @notice Incrementing version for this security and source month.
    uint64 version;
    /// @notice Increasing sequence for this security's ADTV reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}

/// @notice Versioned optional quota override for one security and TSV trade day.
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
    /// @notice Incrementing version for this security and trade day.
    uint64 version;
    /// @notice Increasing sequence for this security's quota reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}
