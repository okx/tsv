// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @dev Observable external side effect used to prove whole-transaction rollback.
contract MigrationJournal {
    uint256 public entries;

    function record() external {
        ++entries;
    }
}

/// @dev Example V2 migration: append storage and authorize Governor or an active Anchor batch.
abstract contract GovernanceMigrationV2 is Initializable {
    error MigrationFailed();
    error UnauthorizedMigration();
    uint256 public migrationMarker;
    address public migrationCaller;

    function initializeV2(uint256 marker, bool fail) external reinitializer(2) {
        _migrate(marker);
        if (fail) revert MigrationFailed();
    }

    function initializeAndRecord(MigrationJournal journal, uint256 marker) external reinitializer(2) {
        _migrate(marker);
        journal.record();
    }

    function initializeWithCall(address target, bytes calldata data) external reinitializer(2) {
        _migrate(1);
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function _migrate(uint256 marker) private {
        TSVGovernanceAnchor root = TSVGoverned(address(this)).governanceAnchor();
        if (msg.sender != root.governor() && !(msg.sender == address(root) && root.upgradeContextActive())) {
            revert UnauthorizedMigration();
        }
        migrationMarker = marker;
        migrationCaller = msg.sender;
    }
}

contract RegistryV2 is TSVRegistryV1, GovernanceMigrationV2 {}

contract LedgerV2 is TSVVolumeLedgerV1, GovernanceMigrationV2 {}

contract InboxV2 is TSVDataInboxV1, GovernanceMigrationV2 {}

contract HookV2 is TSVHookV1, GovernanceMigrationV2 {}

contract RouterV2 is TSVSwapRouterV1, GovernanceMigrationV2 {
    constructor(address pm, address factory) TSVSwapRouterV1(pm, factory) {}
}

contract LPManagerV2 is TSVLPManagerV1, GovernanceMigrationV2 {}

contract WrongUUIDImplementation {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Exposes the protected internal role paths without changing production visibility.
contract GovernedRoleHarness is TSVGoverned {
    function initialize(address root) external initializer {
        __TSVGoverned_init(root);
    }

    function internalGrant(bytes32 role, address account) external onlyGovernor {
        _grantRole(role, account);
    }

    function internalRevoke(bytes32 role, address account) external onlyGovernor {
        _revokeRole(role, account);
    }
}

/// @dev Contract Governor fixture. The callback is explicitly armed only for reentry tests.
contract GovernorExecutor {
    address public immutable owner;
    address public callbackProxy;

    constructor(address owner_) {
        owner = owner_;
    }

    function armCallback(address proxy) external {
        require(msg.sender == owner);
        callbackProxy = proxy;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner || msg.sender == callbackProxy, "executor: unauthorized");
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}
