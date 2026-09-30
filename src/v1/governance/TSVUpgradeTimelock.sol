// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";

/// @notice Per-operation delay with a separately protected authority recovery route.
contract TSVUpgradeTimelock is TimelockController {
    error Unauthorized();
    error ProtectedOperation(bytes32 operationId);
    error InvalidRecovery();

    address public governor;
    address public guardian;
    address public immutable recoveryCouncil;
    TSVBusinessAuthority public businessAuthority;
    TSVEmergencyUpgradeController public emergencyController;
    mapping(bytes32 => bool) public protectedRecovery;
    bytes32 private activeRecoveryId;

    event BusinessAuthorityBound(address indexed authority);
    event EmergencyControllerBound(address indexed controller);
    event AuthoritiesRecovered(
        address indexed oldGovernor, address indexed newGovernor, address indexed newGuardian, bytes32 evidenceHash
    );

    constructor(address governor_, address guardian_, address council_, address[] memory executors)
        TimelockController(0, _proposers(governor_, council_), executors, address(0))
    {
        if (
            governor_ == address(0) || guardian_ == address(0) || council_ == address(0) || governor_ == guardian_
                || council_ == governor_ || council_ == guardian_
        ) revert InvalidRecovery();
        governor = governor_;
        guardian = guardian_;
        recoveryCouncil = council_;
        _revokeRole(CANCELLER_ROLE, governor_);
        _revokeRole(CANCELLER_ROLE, council_);
        _grantRole(CANCELLER_ROLE, guardian_);
        _grantRole(EXECUTOR_ROLE, council_);
    }

    function bindBusinessAuthority(address authority) external {
        if (
            msg.sender != address(this) || address(businessAuthority) != address(0) || authority == address(0)
                || TSVBusinessAuthority(authority).upgradeTimelock() != address(this)
                || TSVBusinessAuthority(authority).governor() != governor
        ) revert InvalidRecovery();
        businessAuthority = TSVBusinessAuthority(authority);
        emit BusinessAuthorityBound(authority);
    }

    function bindEmergencyController(address controller) external {
        if (
            msg.sender != address(this) || address(emergencyController) != address(0) || controller == address(0)
                || TSVEmergencyUpgradeController(controller).upgradeTimelock() != address(this)
                || TSVEmergencyUpgradeController(controller).governor() != governor
                || TSVEmergencyUpgradeController(controller).guardian() != guardian
        ) revert InvalidRecovery();
        emergencyController = TSVEmergencyUpgradeController(controller);
        emit EmergencyControllerBound(controller);
    }

    function recoveryContextActive() external view returns (bool) {
        return activeRecoveryId != 0;
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        if (msg.sender == recoveryCouncil) {
            _validateRecovery(target, value, data, predecessor);
            bytes32 id = hashOperation(target, value, data, predecessor, salt);
            super.schedule(target, value, data, predecessor, salt, delay);
            protectedRecovery[id] = true;
        } else {
            if (msg.sender != governor || _isRecoverySelector(target, data)) revert Unauthorized();
            super.schedule(target, value, data, predecessor, salt, delay);
        }
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        if (msg.sender != governor) revert Unauthorized();
        for (uint256 i; i < targets.length; ++i) {
            if (_isRecoverySelector(targets[i], payloads[i])) revert InvalidRecovery();
        }
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    }

    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
    {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        if (protectedRecovery[id]) {
            _validateRecovery(target, value, payload, predecessor);
            if (activeRecoveryId != 0) revert InvalidRecovery();
            activeRecoveryId = id;
            super.execute(target, value, payload, predecessor, salt);
            activeRecoveryId = 0;
        } else {
            if (_isRecoverySelector(target, payload)) revert InvalidRecovery();
            super.execute(target, value, payload, predecessor, salt);
        }
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override {
        for (uint256 i; i < targets.length; ++i) {
            if (_isRecoverySelector(targets[i], payloads[i])) revert InvalidRecovery();
        }
        super.executeBatch(targets, values, payloads, predecessor, salt);
    }

    function cancel(bytes32 id) public override {
        if (msg.sender != guardian) revert Unauthorized();
        if (protectedRecovery[id]) revert ProtectedOperation(id);
        super.cancel(id);
    }

    function updateDelay(uint256) public pure override {
        revert InvalidRecovery();
    }

    function grantRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.renounceRole(role, account);
    }

    function recoverAuthorities(address newGovernor, address newGuardian, bytes32 evidenceHash) external {
        if (
            msg.sender != address(this) || activeRecoveryId == 0 || evidenceHash == 0 || newGovernor == address(0)
                || newGuardian == address(0) || newGovernor == newGuardian || newGovernor == recoveryCouncil
                || newGuardian == recoveryCouncil || newGovernor == guardian || newGuardian == governor
                || address(businessAuthority) == address(0) || address(emergencyController) == address(0)
        ) {
            revert InvalidRecovery();
        }
        address oldGovernor = governor;
        address oldGuardian = guardian;
        if (newGovernor == oldGovernor && newGuardian == oldGuardian) revert InvalidRecovery();
        if (newGovernor != oldGovernor) {
            businessAuthority.recoverGovernor(oldGovernor, newGovernor, evidenceHash);
            emergencyController.setGovernor(oldGovernor, newGovernor, evidenceHash);
            _grantRole(PROPOSER_ROLE, newGovernor);
            _revokeRole(PROPOSER_ROLE, oldGovernor);
            governor = newGovernor;
        }
        if (newGuardian != oldGuardian) {
            emergencyController.setGuardian(oldGuardian, newGuardian, evidenceHash);
            _grantRole(CANCELLER_ROLE, newGuardian);
            _revokeRole(CANCELLER_ROLE, oldGuardian);
            guardian = newGuardian;
        }
        emit AuthoritiesRecovered(oldGovernor, newGovernor, newGuardian, evidenceHash);
    }

    function _validateRecovery(address target, uint256 value, bytes calldata data, bytes32 predecessor) private view {
        if (
            target != address(this) || value != 0 || predecessor != 0 || data.length != 100
                || !_isRecoverySelector(target, data) || address(businessAuthority) == address(0)
                || address(emergencyController) == address(0)
        ) revert InvalidRecovery();
        (address newGovernor, address newGuardian, bytes32 evidenceHash) =
            abi.decode(data[4:], (address, address, bytes32));
        if (
            newGovernor == address(0) || newGuardian == address(0) || newGovernor == newGuardian
                || newGovernor == recoveryCouncil || newGuardian == recoveryCouncil || newGovernor == guardian
                || newGuardian == governor || evidenceHash == 0 || (newGovernor == governor && newGuardian == guardian)
        ) revert InvalidRecovery();
    }

    function _isRecoverySelector(address target, bytes calldata data) private view returns (bool) {
        return target == address(this) && data.length >= 4 && bytes4(data[:4]) == this.recoverAuthorities.selector;
    }

    function _rejectProtectedRole(bytes32 role) private pure {
        if (role == DEFAULT_ADMIN_ROLE || role == PROPOSER_ROLE || role == CANCELLER_ROLE || role == EXECUTOR_ROLE) {
            revert InvalidRecovery();
        }
    }

    function _proposers(address governor_, address council_) private pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = governor_;
        result[1] = council_;
    }
}
