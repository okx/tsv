// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

abstract contract TSVGoverned is AccessControlUpgradeable, UUPSUpgradeable {
    error UnauthorizedUpgrade();
    error ProtectedRole();
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

    constructor() {
        _disableInitializers();
    }

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

    function businessAuthority() public view returns (TSVBusinessAuthority) {
        return governanceAnchor.authority();
    }

    function upgradeTimelock() public view returns (address) {
        return address(governanceAnchor.timelock());
    }

    function emergencyUpgradeController() public view returns (address) {
        return address(governanceAnchor.controller());
    }

    modifier onlyGovernor() {
        if (msg.sender != governanceAnchor.authority().governor()) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        _;
    }

    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            return account != address(0) && account == governanceAnchor.authority().governor();
        }
        return super.hasRole(role, account);
    }

    function grantRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.renounceRole(role, account);
    }

    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal view virtual override {
        if (msg.sender != address(governanceAnchor.timelock()) && msg.sender != address(governanceAnchor.controller())) revert UnauthorizedUpgrade();
    }
}
