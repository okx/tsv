// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pure validation shared by market, ADTV and quota report ingress.
library ReportValidationLib {
    error InvalidReport();
    error Expired();

    function validate(
        uint64 previousSequence,
        uint64 previousSourceTimestamp,
        bool reportIdUsed,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        bytes32 sourceHash,
        uint256 currentTimestamp
    ) internal pure {
        if (
            reportId == 0 || sourceHash == 0 || reportIdUsed || sequence <= previousSequence
                || sourceTimestamp < previousSourceTimestamp
        ) revert InvalidReport();
        if (sourceTimestamp > currentTimestamp || currentTimestamp > submitDeadline) revert Expired();
    }
}
