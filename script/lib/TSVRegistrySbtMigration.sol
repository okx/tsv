// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlag} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

/// @notice One-time SBT replacement for existing TSV registries; adds no storage variables.
/// @dev Upgrade this implementation onto the SAME Registry proxy and pass migrateSbt as migration calldata.
contract TSVRegistrySbtMigration is TSVRegistryV1 {
    event ParticipantSbtMigrated(address indexed previous, address indexed current);

    function migrateSbt(address next) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        require(next != participantSbt && next.code.length != 0, "invalid replacement SBT");
        require(!ISmartWalletSbtV1(next).paused(), "replacement SBT paused");
        ISmartWalletSbtV1(next).verify(address(this), 0); // Validate the Registry's required ABI.
        address previous = participantSbt;
        uint256[] memory identities = this.sbtTokenIds();
        // Identities from the previous issuer cannot authorize users of a different issuer.
        for (uint256 i; i < identities.length; ++i) {
            sbtIdentityConfig[identities[i]].permissions = PermissionFlag.wrap(0x0000);
            emit SbtConfigChanged(next, identities[i], PermissionFlag.wrap(0x0000), bytes32("SBT_MIGRATION"));
        }
        participantSbt = next;
        emit ParticipantSbtMigrated(previous, next);
    }
}
