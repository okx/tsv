// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Minimal ABI of Securitize IDSBlackListManager, compatible with this compiler version.
interface IBlacklistStatus {
    function isBlacklisted(address account) external view returns (bool);
}
