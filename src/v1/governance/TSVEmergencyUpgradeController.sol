// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRecoveryContext} from "tsv-v1/governance/TSVBusinessAuthority.sol";

interface ITSVImplementationView {
    function tsvImplementation() external view returns (address);
}

interface ITimelockAnchorView {
    function governanceAnchor() external view returns (address);
    function nominatedAnchor() external view returns (address);
}

interface IAnchorProxyListView {
    function timelock() external view returns (address);
    function proxiesBound() external view returns (bool);
    function proxies(uint256 index) external view returns (address);
}

/// @notice Narrow immediate upgrade route for a pre-approved set of TSV proxies.
contract TSVEmergencyUpgradeController {
    error Unauthorized();
    error InvalidOperation();
    error UpgradeFrozen();

    address public governor;
    address public guardian;
    address public immutable upgradeTimelock;
    bool public frozen = true;
    uint256 public freezeEpoch;
    bytes32 public freezeId;
    mapping(address => bool) public upgradeTargetAllowed;
    mapping(bytes32 => bool) public usedUpgradeActionId;

    event UpgradeTargetChanged(address indexed proxy, bool allowed);
    event EmergencyUpgradeExecuted(
        address indexed proxy,
        address oldImplementation,
        address newImplementation,
        bytes32 indexed upgradeActionId,
        bytes32 incidentId,
        bytes32 initDataHash,
        bytes32 evidenceHash
    );
    event EmergencyUpgradesFrozen(bytes32 indexed freezeId, uint256 epoch, bytes32 incidentId);
    event EmergencyUpgradesUnfrozen(bytes32 indexed freezeId, bytes32 evidenceHash);

    constructor(address governor_, address guardian_, address timelock_) {
        if (governor_ == address(0) || guardian_ == address(0) || timelock_ == address(0) || governor_ == guardian_) {
            revert InvalidOperation();
        }
        governor = governor_;
        guardian = guardian_;
        upgradeTimelock = timelock_;
    }

    function setUpgradeTarget(address proxy, bool allowed) external {
        if (msg.sender != upgradeTimelock) revert Unauthorized();
        if (proxy.code.length == 0 || !_isBoundBusinessProxy(proxy)) revert InvalidOperation();
        ITSVImplementationView(proxy).tsvImplementation();
        upgradeTargetAllowed[proxy] = allowed;
        emit UpgradeTargetChanged(proxy, allowed);
    }

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

    function freezeEmergencyUpgrades(bytes32 incidentId, bytes32 reasonHash, bytes32 freezeSalt) external {
        if (msg.sender != guardian) revert Unauthorized();
        if (frozen || incidentId == 0 || reasonHash == 0 || freezeSalt == 0) revert InvalidOperation();
        frozen = true;
        freezeEpoch++;
        freezeId = keccak256(abi.encode(block.chainid, address(this), freezeEpoch, guardian, incidentId, freezeSalt));
        if (freezeId == 0) revert InvalidOperation();
        emit EmergencyUpgradesFrozen(freezeId, freezeEpoch, incidentId);
    }

    function unfreezeEmergencyUpgrades(bytes32 expectedFreezeId, bytes32 evidenceHash) external {
        if (msg.sender != upgradeTimelock) revert Unauthorized();
        if (!frozen || freezeId != expectedFreezeId || evidenceHash == 0) revert InvalidOperation();
        frozen = false;
        emit EmergencyUpgradesUnfrozen(freezeId, evidenceHash);
    }

    function setGovernor(address expectedOldGovernor, address newGovernor, bytes32 evidenceHash) external {
        _requireRecovery();
        if (
            governor != expectedOldGovernor || newGovernor == address(0) || newGovernor == guardian || evidenceHash == 0
        ) revert InvalidOperation();
        governor = newGovernor;
    }

    function setGuardian(address expectedOldGuardian, address newGuardian, bytes32 evidenceHash) external {
        _requireRecovery();
        if (
            guardian != expectedOldGuardian || newGuardian == address(0) || newGuardian == governor || evidenceHash == 0
        ) revert InvalidOperation();
        guardian = newGuardian;
    }

    function _requireRecovery() private view {
        if (msg.sender != upgradeTimelock || !IRecoveryContext(upgradeTimelock).recoveryContextActive()) {
            revert Unauthorized();
        }
    }

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
