// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Shared UUPS and role-control base for TSV business proxies.
/// @dev The Governor is resolved through the fixed Governance Anchor; upgrade authority is limited to the Timelock and emergency controller.
abstract contract TSVGoverned is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Reverts when the caller is not authorized to upgrade this contract.
    error UnauthorizedUpgrade();
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

    TSVGovernanceAnchor public governanceAnchor;

    /// @dev Locks the implementation contract; proxy instances initialize their own storage.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes role storage and verifies the supplied governance root matches the configured bundle.
    /// @param anchor_ Governance Anchor that resolves the active authority and upgrade controllers.
    /// @param timelock_ Expected upgrade Timelock address.
    /// @param controller_ Expected emergency upgrade controller address.
    function __TSVGoverned_init(address anchor_, address timelock_, address controller_) internal onlyInitializing {
        if (anchor_.code.length == 0 || timelock_ == address(0) || controller_ == address(0)) {
            revert InvalidGovernance();
        }
        TSVGovernanceAnchor root = TSVGovernanceAnchor(anchor_);
        if (address(root.timelock()) != timelock_ || address(root.controller()) != controller_) {
            revert InvalidGovernance();
        }
        __AccessControl_init();
        governanceAnchor = root;
    }

    /// @notice Returns the currently active business authority through the Governance Anchor.
    /// @return Current Governor authority contract.
    function businessAuthority() public view returns (TSVBusinessAuthority) {
        return governanceAnchor.authority();
    }

    /// @notice Returns the currently active upgrade Timelock through the Governance Anchor.
    /// @return Current Timelock address.
    function upgradeTimelock() public view returns (address) {
        return address(governanceAnchor.timelock());
    }

    /// @notice Returns the currently active emergency upgrade controller through the Governance Anchor.
    /// @return Current emergency controller address.
    function emergencyUpgradeController() public view returns (address) {
        return address(governanceAnchor.controller());
    }

    /// @dev Restricts the function to the Governor currently stored in the anchored business authority.
    modifier onlyGovernor() {
        if (msg.sender != governanceAnchor.authority().governor()) {
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
            return account != address(0) && account == governanceAnchor.authority().governor();
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

    /// @dev Allows UUPS upgrades only when called by the anchored Timelock or emergency controller.
    function _authorizeUpgrade(address) internal view virtual override {
        if (msg.sender != address(governanceAnchor.timelock()) && msg.sender != address(governanceAnchor.controller())) revert UnauthorizedUpgrade();
    }
}
