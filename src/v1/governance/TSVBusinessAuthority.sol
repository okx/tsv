// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Exposes whether an authorized governance recovery operation is active.
interface IRecoveryContext {
    /// @notice Returns whether the Timelock is currently executing the protected recovery call.
    function recoveryContextActive() external view returns (bool);
}

/// @notice Shared business root. The multisig is represented by one address.
contract TSVBusinessAuthority {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when an address required for recovery is zero or otherwise invalid.
    error InvalidAddress();
    /// @dev Reverts when the expected current Governor does not match the stored Governor.
    error StaleGovernor();

    address public governor;
    address public immutable upgradeTimelock;

    /// @notice Emitted when the business Governor address was changed through protected recovery.
    event BusinessGovernorRecovered(address indexed oldGovernor, address indexed newGovernor, bytes32 evidenceHash);

    /// @notice Sets the initial Governor and the Timelock allowed to recover that address.
    /// @param governor_ Initial business Governor.
    /// @param upgradeTimelock_ Timelock that may recover the Governor during an approved recovery operation.
    constructor(address governor_, address upgradeTimelock_) {
        if (governor_ == address(0) || upgradeTimelock_ == address(0)) revert InvalidAddress();
        governor = governor_;
        upgradeTimelock = upgradeTimelock_;
    }

    /// @notice Replaces the Governor only during the Timelock's protected recovery execution.
    /// @param expectedOldGovernor Governor address that must still be current.
    /// @param newGovernor Replacement business Governor.
    /// @param evidenceHash Nonzero digest of the recovery evidence.
    function recoverGovernor(address expectedOldGovernor, address newGovernor, bytes32 evidenceHash) external {
        if (msg.sender != upgradeTimelock || !IRecoveryContext(upgradeTimelock).recoveryContextActive()) {
            revert Unauthorized();
        }
        if (newGovernor == address(0) || evidenceHash == bytes32(0)) revert InvalidAddress();
        if (governor != expectedOldGovernor || governor == newGovernor) revert StaleGovernor();
        governor = newGovernor;
        emit BusinessGovernorRecovered(expectedOldGovernor, newGovernor, evidenceHash);
    }
}
