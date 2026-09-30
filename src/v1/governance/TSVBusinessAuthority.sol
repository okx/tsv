// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRecoveryContext {
    function recoveryContextActive() external view returns (bool);
}

/// @notice Shared business root. The multisig is represented by one address.
contract TSVBusinessAuthority {
    error Unauthorized();
    error InvalidAddress();
    error StaleGovernor();

    address public governor;
    address public immutable upgradeTimelock;

    event BusinessGovernorRecovered(address indexed oldGovernor, address indexed newGovernor, bytes32 evidenceHash);

    constructor(address governor_, address upgradeTimelock_) {
        if (governor_ == address(0) || upgradeTimelock_ == address(0)) revert InvalidAddress();
        governor = governor_;
        upgradeTimelock = upgradeTimelock_;
    }

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
