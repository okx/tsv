// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Exposes the governance anchor bound to a core proxy.
interface IAnchoredProxyV1 {
    /// @notice Returns the fixed Anchor address stored by a business proxy.
    function governanceAnchor() external view returns (address);

    /// @notice Upgrades a business proxy and optionally initializes the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @dev Exposes the component links maintained by the Registry.
interface IRegistryLinksV1 {
    /// @notice Returns the Registry's configured Hook.
    function hook() external view returns (address);

    /// @notice Returns the Registry's configured LP Manager.
    function lpManager() external view returns (address);

    /// @notice Returns the Registry's configured DataInbox.
    function dataInbox() external view returns (address);
}

/// @dev Exposes the Registry, Hook and Inbox links maintained by the Ledger.
interface ILedgerLinksV1 {
    /// @notice Returns the Ledger's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Ledger's configured Hook writer.
    function hook() external view returns (address);

    /// @notice Returns the Ledger's configured DataInbox writer.
    function dataInbox() external view returns (address);
}

/// @dev Exposes the Registry and Ledger links maintained by the data Inbox.
interface IInboxLinksV1 {
    /// @notice Returns the DataInbox's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the DataInbox's configured Volume Ledger.
    function ledger() external view returns (address);
}

/// @dev Exposes the component links maintained by the Hook.
interface IHookLinksV1 {
    /// @notice Returns the Hook's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Hook's configured Volume Ledger.
    function ledger() external view returns (address);

    /// @notice Returns the Hook's authorized Swap Router.
    function router() external view returns (address);

    /// @notice Returns the Hook's authorized LP Manager.
    function lpManager() external view returns (address);

