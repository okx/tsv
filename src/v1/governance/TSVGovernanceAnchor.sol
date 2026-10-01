// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";

interface IAnchoredProxyV1 {
    function governanceAnchor() external view returns (address);
}

interface IRegistryLinksV1 {
    function hook() external view returns (address);
    function lpManager() external view returns (address);
    function dataInbox() external view returns (address);
}

interface ILedgerLinksV1 {
    function registry() external view returns (address);
    function hook() external view returns (address);
    function dataInbox() external view returns (address);
}

interface IInboxLinksV1 {
    function registry() external view returns (address);
    function ledger() external view returns (address);
}

interface IHookLinksV1 {
    function registry() external view returns (address);
    function ledger() external view returns (address);
    function router() external view returns (address);
    function lpManager() external view returns (address);
    function poolManager() external view returns (address);
}

interface IRouterLinksV1 {
    function registry() external view returns (address);
    function ledger() external view returns (address);
    function poolManager() external view returns (address);
}

interface ILpLinksV1 {
    function registry() external view returns (address);
    function poolManager() external view returns (address);
}

/// @notice Fixed governance root for all six business proxies. A migration needs Council and current Guardian.
contract TSVGovernanceAnchor {
    error Unauthorized();
    error InvalidBundle();
    error InvalidProposal();

    struct Proposal {
        TSVUpgradeTimelock timelock;
        TSVBusinessAuthority authority;
        TSVEmergencyUpgradeController controller;
        uint64 epoch;
        uint64 guardianEpoch;
        bytes32 evidenceHash;
        bool active;
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

    event ProxiesBound(address[6] proxies);
    event RootProposed(
        bytes32 indexed id, address timelock, address authority, address controller, bytes32 evidenceHash
    );
    event RootApprovalChanged(bytes32 indexed id, bool approved);
    event RootCancelled(bytes32 indexed id);
    event RootMigrated(bytes32 indexed id, uint64 epoch, address timelock, address authority, address controller);
    event GuardianSynced(address indexed oldGuardian, address indexed newGuardian, uint64 guardianEpoch);

    constructor(address timelock_, address authority_, address controller_) {
        if (timelock_ == address(0) || authority_ == address(0) || controller_ == address(0)) revert InvalidBundle();
        timelock = TSVUpgradeTimelock(payable(timelock_));
        authority = TSVBusinessAuthority(authority_);
        controller = TSVEmergencyUpgradeController(controller_);
        guardian = timelock.guardian();
        recoveryCouncil = timelock.recoveryCouncil();
        _validateBundle(timelock, authority, controller, false);
    }

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

    function approveRoot(bytes32 id) external {
        if (msg.sender != guardian) revert Unauthorized();
        Proposal storage p = proposals[id];
        if (!p.active || p.epoch != epoch || p.guardianEpoch != guardianEpoch) revert InvalidProposal();
        p.approved = true;
        emit RootApprovalChanged(id, true);
    }

    function revokeRootApproval(bytes32 id) external {
        if (msg.sender != guardian || !proposals[id].approved) revert Unauthorized();
        proposals[id].approved = false;
        emit RootApprovalChanged(id, false);
    }

    function cancelRoot(bytes32 id) external {
        if (msg.sender != recoveryCouncil || !proposals[id].active) revert Unauthorized();
        proposals[id].active = false;
        emit RootCancelled(id);
    }

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
