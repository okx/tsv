// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";

/// @dev Exposes the governance anchor bound to a core proxy.
interface IAnchoredProxyV1 {
    /// @notice Returns the fixed Anchor address stored by a business proxy.
    function governanceAnchor() external view returns (address);
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

    /// @notice Returns the Router's configured Volume Ledger.
    function ledger() external view returns (address);

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

/// @notice Fixed governance root for all six business proxies. A migration needs Council and current Guardian.
contract TSVGovernanceAnchor {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the proposed governance-root bundle is incomplete or inconsistent.
    error InvalidBundle();
    /// @dev Reverts when the proposal is unknown, stale, expired, or not approved for execution.
    error InvalidProposal();

    /// @dev Stores the proposed governance root migration and its approval state.
    struct Proposal {
        /// @dev Candidate upgrade timelock.
        TSVUpgradeTimelock timelock;
        /// @dev Candidate business authority.
        TSVBusinessAuthority authority;
        /// @dev Candidate emergency upgrade controller.
        TSVEmergencyUpgradeController controller;
        /// @dev Governance-root epoch captured when the proposal was created.
        uint64 epoch;
        /// @dev Guardian epoch captured when the proposal was created.
        uint64 guardianEpoch;
        /// @dev Digest of the evidence supporting this migration.
        bytes32 evidenceHash;
        /// @dev Whether the proposal remains available for approval or execution.
        bool active;
        /// @dev Whether the current Guardian approved the proposal.
        bool approved;
    }

    TSVUpgradeTimelock public timelock;
    TSVBusinessAuthority public authority;
    TSVEmergencyUpgradeController public controller;
    address public guardian;
    address public immutable recoveryCouncil;
    uint64 public epoch;
    uint64 public guardianEpoch;
    bool public proxiesBound;
    address[6] public proxies;
    mapping(bytes32 => Proposal) public proposals;

    /// @notice Emitted when the six business proxies were bound to the governance anchor.
    event ProxiesBound(address[6] proxies);
    /// @notice Emitted when a governance root migration was proposed.
    event RootProposed(
        bytes32 indexed id, address timelock, address authority, address controller, bytes32 evidenceHash
    );
    /// @notice Emitted when a guardian approval for a root migration was added or revoked.
    event RootApprovalChanged(bytes32 indexed id, bool approved);
    /// @notice Emitted when a pending governance root migration was cancelled.
    event RootCancelled(bytes32 indexed id);
    /// @notice Emitted when the governance root was migrated to the approved addresses.
    event RootMigrated(bytes32 indexed id, uint64 epoch, address timelock, address authority, address controller);
    /// @notice Emitted when the governance anchor guardian was synchronized.
    event GuardianSynced(address indexed oldGuardian, address indexed newGuardian, uint64 guardianEpoch);

    /// @notice Fixes the initial governance bundle and records the Council and Guardian recovery authorities.
    /// @param timelock_ Initial upgrade and recovery Timelock.
    /// @param authority_ Initial business authority contract.
    /// @param controller_ Initial emergency upgrade controller.
    constructor(address timelock_, address authority_, address controller_) {
        if (timelock_ == address(0) || authority_ == address(0) || controller_ == address(0)) revert InvalidBundle();
        timelock = TSVUpgradeTimelock(payable(timelock_));
        authority = TSVBusinessAuthority(authority_);
        controller = TSVEmergencyUpgradeController(controller_);
        guardian = timelock.guardian();
        recoveryCouncil = timelock.recoveryCouncil();
        _validateBundle(timelock, authority, controller, false);
    }

    /// @notice Permanently binds and cross-checks the six business proxy addresses.
    /// @dev Array order is Registry, Ledger, DataInbox, Hook, Router, and LP Manager.
    /// @param addresses Six deployed business proxies in the required component order.
    function bindProxies(address[6] calldata addresses) external {
        if (msg.sender != authority.governor() || proxiesBound) revert Unauthorized();
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
                || IRouterLinksV1(addresses[4]).ledger() != addresses[1]
                || ILpLinksV1(addresses[5]).registry() != addresses[0]
                || IHookLinksV1(addresses[3]).poolManager() != IRouterLinksV1(addresses[4]).poolManager()
                || IHookLinksV1(addresses[3]).poolManager() != ILpLinksV1(addresses[5]).poolManager()
        ) revert InvalidBundle();
        proxiesBound = true;
        emit ProxiesBound(addresses);
    }