    /// @notice Returns the Hook's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @dev Exposes the component links maintained by the Swap Router.
interface IRouterLinksV1 {
    /// @notice Returns the Router's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Router's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @dev Exposes the component links maintained by the LP Manager.
interface ILpLinksV1 {
    /// @notice Returns the LP Manager's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the LP Manager's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @notice Fixed governance root storing identities and the global upgrade switch for all six business proxies.
contract TSVGovernanceAnchor {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the governance identities or business-proxy bindings are inconsistent.
    error InvalidBundle();
    /// @dev Reverts when the proposal is unknown, stale, expired, or not approved for execution.
    error InvalidProposal();
    /// @dev Reverts when the Guardian has frozen all business-proxy upgrades.
    error UpgradeFrozen();
    /// @dev Reverts when a freeze transition is invalid or references a stale freeze.
    error InvalidFreeze();

    address public governor;
    address public guardian;
    address public immutable recoveryCouncil;
    uint64 public epoch;
    uint64 public guardianEpoch;
    bool public proxiesBound;
    address[6] public proxies;

    /// @dev Captures the identities and epochs approved for an identity recovery.
    struct RecoveryProposal {
        address newGovernor;
        address newGuardian;
        uint64 epoch;
        uint64 guardianEpoch;
        bool active;
        bool approved;
    }

    mapping(bytes32 => RecoveryProposal) public recoveries;
    bool public upgradeContextActive;
    /// @notice Guardian-controlled switch covering every business-proxy upgrade entry point.
    bool public upgradesFrozen;
    /// @notice Monotonically increasing identifier for freeze incidents.
    uint64 public freezeEpoch;
    bytes32 public freezeId;

    event UpgradesFrozen(bytes32 indexed id, address indexed guardian);
    event UpgradesUnfrozen(bytes32 indexed id, address indexed guardian);

    /// @notice Freezes single and batch upgrades. Business operations and recovery remain available.
    function freezeUpgrades() external returns (bytes32 id) {
        if (msg.sender != guardian) revert Unauthorized();
        if (upgradesFrozen) revert InvalidFreeze();
        ++freezeEpoch;
        id = keccak256(abi.encode(block.chainid, address(this), freezeEpoch, guardian));
        freezeId = id;
        upgradesFrozen = true;
        emit UpgradesFrozen(id, msg.sender);
    }

    /// @notice Reopens upgrades only when the current Guardian explicitly resolves the current freeze.
    function unfreezeUpgrades(bytes32 expectedFreezeId) external {
        if (msg.sender != guardian) revert Unauthorized();
        if (!upgradesFrozen || expectedFreezeId != freezeId) revert InvalidFreeze();
        upgradesFrozen = false;
        emit UpgradesUnfrozen(freezeId, msg.sender);
    }

    event BatchUpgraded(address indexed governor, uint256 count);

    /// @notice Upgrades up to six bound business proxies atomically in one Governor transaction.
    /// @dev Upgrade initializers receive this Anchor as msg.sender.
    function upgradeBatch(address[] calldata targets, address[] calldata implementations, bytes[] calldata initData)
        external
    {
        if (msg.sender != governor) revert Unauthorized();
        if (upgradesFrozen) revert UpgradeFrozen();
        if (
            !proxiesBound || upgradeContextActive || targets.length == 0 || targets.length > 6
                || targets.length != implementations.length || targets.length != initData.length
        ) revert InvalidBundle();
        for (uint256 i; i < targets.length; ++i) {
            bool bound;
            for (uint256 j; j < 6; ++j) {
                if (targets[i] == proxies[j]) bound = true;
            }
            if (!bound || implementations[i].code.length == 0) revert InvalidBundle();
            for (uint256 j; j < i; ++j) {
                if (targets[i] == targets[j]) revert InvalidBundle();
            }
        }
        upgradeContextActive = true;
        for (uint256 i; i < targets.length; ++i) {
            IAnchoredProxyV1(targets[i]).upgradeToAndCall(implementations[i], initData[i]);
        }
        upgradeContextActive = false;
        emit BatchUpgraded(msg.sender, targets.length);
    }

    /// @notice Emitted when the six business proxies were bound to the governance anchor.
    event ProxiesBound(address[6] proxies);
    /// @notice Emitted when the governance anchor guardian was synchronized.
    event GuardianSynced(address indexed oldGuardian, address indexed newGuardian, uint64 guardianEpoch);

    /// @notice Sets the initial independent governance identities; the Anchor itself is not upgradeable.
    constructor(address governor_, address guardian_, address recoveryCouncil_) {
        if (
            governor_ == address(0) || guardian_ == address(0) || recoveryCouncil_ == address(0)
                || governor_ == guardian_ || governor_ == recoveryCouncil_ || guardian_ == recoveryCouncil_
        ) revert InvalidBundle();
        guardian = guardian_;
        recoveryCouncil = recoveryCouncil_;
        governor = governor_;
    }

    event RecoveryProposed(bytes32 indexed id, address newGovernor, address newGuardian);
    event RecoveryApprovalChanged(bytes32 indexed id, bool approved);
    event RecoveryCancelled(bytes32 indexed id);
    event AuthoritiesRecovered(address indexed oldGovernor, address indexed newGovernor, address newGuardian);

    /// @notice Permanently binds and cross-checks the six business proxy addresses.
    /// @dev Array order is Registry, Ledger, DataInbox, Hook, Router, and LP Manager.
    /// @param addresses Six deployed business proxies in the required component order.
    function bindProxies(address[6] calldata addresses) external {
        if (msg.sender != governor || proxiesBound) revert Unauthorized();
        for (uint256 i; i < 6; ++i) {
            if (addresses[i].code.length == 0 || IAnchoredProxyV1(addresses[i]).governanceAnchor() != address(this)) {
                revert InvalidBundle();
            }
            for (uint256 j; j < i; ++j) {
                if (addresses[i] == addresses[j]) revert InvalidBundle();
            }
            proxies[i] = addresses[i];
        }
        if (
            IRegistryLinksV1(addresses[0]).hook() != addresses[3]
                || IRegistryLinksV1(addresses[0]).lpManager() != addresses[5]
                || IRegistryLinksV1(addresses[0]).dataInbox() != addresses[2]
                || ILedgerLinksV1(addresses[1]).registry() != addresses[0]
                || ILedgerLinksV1(addresses[1]).hook() != addresses[3]
                || ILedgerLinksV1(addresses[1]).dataInbox() != addresses[2]
                || IInboxLinksV1(addresses[2]).registry() != addresses[0]
                || IInboxLinksV1(addresses[2]).ledger() != addresses[1]
                || IHookLinksV1(addresses[3]).registry() != addresses[0]
                || IHookLinksV1(addresses[3]).ledger() != addresses[1]
                || IHookLinksV1(addresses[3]).router() != addresses[4]
                || IHookLinksV1(addresses[3]).lpManager() != addresses[5]
                || IRouterLinksV1(addresses[4]).registry() != addresses[0]
                || ILpLinksV1(addresses[5]).registry() != addresses[0]
                || IHookLinksV1(addresses[3]).poolManager() != IRouterLinksV1(addresses[4]).poolManager()
                || IHookLinksV1(addresses[3]).poolManager() != ILpLinksV1(addresses[5]).poolManager()
        ) revert InvalidBundle();
        proxiesBound = true;
        emit ProxiesBound(addresses);
    }

    /// @notice Proposes a narrowly scoped Governor/Guardian recovery as the Recovery Council.
    function proposeRecovery(address newGovernor, address newGuardian, bytes32 salt) external returns (bytes32 id) {
        if (msg.sender != recoveryCouncil || salt == 0) revert Unauthorized();
        _validateRecovery(newGovernor, newGuardian);
        id = keccak256(abi.encode(block.chainid, address(this), epoch, guardianEpoch, newGovernor, newGuardian, salt));
        if (recoveries[id].active) revert InvalidProposal();
        recoveries[id] = RecoveryProposal(newGovernor, newGuardian, epoch, guardianEpoch, true, false);
        emit RecoveryProposed(id, newGovernor, newGuardian);
    }

    /// @notice Approves a current recovery as the current Guardian.
    function approveRecovery(bytes32 id) external {
        if (msg.sender != guardian) revert Unauthorized();
        RecoveryProposal storage p = recoveries[id];
        if (!p.active || p.epoch != epoch || p.guardianEpoch != guardianEpoch) revert InvalidProposal();
        p.approved = true;
        emit RecoveryApprovalChanged(id, true);
    }

    /// @notice Revokes the Guardian's approval without cancelling the Council's proposal.
    function revokeRecoveryApproval(bytes32 id) external {
        if (msg.sender != guardian || !recoveries[id].approved) revert Unauthorized();
        recoveries[id].approved = false;
        emit RecoveryApprovalChanged(id, false);
    }

    /// @notice Cancels a pending recovery as the Recovery Council.
    function cancelRecovery(bytes32 id) external {
        if (msg.sender != recoveryCouncil || !recoveries[id].active) revert Unauthorized();
        recoveries[id].active = false;
        emit RecoveryCancelled(id);
    }

    /// @notice Atomically applies a Council-proposed, current-Guardian-approved identity recovery.
    function executeRecovery(bytes32 id) external {
        RecoveryProposal storage p = recoveries[id];
        if (upgradeContextActive || !p.active || !p.approved || p.epoch != epoch || p.guardianEpoch != guardianEpoch) {
            revert InvalidProposal();
        }
        _validateRecovery(p.newGovernor, p.newGuardian);
        p.active = false;
        p.approved = false;
        address oldGovernor = governor;
        address oldGuardian = guardian;
        governor = p.newGovernor;
        if (p.newGuardian != oldGuardian) {
            guardian = p.newGuardian;
            ++guardianEpoch;
            emit GuardianSynced(oldGuardian, guardian, guardianEpoch);
        }
        ++epoch;
        emit AuthoritiesRecovered(oldGovernor, p.newGovernor, p.newGuardian);
    }

    function _validateRecovery(address newGovernor, address newGuardian) private view {
        address currentGovernor = governor;
        if (
            newGovernor == address(0) || newGuardian == address(0) || newGovernor == newGuardian
                || newGovernor == recoveryCouncil || newGuardian == recoveryCouncil || newGovernor == guardian
                || newGuardian == currentGovernor || (newGovernor == currentGovernor && newGuardian == guardian)
        ) revert InvalidBundle();
    }
}
