// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig,
    PermissionedAdmission,
    AssetStatus,
    PoolConfig,
    SecurityConfig
} from "tsv-v1/types/TSVTypes.sol";

/// @notice Shared W/U/Q interface. Asset records use the canonical TSVTypes definitions.
interface ITSVPermissionedRegistry {
    function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory);
    function getUnderlying(address u) external view returns (UnderlyingConfig memory);
    function getQuoteToken(address q) external view returns (QuoteTokenConfig memory);
    function getPool(bytes32 id) external view returns (PoolConfig memory);
    function getSecurity(bytes32 id) external view returns (SecurityConfig memory);
    function isTradable(bytes32 id) external view returns (bool);
    function isPermissionedOwnerApproved(address owner) external view returns (bool);
    function exitAdminOf(address w) external view returns (address);
    function exitAdminVersion(address w) external view returns (uint64);
    function permissionsAdapterFactory() external view returns (address);
    function permissionedPoolManager() external view returns (address);
    function permissionedRouter() external view returns (address);
    function permissionedAllowlistChecker() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function hook() external view returns (address);
    function lpManager() external view returns (address);
    function dataInbox() external view returns (address);
    function governanceAnchor() external view returns (address);
    function participantSbt() external view returns (address);
    function sbtTokenId() external view returns (uint256);
    function marketSequence(bytes32 id) external view returns (uint64);

    function admitPermissionedSecurity(uint8 tierId, PermissionedAdmission calldata admission) external;
    function registerPermissionedCurrency(PermissionedAdmission calldata admission) external;
    function registerQuoteToken(address q) external;
    function setPermissionedCurrencyStatus(address w, AssetStatus status) external;
    function setQuoteTokenStatus(address q, AssetStatus status) external;
    function setPermissionedOwnerApproval(address owner, bool approved) external;
    function updatePermissionedExpectedOwner(address w, address newOwner) external;
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter) external;
    function setExitAdmin(address w, address newAdmin) external;
    function bindPermissionedComponents(address factory, address router) external;
}