    /// @notice Proposes a replacement governance bundle for Council and Guardian approval.
    /// @param newTimelock Candidate upgrade Timelock.
    /// @param newAuthority Candidate business authority.
    /// @param newController Candidate emergency upgrade controller.
    /// @param salt Nonzero salt making this proposal ID unique.
    /// @param evidenceHash Nonzero digest of the migration evidence.
    /// @return id Proposal ID binding the current epochs and candidate root addresses.
    function proposeRoot(
        address newTimelock,
        address newAuthority,
        address newController,
        bytes32 salt,
        bytes32 evidenceHash
    ) external returns (bytes32 id) {
        if (msg.sender != recoveryCouncil || salt == 0 || evidenceHash == 0 || !proxiesBound) {
            revert Unauthorized();
        }
        if (
            newTimelock == address(timelock) || newAuthority == address(authority)
                || newController == address(controller)
        ) revert InvalidBundle();
        id = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                epoch,
                guardianEpoch,
                newTimelock,
                newAuthority,
                newController,
                salt,
                evidenceHash
            )
        );
        if (proposals[id].active) revert InvalidProposal();
        TSVUpgradeTimelock candidate = TSVUpgradeTimelock(payable(newTimelock));
        TSVBusinessAuthority candidateAuthority = TSVBusinessAuthority(newAuthority);
        TSVEmergencyUpgradeController candidateController = TSVEmergencyUpgradeController(newController);
        _validateBundle(candidate, candidateAuthority, candidateController, true);
        proposals[id] = Proposal(
            candidate, candidateAuthority, candidateController, epoch, guardianEpoch, evidenceHash, true, false
        );
        emit RootProposed(id, newTimelock, newAuthority, newController, evidenceHash);
    }

    /// @notice Approves a current-epoch root proposal as the current Guardian.
    /// @param id Proposal ID to approve.
    function approveRoot(bytes32 id) external {
        if (msg.sender != guardian) revert Unauthorized();
        Proposal storage p = proposals[id];
        if (!p.active || p.epoch != epoch || p.guardianEpoch != guardianEpoch) revert InvalidProposal();
        p.approved = true;
        emit RootApprovalChanged(id, true);
    }

    /// @notice Revokes the current Guardian's approval for a root proposal.
    /// @param id Proposal ID whose approval is revoked.
    function revokeRootApproval(bytes32 id) external {
        if (msg.sender != guardian || !proposals[id].approved) revert Unauthorized();
        proposals[id].approved = false;
        emit RootApprovalChanged(id, false);
    }

    /// @notice Cancels an active root proposal as the Recovery Council.
    /// @param id Proposal ID to cancel.
    function cancelRoot(bytes32 id) external {
        if (msg.sender != recoveryCouncil || !proposals[id].active) revert Unauthorized();
        proposals[id].active = false;
        emit RootCancelled(id);
    }

    /// @notice Activates an approved, current-epoch governance bundle and advances the root epoch.
    /// @param id Proposal ID to execute.
    function executeRoot(bytes32 id) external {
        Proposal storage p = proposals[id];
        if (!p.active || !p.approved || p.epoch != epoch || p.guardianEpoch != guardianEpoch) {
            revert InvalidProposal();
        }
        _validateBundle(p.timelock, p.authority, p.controller, true);
        if (address(p.timelock.governanceAnchor()) != address(0) || p.timelock.nominatedAnchor() != address(this)) {
            revert InvalidBundle();
        }
        p.active = false;
        ++epoch;
        timelock = p.timelock;
        authority = p.authority;
        controller = p.controller;
        p.timelock.activateGovernanceAnchor(address(this));
        emit RootMigrated(id, epoch, address(timelock), address(authority), address(controller));
    }

    /// @notice Synchronizes a Guardian rotation completed by the bound Timelock recovery flow.
    /// @param oldGuardian Guardian address currently stored by this Anchor.
    /// @param newGuardian Guardian address now stored by the Timelock and controller.
    function syncGuardian(address oldGuardian, address newGuardian) external {
        if (
            msg.sender != address(timelock) || !timelock.recoveryContextActive() || guardian != oldGuardian
                || newGuardian == address(0) || timelock.guardian() != newGuardian
                || controller.guardian() != newGuardian
        ) revert Unauthorized();
        guardian = newGuardian;
        ++guardianEpoch;
        emit GuardianSynced(oldGuardian, newGuardian, guardianEpoch);
    }

    /// @dev Checks governance identities, reciprocal Timelock/controller references, and optional proxy bindings.
    /// @param tl Candidate Timelock to validate.
    /// @param ba Candidate business authority to validate.
    /// @param ec Candidate emergency controller to validate.
    /// @param requireBound Whether the candidate must already be bound to this Anchor and all six proxies.
    function _validateBundle(
        TSVUpgradeTimelock tl,
        TSVBusinessAuthority ba,
        TSVEmergencyUpgradeController ec,
        bool requireBound
    ) private view {
        if (
            address(tl).code.length == 0 || address(ba).code.length == 0 || address(ec).code.length == 0
                || address(tl) == address(ba) || address(tl) == address(ec) || address(ba) == address(ec)
                || ba.upgradeTimelock() != address(tl) || ec.upgradeTimelock() != address(tl)
                || ba.governor() != tl.governor() || ec.governor() != tl.governor() || ec.guardian() != guardian
                || tl.guardian() != guardian || tl.recoveryCouncil() != recoveryCouncil || !ec.frozen()
                || !tl.hasRole(tl.PROPOSER_ROLE(), tl.governor()) || !tl.hasRole(tl.CANCELLER_ROLE(), guardian)
                || !tl.hasRole(tl.EXECUTOR_ROLE(), recoveryCouncil) || !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl))
        ) revert InvalidBundle();
        if (requireBound) {
            if (
                address(tl.businessAuthority()) != address(ba) || address(tl.emergencyController()) != address(ec)
                    || tl.nominatedAnchor() != address(this) || !proxiesBound
            ) revert InvalidBundle();
            for (uint256 i; i < 6; ++i) {
                if (
                    !ec.upgradeTargetAllowed(proxies[i]) || proxies[i].code.length == 0
                        || IAnchoredProxyV1(proxies[i]).governanceAnchor() != address(this)
                ) revert InvalidBundle();
            }
        }
    }
}
