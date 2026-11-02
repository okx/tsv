// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Shared UUPS and role-control base for TSV business proxies.
/// @dev Default admins manage roles; upgrade admins authorize UUPS upgrades.
abstract contract TSVGoverned is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Reverts when the caller is not authorized to upgrade this contract.
    error UnauthorizedUpgrade();
    /// @dev Reverts when the initial admin is the zero address.
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
    bytes32 public constant WITHDRAW_CLAIM_ROLE = keccak256("WITHDRAW_CLAIM_ROLE");

    /// @dev Locks the implementation contract; proxy instances initialize their own storage.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes proxy roles without an external governance contract.
    function __TSVGoverned_init(address admin) internal onlyInitializing {
        if (admin == address(0)) revert InvalidGovernance();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADE_ADMIN_ROLE, admin);
    }

    /// @dev Only an explicitly authorized upgrade admin may upgrade this proxy.
    function _authorizeUpgrade(address) internal view virtual override {
        if (!hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
    }
}
