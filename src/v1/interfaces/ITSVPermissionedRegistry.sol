// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

import {
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig,
    PermissionedAdmission,
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
    function exitAdminOf(address u) external view returns (address);
    function permissionsAdapterFactory() external view returns (address);
    function permissionedPoolManager() external view returns (address);
    function hook() external view returns (address);
    function lpManager() external view returns (address);
    function dataInbox() external view returns (address);
    function governanceAnchor() external view returns (address);
    function participantSbt() external view returns (address);
    function sbtTokenIds() external view returns (uint256[] memory);
    function sbtIdentityConfig(uint256 tokenId) external view returns (bool registered, PermissionFlag permissions);
    function permissionsOf(address owner) external view returns (PermissionFlag);
    function isAllowed(PermissionFlag permission, address account) external view returns (bool);
    function hasIdentity(address owner, uint256 tokenId) external view returns (bool);
    function hasCredential(address owner) external view returns (bool);
    function setSbtConfig(uint256 tokenId, PermissionFlag permissions) external;
    function marketSequence(bytes32 id) external view returns (uint64);

    function admitPermissionedSecurity(uint8 tierId, PermissionedAdmission calldata admission) external;
    function registerPermissionedCurrency(PermissionedAdmission calldata admission) external;
    function registerQuoteToken(address q) external;
    function setPermissionedOwnerApproval(address owner, bool approved) external;
    function updatePermissionedExpectedOwner(address w, address newOwner) external;
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter) external;
    function setExitAdmin(address u, address newAdmin) external;
    function bindComponents(address hook, address lpManager, address dataInbox, address factory, address sbt) external;
}
