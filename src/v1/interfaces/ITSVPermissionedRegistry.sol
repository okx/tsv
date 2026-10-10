// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {
    UnderlyingConfig,
    QuoteTokenConfig,
    PermissionedAdmission,
    PoolConfig,
    SecurityConfig,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";

/// @notice Shared W/U/Q interface. Asset records use the canonical TSVTypes definitions.
interface ITSVPermissionedRegistry {
    /// @notice Registers the exact pool key; only the bound LP Manager may call this.
    /// @param key Full Uniswap V4 pool key to admit.
    /// @return poolId Raw pool ID derived from `key`.
    function registerPool(PoolKey calldata key) external returns (bytes32 poolId);

    /// @notice Returns the canonical underlying bound to a permissioned stock adapter.
    /// @param w Permissioned stock adapter address to query.
    /// @return underlying Canonical underlying U, or zero when `w` is unknown.
    function getCurrencyUnderlying(address w) external view returns (address underlying);

    /// @notice Returns the stored canonical underlying configuration.
    /// @param u Canonical underlying address to query.
    /// @return Stored U configuration; unknown underlyings return a default record.
    function getUnderlying(address u) external view returns (UnderlyingConfig memory);

    /// @notice Returns the stored quote token configuration.
    /// @param q Quote token address to query.
    /// @return Stored quote configuration; unknown quotes return a default record.
    function getQuoteToken(address q) external view returns (QuoteTokenConfig memory);

    /// @notice Returns the registered key and permanent security for a pool.
    /// @param id Raw Uniswap V4 pool ID to query.
    /// @return Stored pool record; unknown pools return a default record.
    function getPool(bytes32 id) external view returns (PoolConfig memory);

    /// @notice Returns the stored listing and tier for a security.
    /// @param id Security identifier to query.
    /// @return Stored security record; unknown IDs return a default record.
    function getSecurity(bytes32 id) external view returns (SecurityConfig memory);

    /// @notice Returns whether a registered pool permits swaps after all Registry gates.
    /// @param id Raw Uniswap V4 pool ID to check.
    /// @return Whether swaps may proceed for the pool.
    function isTradable(bytes32 id) external view returns (bool);

    /// @notice Returns whether a registered pool permits ordinary LP operations after all Registry gates.
    /// @param id Raw Uniswap V4 pool ID to check.
    /// @return Whether ordinary LP operations may proceed for the pool.
    function isLPAllowed(bytes32 id) external view returns (bool);

    /// @notice Returns the explicit lifecycle of a registered pool.
    /// @param poolId Raw Uniswap V4 pool ID to query.
    /// @return lifecycle Current pool lifecycle; unknown pools return the enum default DELIST.
    function getPoolLifeCycle(bytes32 poolId) external view returns (PoolLifecycle lifecycle);

