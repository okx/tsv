// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Shared UUPS and role-control base for TSV business proxies.
/// @dev The current Governor upgrades in one transaction while the fixed Anchor's global upgrade switch is open.
abstract contract TSVGoverned is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Reverts when the caller is not authorized to upgrade this contract.
    error UnauthorizedUpgrade();
    /// @dev Reverts when the Guardian has frozen every upgrade entry point.
    error UpgradeFrozen();
    /// @dev Reverts when the requested role change targets a protected role.
    error ProtectedRole();
    /// @dev Reverts when the governance contract addresses or links are invalid.
    error InvalidGovernance();

    bytes32 public constant SYMBOL_ADMIN_ROLE = keccak256("SYMBOL_ADMIN_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant HALT_REPORTER_ROLE = keccak256("HALT_REPORTER_ROLE");
    bytes32 public constant VOLUME_ORACLE_ROLE = keccak256("VOLUME_ORACLE_ROLE");
    bytes32 public constant EMERGENCY_PAUSER_ROLE = keccak256("EMERGENCY_PAUSER_ROLE");
    bytes32 public constant EMERGENCY_RESUMER_ROLE = keccak256("EMERGENCY_RESUMER_ROLE");
    bytes32 public constant REVOKE_EXIT_EXECUTOR_ROLE = keccak256("REVOKE_EXIT_EXECUTOR_ROLE");
    bytes32 public constant FORCE_EXIT_ADMIN_ROLE = keccak256("FORCE_EXIT_ADMIN_ROLE");
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    TSVGovernanceAnchor public governanceAnchor;

    /// @dev Locks the implementation contract; proxy instances initialize their own storage.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes role storage and verifies the supplied governance root matches the configured identities.
    /// @param anchor_ Governance Anchor that stores the active Governor and global upgrade switch.
    function __TSVGoverned_init(address anchor_) internal onlyInitializing {
        if (anchor_.code.length == 0) revert InvalidGovernance();
        TSVGovernanceAnchor root = TSVGovernanceAnchor(anchor_);
        address governor = root.governor();
        address guardian = root.guardian();
        address council = root.recoveryCouncil();
        if (
            governor == address(0) || guardian == address(0) || council == address(0) || governor == guardian
                || governor == council || guardian == council
        ) {
            revert InvalidGovernance();
        }
        __AccessControl_init();
        governanceAnchor = root;
    }

    /// @dev Restricts the function to the Governor currently stored in the fixed Anchor.
    modifier onlyGovernor() {
        if (msg.sender != governanceAnchor.governor()) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        _;
    }

    /// @notice Checks a role, resolving the default admin dynamically to the current Governor.
    /// @param role Role identifier being queried.
    /// @param account Account whose role membership is queried.
    /// @return Whether the account currently holds the role.
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            return account != address(0) && account == governanceAnchor.governor();
        }
        return super.hasRole(role, account);
    }

    /// @notice Grants a business role; the default-admin role remains anchored to the Governor.
    /// @param role Role identifier to grant.
    /// @param account Account receiving the role.
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.grantRole(role, account);
    }

    /// @notice Revokes a business role; the default-admin role cannot be changed through AccessControl.
    /// @param role Role identifier to revoke.
    /// @param account Account losing the role.
    function revokeRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.revokeRole(role, account);
    }

    /// @notice Renounces a business role while protecting the Governor-controlled default-admin role.
    /// @param role Role identifier to renounce.
    /// @param account Account renouncing the role; AccessControl requires it to equal the caller.
    function renounceRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.renounceRole(role, account);
    }

    /// @dev Rejects internal attempts to assign the protected default-admin role.
    /// @param role Role identifier to grant.
    /// @param account Account receiving the role.
    /// @return Whether membership changed.
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._grantRole(role, account);
    }

    /// @dev Rejects internal attempts to revoke the protected default-admin role.
    /// @param role Role identifier to revoke.
    /// @param account Account losing the role.
    /// @return Whether membership changed.
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._revokeRole(role, account);
    }

    /// @dev Allows the Governor or its active Anchor batch only while global upgrades are unfrozen.
    function _authorizeUpgrade(address) internal view virtual override {
        if (
            msg.sender != governanceAnchor.governor()
                && !(msg.sender == address(governanceAnchor) && governanceAnchor.upgradeContextActive())
        ) {
            revert UnauthorizedUpgrade();
        }
        if (governanceAnchor.upgradesFrozen()) revert UpgradeFrozen();
    }
}
