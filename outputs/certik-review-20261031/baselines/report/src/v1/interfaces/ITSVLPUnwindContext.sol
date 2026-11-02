// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Trusted LP Manager context used by the Hook to identify authorized forced removals.
interface ITSVLPUnwindContext {
    function isUnwindActive() external view returns (bool);
}
