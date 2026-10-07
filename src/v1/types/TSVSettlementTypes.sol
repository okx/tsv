// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Runtime classification for a single swap; never persisted as asset configuration.
enum SettlementAssetKind {
    PERMISSIONED_STOCK,
    QUOTE_ERC20
}

/// @notice Immutable-for-the-operation settlement policy derived from the Registry and actual contracts.
struct SettlementLegPlan {
    SettlementAssetKind kind;
    address currency;
    address underlying;
    uint8 rawDecimals;
    address expectedOwner;
    uint64 configVersion;
    bytes32 securityId;
    address legalShareAdapter;
    uint32 legalAdapterVersion;
    address exitAdmin;
    uint64 exitAdminVersion;
}