    /// @notice Returns the explicit lifecycle for the pool derived from a full PoolKey.
    /// @param key Full Uniswap V4 pool key whose derived pool ID is queried.
    /// @return lifecycle Current pool lifecycle; unknown pools return the enum default DELIST.
    function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle);

    /// @notice Updates one registered pool's lifecycle.
    /// @param poolId Raw Uniswap V4 pool ID whose lifecycle changes.
    /// @param lifecycle New lifecycle to set.
    /// @return Whether storage changed.
    function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle) external returns (bool);

    /// @notice Updates many registered pools to the same lifecycle.
    /// @param poolIds Pool IDs whose lifecycle should be updated.
    /// @param lifecycle New lifecycle to apply to every pool.
    /// @return changedCount Number of pools whose stored lifecycle changed.
    function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle)
        external
        returns (uint256 changedCount);

    /// @notice Applies an LP Manager tick-count delta for a registered pool key.
    /// @param key Full V4 pool key whose derived pool ID must already be registered.
    /// @param delta Signed tick-count change to apply.
    /// @return Whether the update was accepted.
    function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool);

    /// @notice Returns whether a protocol-wide emergency pause is currently active.
    /// @return Whether a GLOBAL TRADE, GLOBAL LP, or GLOBAL ALL emergency pause is active.
    function isPaused() external view returns (bool);

    /// @notice Returns the configured exit receiver for a canonical underlying.
    /// @param u Canonical underlying address to query.
    /// @return Exit receiver address, or zero when unset.
    function exitAdminOf(address u) external view returns (address);

    /// @notice Returns the bound permissioned adapter Factory.
    /// @return Factory address.
    function permissionsAdapterFactory() external view returns (address);

    /// @notice Returns the PoolManager used by the permissioned adapter Factory.
    /// @return PoolManager address.
    function permissionedPoolManager() external view returns (address);

    /// @notice Returns the TSV Hook authorized for registered pools.
    /// @return Hook address.
    function hook() external view returns (address);

    /// @notice Returns the LP Manager authorized for pool registration and LP validation.
    /// @return LP Manager address.
    function lpManager() external view returns (address);

    /// @notice Returns the DataInbox authorized to apply market reports.
    /// @return DataInbox address.
    function dataInbox() external view returns (address);

    /// @notice Returns the governance Anchor inherited from `TSVGoverned`.
    /// @return Governance Anchor address.
    function governanceAnchor() external view returns (address);

    /// @notice Returns the participant SBT used for identity checks.
    /// @return Participant SBT address.
    function participantSbt() external view returns (address);

    /// @notice Enumerates registered SBT identity token IDs.
    /// @return Token IDs registered through `setSbtConfig`.
    function sbtTokenIds() external view returns (uint256[] memory);

    /// @notice Returns one SBT identity configuration.
    /// @param tokenId SBT identity token ID to query.
    /// @return registered Whether the identity token ID is registered.
    /// @return permissions TSV operation permissions assigned to the identity.
    function sbtIdentityConfig(uint256 tokenId) external view returns (bool registered, PermissionFlag permissions);

    /// @notice Returns active operation permissions for an account.
    /// @param owner Account whose active operation permissions are checked.
    /// @return Bitmask of active TSV operation permissions.
    function permissionsOf(address owner) external view returns (PermissionFlag);

    /// @notice Checks whether an account has one TSV operation permission.
    /// @param permission SWAP_ALLOWED or LIQUIDITY_ALLOWED.
    /// @param account Participant whose permissions are checked.
    /// @return Whether `account` currently has `permission`.
    function isAllowed(PermissionFlag permission, address account) external view returns (bool);

    /// @notice Checks a registered identity independently of operation permissions and global pause.
    /// @param owner Account whose SBT identity ownership is checked.
    /// @param tokenId Registered SBT token ID to check.
    /// @return Whether `owner` currently holds `tokenId`.
    function hasIdentity(address owner, uint256 tokenId) external view returns (bool);

    /// @notice Checks whether an account holds any registered identity.
    /// @param owner Account whose registered identity ownership is checked.
    /// @return Whether `owner` holds at least one registered SBT identity.
    function hasCredential(address owner) external view returns (bool);

    /// @notice Registers one identity or updates its swap/LP permissions.
    /// @param tokenId Identity token ID to register or update.
    /// @param permissions TSV operation flags assigned to the identity.
    function setSbtConfig(uint256 tokenId, PermissionFlag permissions) external;

    /// @notice Returns the last accepted market-report sequence for a security.
    /// @param id Security identifier to query.
    /// @return Last accepted market-report sequence number.
    function marketSequence(bytes32 id) external view returns (uint64);

    /// @notice Lists a new security with its first stock W, or adds a W to an existing listed security.
    /// @param admission Permissioned stock admission payload for the W/U/security binding.
    /// @param tierId Tier to assign to a newly listed security, or the existing security tier for additional W.
    function registerPermissionedCurrency(PermissionedAdmission calldata admission, uint8 tierId) external;

    /// @notice Registers an original quote ERC-20.
    /// @param q Quote token address to admit.
    function registerQuoteToken(address q) external;

    /// @notice Replaces the canonical legal-share adapter for an underlying.
    /// @param u Canonical underlying whose legal-share adapter is replaced.
    /// @param newAdapter New legal-share adapter for `u`.
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter) external;

    /// @notice Configures the receiver shared by every W for an underlying U.
    /// @param u Canonical underlying whose exit receiver changes.
    /// @param newAdmin New receiver for forced exits and related recovery flows.
    function setExitAdmin(address u, address newAdmin) external;

    /// @notice Binds Registry dependencies once, after all components are deployed.
    /// @param hook TSV Hook authorized for pool callbacks.
    /// @param lpManager LP Manager authorized to register exact pool keys before initialization.
    /// @param dataInbox DataInbox authorized to apply market reports.
    /// @param factory Real issuer Factory used to verify W provenance and derive PoolManager.
    /// @param sbt Fixed SBT contract supplying participant identities.
    function bindComponents(address hook, address lpManager, address dataInbox, address factory, address sbt)
        external;
}
