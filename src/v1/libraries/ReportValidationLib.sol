// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pure validation shared by market, ADTV and quota report ingress.
library ReportValidationLib {
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();

    /// @notice Enforces shared report identity, ordering, freshness, and deadline constraints.
    /// @param previousSequence Last accepted sequence for this report stream.
    /// @param previousSourceTimestamp Last accepted source timestamp for this stream.
    /// @param reportIdUsed Whether the report identifier has already been accepted.
    /// @param sourceTimestamp Timestamp when the source data was produced.
    /// @param submitDeadline Latest timestamp at which this report may be accepted.
    /// @param sequence Sequence supplied by the reporter for this stream.
    /// @param reportId Unique report identifier.
    /// @param currentTimestamp Current block timestamp supplied by the caller.
    function validate(
        uint64 previousSequence,
        uint64 previousSourceTimestamp,
        bool reportIdUsed,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        uint256 currentTimestamp
    ) internal pure {
        if (reportId == 0 || reportIdUsed || sequence <= previousSequence || sourceTimestamp < previousSourceTimestamp) revert InvalidReport();
        if (sourceTimestamp > currentTimestamp || currentTimestamp > submitDeadline) revert Expired();
    }
}
