// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Issuer-specific eligibility for forced LP exits.
interface IStatusQuoter {
    function isUnwindable(address account) external view returns (bool);
}
