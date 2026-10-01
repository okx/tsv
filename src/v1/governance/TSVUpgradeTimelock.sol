// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Per-operation delay with a separately protected authority recovery route.
contract TSVUpgradeTimelock is TimelockController {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the operation targets a protected governance action.
    error ProtectedOperation(bytes32 operationId);
    /// @dev Reverts when the protected recovery operation or its evidence is invalid.
    error InvalidRecovery();

    address public governor;
    address public guardian;
    address public immutable recoveryCouncil;
    TSVBusinessAuthority public businessAuthority;
    TSVEmergencyUpgradeController public emergencyController;
    TSVGovernanceAnchor public governanceAnchor;
    address public nominatedAnchor;
    mapping(bytes32 => bool) public protectedRecovery;
    mapping(bytes32 => bool) public guardianApprovedRecovery;
    mapping(bytes32 => address) public recoveryApprovalGuardian;
    bytes32 private activeRecoveryId;

    /// @notice Emitted when the business authority contract was bound to the timelock.
    event BusinessAuthorityBound(address indexed authority);
    /// @notice Emitted when the emergency controller contract was bound to the timelock.
    event EmergencyControllerBound(address indexed controller);
    /// @notice Emitted when the governance anchor was bound to the timelock.
    event GovernanceAnchorBound(address indexed anchor);
    /// @notice Emitted when guardian approval for a protected recovery operation changed.
    event RecoveryApprovalChanged(bytes32 indexed operationId, bool approved);
    /// @notice Emitted when the protected Governor and Guardian authorities were recovered.
    event AuthoritiesRecovered(
        address indexed oldGovernor, address indexed newGovernor, address indexed newGuardian, bytes32 evidenceHash
    );

    /// @notice Creates a per-operation Timelock with separate Governor, Guardian, Council, and Executor roles.
    /// @param governor_ Initial proposer of ordinary governance operations.
    /// @param guardian_ Initial canceller and recovery approver.
    /// @param council_ Recovery Council proposer and executor for protected authority recovery.
    /// @param executors Additional addresses allowed to execute ready operations.
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

    /// @notice Binds the matching business authority once through a Timelock self-call.
    /// @param authority Business authority whose Governor matches this Timelock.
    function bindBusinessAuthority(address authority) external {
        if (
            msg.sender != address(this) || address(businessAuthority) != address(0) || authority == address(0)
                || TSVBusinessAuthority(authority).upgradeTimelock() != address(this)
                || TSVBusinessAuthority(authority).governor() != governor
        ) revert InvalidRecovery();
        businessAuthority = TSVBusinessAuthority(authority);
        emit BusinessAuthorityBound(authority);
    }

    /// @notice Binds the matching emergency upgrade controller once through a Timelock self-call.
    /// @param controller Controller whose Governor, Guardian, and Timelock match this contract.
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

    /// @notice Binds the initial Governance Anchor after its governance bundle has been bound.
    /// @param anchor Anchor whose Timelock, authority, and controller match this contract.
    function bindGovernanceAnchor(address anchor) external {
        if (
            msg.sender != address(this) || address(governanceAnchor) != address(0) || anchor.code.length == 0
                || TSVGovernanceAnchor(anchor).timelock() != this
                || address(TSVGovernanceAnchor(anchor).authority()) != address(businessAuthority)
                || address(TSVGovernanceAnchor(anchor).controller()) != address(emergencyController)
        ) revert InvalidRecovery();
        governanceAnchor = TSVGovernanceAnchor(anchor);
        emit GovernanceAnchorBound(anchor);
    }

    /// @notice Activates an Anchor nominated during a root migration.
    /// @param anchor Nominated Anchor with matching Timelock, authority, and controller references.
    function activateGovernanceAnchor(address anchor) external {
        if (
            msg.sender != anchor || nominatedAnchor != anchor || address(governanceAnchor) != address(0)
                || anchor.code.length == 0 || TSVGovernanceAnchor(anchor).timelock() != this
                || address(TSVGovernanceAnchor(anchor).authority()) != address(businessAuthority)
                || address(TSVGovernanceAnchor(anchor).controller()) != address(emergencyController)
        ) revert InvalidRecovery();
        nominatedAnchor = address(0);
        governanceAnchor = TSVGovernanceAnchor(anchor);
        emit GovernanceAnchorBound(anchor);
    }

    /// @notice Nominates an Anchor before it is activated by that Anchor itself.
    /// @param anchor Candidate Governance Anchor contract.
    function nominateGovernanceAnchor(address anchor) external {
        if (msg.sender != address(this) || address(governanceAnchor) != address(0) || anchor.code.length == 0) {
            revert InvalidRecovery();
        }
        nominatedAnchor = anchor;
    }

    /// @notice Approves a pending protected recovery operation as the current Guardian.
    /// @param operationId Timelock operation ID marked as protected recovery.
    function approveRecovery(bytes32 operationId) external {
        if (msg.sender != guardian || !protectedRecovery[operationId] || !isOperationPending(operationId)) {
            revert InvalidRecovery();
        }
        guardianApprovedRecovery[operationId] = true;
        recoveryApprovalGuardian[operationId] = msg.sender;
        emit RecoveryApprovalChanged(operationId, true);
    }

    /// @notice Revokes Guardian approval for a protected recovery operation before execution.
    /// @param operationId Protected operation ID whose approval is revoked.
    function revokeRecoveryApproval(bytes32 operationId) external {
        if (msg.sender != guardian || !guardianApprovedRecovery[operationId]) revert InvalidRecovery();
        guardianApprovedRecovery[operationId] = false;
        delete recoveryApprovalGuardian[operationId];
        emit RecoveryApprovalChanged(operationId, false);
    }

    /// @notice Reports whether protected authority recovery is currently executing.
    /// @return Whether the active recovery operation ID is nonzero.
    function recoveryContextActive() external view returns (bool) {
        return activeRecoveryId != 0;
    }

    /// @notice Schedules an ordinary Governor operation or a narrowly validated Council recovery operation.
    /// @param target Contract that will receive the scheduled call.
    /// @param value Native currency value sent with the call.
    /// @param data Calldata for the target operation.
    /// @param predecessor Operation that must complete first, or zero.
    /// @param salt Salt used to derive the operation ID.
    /// @param delay Requested delay before execution.
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

    /// @notice Schedules a Governor batch after excluding protected recovery selectors.
    /// @param targets Target contracts for each call.
    /// @param values Native currency values sent with each call.
    /// @param payloads Calldata for each target operation.
    /// @param predecessor Operation that must complete first, or zero.
    /// @param salt Salt used to derive the batch operation ID.
    /// @param delay Requested delay before batch execution.
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

    /// @notice Executes a ready operation, requiring current Guardian approval for protected recovery.
    /// @param target Target contract for the call.
    /// @param value Native currency value sent with the call.
    /// @param payload Calldata for the target operation.
    /// @param predecessor Operation that must complete first, or zero.
    /// @param salt Salt used when the operation was scheduled.
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
    {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        if (protectedRecovery[id]) {
            _validateRecovery(target, value, payload, predecessor);
            if (activeRecoveryId != 0 || !guardianApprovedRecovery[id] || recoveryApprovalGuardian[id] != guardian) {
                revert InvalidRecovery();
            }
            guardianApprovedRecovery[id] = false;
            delete recoveryApprovalGuardian[id];
            activeRecoveryId = id;
            super.execute(target, value, payload, predecessor, salt);
            activeRecoveryId = 0;
        } else {
            if (_isRecoverySelector(target, payload)) revert InvalidRecovery();
            super.execute(target, value, payload, predecessor, salt);
        }
    }

    /// @notice Executes a ready batch after excluding protected recovery selectors from all targets.
    /// @param targets Target contracts for each call.
    /// @param values Native currency values sent with each call.
    /// @param payloads Calldata for each target operation.
    /// @param predecessor Operation that must complete first, or zero.
    /// @param salt Salt used when the batch was scheduled.
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

    /// @notice Allows the Guardian to cancel an ordinary operation, but not protected recovery.
    /// @param id Timelock operation ID to cancel.
    function cancel(bytes32 id) public override {
        if (msg.sender != guardian) revert Unauthorized();
        if (protectedRecovery[id]) revert ProtectedOperation(id);
        super.cancel(id);
    }

    /// @notice Rejects global delay changes; each operation supplies its own delay when scheduled.
    function updateDelay(uint256) public pure override {
        revert InvalidRecovery();
    }

    /// @notice Grants roles except the protected Timelock administration and execution roles.
    /// @param role Role identifier to grant.
    /// @param account Account receiving the role.
    function grantRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.grantRole(role, account);
    }

    /// @notice Revokes roles except the protected Timelock administration and execution roles.
    /// @param role Role identifier to revoke.
    /// @param account Account losing the role.
    function revokeRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.revokeRole(role, account);
    }

    /// @notice Rejects renunciation of protected Timelock roles.
    /// @param role Role identifier to renounce.
    /// @param account Account renouncing the role.
    function renounceRole(bytes32 role, address account) public override {
        _rejectProtectedRole(role);
        super.renounceRole(role, account);
    }

    /// @notice Rotates the Governor and/or Guardian during a Council-scheduled, Guardian-approved recovery.
    /// @param newGovernor Replacement Governor address.
    /// @param newGuardian Replacement Guardian address.
    /// @param evidenceHash Nonzero digest of the recovery evidence.
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
            if (address(governanceAnchor) != address(0)) {
                governanceAnchor.syncGuardian(oldGuardian, newGuardian);
            }
        }
        emit AuthoritiesRecovered(oldGovernor, newGovernor, newGuardian, evidenceHash);
    }

    /// @dev Restricts protected recovery to a self-call with the exact authority-rotation payload shape.
    /// @param target Target contract encoded in the operation.
    /// @param value Native currency value encoded in the operation.
    /// @param data Calldata encoded in the operation.
    /// @param predecessor Predecessor operation ID encoded in the operation.
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

    /// @dev Identifies calls to this Timelock's protected `recoverAuthorities` entry point.
    /// @param target Operation target.
    /// @param data Operation calldata.
    /// @return Whether the call targets the protected recovery selector.
    function _isRecoverySelector(address target, bytes calldata data) private view returns (bool) {
        return target == address(this) && data.length >= 4 && bytes4(data[:4]) == this.recoverAuthorities.selector;
    }

    /// @dev Blocks changes to roles that define Timelock administration, proposal, cancellation, or execution.
    /// @param role Role identifier being changed.
    function _rejectProtectedRole(bytes32 role) private pure {
        if (role == DEFAULT_ADMIN_ROLE || role == PROPOSER_ROLE || role == CANCELLER_ROLE || role == EXECUTOR_ROLE) {
            revert InvalidRecovery();
        }
    }

    /// @dev Builds the initial proposer list from the Governor and Recovery Council.
    /// @param governor_ Initial ordinary-operation proposer.
    /// @param council_ Initial protected-recovery proposer.
    /// @return result Two-address proposer array passed to `TimelockController`.
    function _proposers(address governor_, address council_) private pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = governor_;
        result[1] = council_;
    }
}
