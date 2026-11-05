// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Issuer-specific eligibility for forced LP exits.
interface IStatusQuoter {
    function isUnwindable(address account) external view returns (bool);
}
