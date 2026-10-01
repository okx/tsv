// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRecoveryContext} from "tsv-v1/governance/TSVBusinessAuthority.sol";

/// @dev Exposes the implementation address of a governed proxy.
interface ITSVImplementationView {
    /// @notice Returns the current logic address stored by a TSV proxy.
    function tsvImplementation() external view returns (address);
}

/// @dev Exposes the governance anchor linked to the upgrade timelock.
interface ITimelockAnchorView {
    /// @notice Returns the currently active Governance Anchor.
    function governanceAnchor() external view returns (address);

    /// @notice Returns the candidate Anchor nominated for initial binding or migration.
    function nominatedAnchor() external view returns (address);
}

/// @dev Exposes the proxy list and status maintained by the governance anchor.
interface IAnchorProxyListView {
    /// @notice Returns the Timelock associated with the Anchor.
    function timelock() external view returns (address);

    /// @notice Returns whether the Anchor has permanently bound its six business proxies.
    function proxiesBound() external view returns (bool);

    /// @notice Returns the business proxy stored at `index`.
    function proxies(uint256 index) external view returns (address);
}

/// @notice Narrow immediate upgrade route for a pre-approved set of TSV proxies.
contract TSVEmergencyUpgradeController {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the requested operation is not valid in the current state or callback context.
    error InvalidOperation();
    /// @dev Reverts when emergency upgrades are frozen.
    error UpgradeFrozen();

    address public governor;
    address public guardian;
    address public immutable upgradeTimelock;
    bool public frozen = true;
    uint256 public freezeEpoch;
    bytes32 public freezeId;
    mapping(address => bool) public upgradeTargetAllowed;
    mapping(bytes32 => bool) public usedUpgradeActionId;

    /// @notice Emitted when the emergency upgrade target and implementation were changed.
    event UpgradeTargetChanged(address indexed proxy, bool allowed);
    /// @notice Emitted when an emergency implementation upgrade was executed.
    event EmergencyUpgradeExecuted(
        address indexed proxy,
        address oldImplementation,
        address newImplementation,
        bytes32 indexed upgradeActionId,
        bytes32 incidentId,
        bytes32 initDataHash,
        bytes32 evidenceHash
    );
    /// @notice Emitted when emergency upgrades were frozen.
    event EmergencyUpgradesFrozen(bytes32 indexed freezeId, uint256 epoch, bytes32 incidentId);
    /// @notice Emitted when emergency upgrades were unfrozen.
    event EmergencyUpgradesUnfrozen(bytes32 indexed freezeId, bytes32 evidenceHash);

    /// @notice Sets initial emergency-upgrade identities and freezes upgrades until explicitly unfrozen.
    /// @param governor_ Initial Governor authorized to execute emergency upgrades.
    /// @param guardian_ Initial Guardian authorized to freeze emergency upgrades.
    /// @param timelock_ Timelock that controls target configuration, unfreezing, and protected recovery.
    constructor(address governor_, address guardian_, address timelock_) {
        if (governor_ == address(0) || guardian_ == address(0) || timelock_ == address(0) || governor_ == guardian_) {
            revert InvalidOperation();
        }
        governor = governor_;
        guardian = guardian_;
        upgradeTimelock = timelock_;
    }

    /// @notice Allows or disallows emergency upgrades for one of the six Anchor-bound business proxies.
    /// @param proxy Proxy whose emergency-upgrade eligibility is changed.
    /// @param allowed Whether the proxy may be upgraded through this controller.
    function setUpgradeTarget(address proxy, bool allowed) external {
        if (msg.sender != upgradeTimelock) revert Unauthorized();
        if (proxy.code.length == 0 || !_isBoundBusinessProxy(proxy)) revert InvalidOperation();
        ITSVImplementationView(proxy).tsvImplementation();
        upgradeTargetAllowed[proxy] = allowed;
        emit UpgradeTargetChanged(proxy, allowed);
    }

    /// @notice Performs an immediate implementation upgrade when the emergency route is unfrozen.
    /// @param proxy Bound business proxy to upgrade.
    /// @param newImplementation Replacement implementation contract.
    /// @param initData Optional upgrade-and-call payload for the new implementation.
    /// @param incidentId Nonzero identifier for the incident requiring the upgrade.
    /// @param upgradeActionId Unique, single-use identifier for this upgrade action.
    /// @param reasonCode Nonzero reason code describing the emergency action.
    /// @param evidenceHash Nonzero digest of the supporting evidence.
    function executeEmergencyUpgrade(
        address proxy,
        address newImplementation,
        bytes calldata initData,
        bytes32 incidentId,
        bytes32 upgradeActionId,
        bytes32 reasonCode,
        bytes32 evidenceHash
    ) external {
        if (msg.sender != governor) revert Unauthorized();
        if (frozen) revert UpgradeFrozen();
        if (
            !upgradeTargetAllowed[proxy] || !_isBoundBusinessProxy(proxy) || newImplementation.code.length == 0
                || incidentId == 0 || upgradeActionId == 0 || usedUpgradeActionId[upgradeActionId] || reasonCode == 0
                || evidenceHash == 0
        ) revert InvalidOperation();
        address oldImplementation = ITSVImplementationView(proxy).tsvImplementation();
        if (oldImplementation == newImplementation || oldImplementation.code.length == 0) revert InvalidOperation();
        usedUpgradeActionId[upgradeActionId] = true;
        (bool success, bytes memory returndata) =
            proxy.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImplementation, initData));
        if (!success) {
            assembly ("memory-safe") { revert(add(returndata, 32), mload(returndata)) }
        }
        if (ITSVImplementationView(proxy).tsvImplementation() != newImplementation) revert InvalidOperation();
        emit EmergencyUpgradeExecuted(
            proxy, oldImplementation, newImplementation, upgradeActionId, incidentId, keccak256(initData), evidenceHash
        );
    }

    /// @notice Freezes emergency upgrades and creates a unique freeze ID for the current freeze epoch.
    /// @param incidentId Nonzero incident identifier.
    /// @param reasonHash Nonzero digest of the freeze rationale.
    /// @param freezeSalt Nonzero salt preventing reuse of an identical freeze ID.
    function freezeEmergencyUpgrades(bytes32 incidentId, bytes32 reasonHash, bytes32 freezeSalt) external {
        if (msg.sender != guardian) revert Unauthorized();
        if (frozen || incidentId == 0 || reasonHash == 0 || freezeSalt == 0) revert InvalidOperation();
        frozen = true;
        freezeEpoch++;
        freezeId = keccak256(abi.encode(block.chainid, address(this), freezeEpoch, guardian, incidentId, freezeSalt));
        if (freezeId == 0) revert InvalidOperation();
        emit EmergencyUpgradesFrozen(freezeId, freezeEpoch, incidentId);
    }

    /// @notice Unfreezes emergency upgrades only for the currently active freeze ID.
    /// @param expectedFreezeId Freeze ID the Timelock expects to close.
    /// @param evidenceHash Nonzero digest authorizing the unfreeze.
    function unfreezeEmergencyUpgrades(bytes32 expectedFreezeId, bytes32 evidenceHash) external {
        if (msg.sender != upgradeTimelock) revert Unauthorized();
        if (!frozen || freezeId != expectedFreezeId || evidenceHash == 0) revert InvalidOperation();
        frozen = false;
        emit EmergencyUpgradesUnfrozen(freezeId, evidenceHash);
    }

    /// @notice Replaces the Governor only inside a protected Timelock recovery context.
    /// @param expectedOldGovernor Governor address that must still be current.
    /// @param newGovernor Replacement Governor; cannot equal the Guardian.
    /// @param evidenceHash Nonzero digest of the recovery evidence.
    function setGovernor(address expectedOldGovernor, address newGovernor, bytes32 evidenceHash) external {
        _requireRecovery();
        if (
            governor != expectedOldGovernor || newGovernor == address(0) || newGovernor == guardian || evidenceHash == 0
        ) revert InvalidOperation();
        governor = newGovernor;
    }

    /// @notice Replaces the Guardian only inside a protected Timelock recovery context.
    /// @param expectedOldGuardian Guardian address that must still be current.
    /// @param newGuardian Replacement Guardian; cannot equal the Governor.
    /// @param evidenceHash Nonzero digest of the recovery evidence.
    function setGuardian(address expectedOldGuardian, address newGuardian, bytes32 evidenceHash) external {
        _requireRecovery();
        if (
            guardian != expectedOldGuardian || newGuardian == address(0) || newGuardian == governor || evidenceHash == 0
        ) revert InvalidOperation();
        guardian = newGuardian;
    }

    /// @dev Requires both the configured Timelock caller and its active recovery execution context.
    function _requireRecovery() private view {
        if (msg.sender != upgradeTimelock || !IRecoveryContext(upgradeTimelock).recoveryContextActive()) {
            revert Unauthorized();
        }
    }

    /// @dev Resolves the active or nominated Anchor and checks all binding conditions before trusting its proxy list.
    /// @param proxy Address to compare with the Anchor's six registered business proxies.
    /// @return Whether `proxy` is one of the bound business proxies.
    function _isBoundBusinessProxy(address proxy) private view returns (bool) {
        ITimelockAnchorView timelock = ITimelockAnchorView(upgradeTimelock);
        address anchor = timelock.governanceAnchor();
        if (anchor == address(0)) {
            anchor = timelock.nominatedAnchor();
            if (anchor.code.length == 0) return false;
            address currentTimelock = IAnchorProxyListView(anchor).timelock();
            if (currentTimelock == address(0) || ITimelockAnchorView(currentTimelock).governanceAnchor() != anchor) {
                return false;
            }
        }
        if (anchor.code.length == 0) return false;

        IAnchorProxyListView proxyList = IAnchorProxyListView(anchor);
        if (!proxyList.proxiesBound()) return false;
        for (uint256 i; i < 6; ++i) {
            if (proxyList.proxies(i) == proxy) return true;
        }
        return false;
    }
}
