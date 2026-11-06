// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev Adds a stateful upgrade initializer to test atomic upgrade-and-call.
contract V1RegistryUpgradeMock is TSVRegistryV1 {
    error UpgradeInitFailed();
    uint256 public upgradeMarker;

    function initializeV2(uint256 marker, bool fail) external reinitializer(2) onlyRole(UPGRADE_ADMIN_ROLE) {
        upgradeMarker = marker;
        if (fail) revert UpgradeInitFailed();
    }
}
