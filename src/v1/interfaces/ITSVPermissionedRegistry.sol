// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PermissionFlag} from "../vendor/permissionedPools/libraries/PermissionFlags.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {
    UnderlyingRecord,
    QuoteTokenRecord,
    PermissionedRegisterParam,
    TierPolicyRecord,
    PoolRecord,
    SecurityRecord,
    PoolLifecycle,
    SecurityPauseMode
} from "tsv-v1/types/TSVTypes.sol";

/// @notice Shared W/U/Q interface. Asset records use the canonical TSVTypes definitions.
interface ITSVPermissionedRegistry {
    /// @notice Checks a role in the Registry, including its dynamically resolved default admin.
    function hasRole(bytes32 role, address account) external view returns (bool);
    /// @notice Registers the exact pool key; only the bound LP Manager may call this.
    /// @param key Full Uniswap V4 pool key to register.
    /// @return poolId Raw pool ID derived from `key`.
    function registerPool(PoolKey calldata key) external returns (bytes32 poolId);

    /// @notice Returns the canonical underlying bound to a permissioned stock adapter.
    /// @param w Permissioned stock adapter address to query.
    /// @return underlying Canonical underlying U, or zero when `w` is unknown.
    function getCurrencyUnderlying(address w) external view returns (address underlying);

    /// @notice Returns the stored canonical underlying configuration.
    /// @param u Canonical underlying address to query.
    /// @return Stored U configuration; unknown underlyings return a default record.
    function getUnderlying(address u) external view returns (UnderlyingRecord memory);

    /// @notice Returns the stored quote token configuration.
    /// @param q Quote token address to query.
    /// @return Stored quote configuration; unknown quotes return a default record.
    function getQuoteToken(address q) external view returns (QuoteTokenRecord memory);

    /// @notice Returns the registered key and permanent security for a pool.
    /// @param id Raw Uniswap V4 pool ID to query.
    /// @return Stored pool record; unknown pools return a default record.
    function getPool(bytes32 id) external view returns (PoolRecord memory);

    /// @notice Returns listing/tier state and the mode derived from TRADE/LP pause bits.
    /// @dev Both bits set means ALL (3); both cleared means unpaused (0). No extra aggregate bits are stored.
    /// @param id Security identifier to query.
    /// @return Stored security record; unknown IDs return a default record.
    function getSecurity(bytes32 id) external view returns (SecurityRecord memory);

    /// @notice Returns the listing-cap policy currently configured for a tier.
    /// @param tierId Tier identifier to query.
    /// @return Stored tier policy record; unknown tiers return a default record.
    function getTierPolicy(uint8 tierId) external view returns (TierPolicyRecord memory);

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

    /// @notice Returns the number of pools for a security whose lifecycle is not DELIST.
    /// @param securityId Security whose lifecycle-listed pool count is queried.
    /// @return count Number of pools that still block `delistSecurity`.
    function getListPoolCountBySecurity(bytes32 securityId) external view returns (uint32 count);

    /// @notice Returns the current Tick/NFT count tracked for a registered pool.
    /// @param poolId Raw Uniswap V4 pool ID to query.
    /// @return count Current tracked Tick/NFT count.
    function getPoolTickCount(bytes32 poolId) external view returns (uint256 count);

    /// @notice Updates one registered pool's lifecycle.
    /// @param poolId Raw Uniswap V4 pool ID whose lifecycle changes.
    /// @param lifecycle New lifecycle to set.
    /// @param reasonCode Nonzero operational reason code for the lifecycle change.
    /// @return Whether storage changed.
    function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle, bytes32 reasonCode) external returns (bool);

    /// @notice Updates many registered pools to the same lifecycle.
    /// @param poolIds Pool IDs whose lifecycle should be updated.
    /// @param lifecycle New lifecycle to apply to every pool.
    /// @param reasonCode Nonzero operational reason code for the lifecycle changes.
    /// @return changedCount Number of pools whose stored lifecycle changed.
    function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle, bytes32 reasonCode)
        external
        returns (uint256 changedCount);

    /// @notice Applies an LP Manager tick-count delta for a registered pool key.
    /// @param key Full V4 pool key whose derived pool ID must already be registered.
    /// @param delta Signed tick-count change to apply.
    /// @return Whether the update was accepted.
    function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool);

    /// @notice Returns whether a protocol-wide emergency pause is currently active.
    /// @return Whether the global emergency pause is active.
    function isPaused() external view returns (bool);

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
    function isSbtAllowed(PermissionFlag permission, address account) external view returns (bool);

    /// @notice Checks a registered identity independently of operation permissions and global pause.
    /// @param owner Account whose SBT identity ownership is checked.
    /// @param tokenId Registered SBT token ID to check.
    /// @return Whether `owner` currently holds `tokenId`.
    function hasIdentity(address owner, uint256 tokenId) external view returns (bool);

    /// @notice Checks whether an account holds any currently registered identity.
    /// @param owner Account whose registered identity ownership is checked.
    /// @return Whether `owner` holds at least one registered SBT identity.
    function hasCredential(address owner) external view returns (bool);

    /// @notice Registers or updates one identity; assigning NONE removes it from the registered set.
    /// @param tokenId Identity token ID to register or update.
    /// @param permissions TSV operation flags assigned to the identity.
    /// @param reasonCode Nonzero operational reason code for the configuration change.
    function setSbtConfig(uint256 tokenId, PermissionFlag permissions, bytes32 reasonCode) external;

    /// @notice Returns the current operation pause mode for a security.
    /// @param id Security identifier to query.
    /// @return Pause bitmask: 0=unpaused, 1=TRADE, 2=LP, 3=ALL; not an enum ordinal.
    function getSecurityPauseMode(bytes32 id) external view returns (uint8);

    /// @notice Sets or clears selected security pause bits, preserving unselected bits.
    /// @dev ALL/true pauses both; ALL/false resumes both.
    ///      Only HALT_REPORTER_ROLE; listed securities only; no-op updates revert.
    /// @param securityId Listed security identifier.
    /// @param mode TRADE, LP or ALL operation selector.
    /// @param enable True to pause selected operations; false to resume them.
    /// @param reasonCode Nonzero operational reason code.
    function applySecurityStatus(bytes32 securityId, SecurityPauseMode mode, bool enable, bytes32 reasonCode) external;

    /// @notice Lists a new security with its first stock W, or adds a W to an existing listed security.
    /// @param registerParam Permissioned stock registration payload for the W/U/security binding.
    /// @param tierId Tier to assign to a newly listed security, or the existing security tier for additional W.
    /// @param reasonCode Nonzero operational reason code for the registration.
    function registerPermissionedCurrency(
        PermissionedRegisterParam calldata registerParam,
        uint8 tierId,
        bytes32 reasonCode
    ) external;

    /// @notice Registers an original quote ERC-20.
    /// @param q Quote token address to register.
    /// @param reasonCode Nonzero operational reason code for registering the quote token.
    function registerQuoteToken(address q, bytes32 reasonCode) external;

    /// @notice Disables a registered quote token for future pool registration while preserving stored metadata.
    /// @param quote Quote token address whose future pool registration should be disabled.
    /// @param reasonCode Nonzero operational reason code for disabling the quote token.
    function disableQuoteTokenPoolRegister(address quote, bytes32 reasonCode) external;

    /// @notice Disables a canonical underlying for future pool registration while preserving stored metadata.
    /// @param u Canonical underlying whose future pool registration should be disabled.
    /// @param reasonCode Nonzero operational reason code for disabling the underlying.
    function disableUnderlyingPoolRegister(address u, bytes32 reasonCode) external;

    /// @notice Replaces the legal-share adapter for an underlying; the new adapter applies to subsequent swaps immediately.
    /// @param u Canonical underlying whose legal-share adapter is replaced.
    /// @param newAdapter New legal-share adapter for `u`.
    /// @param reasonCode Nonzero operational reason code for replacing the adapter.
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter, bytes32 reasonCode) external;

    /// @notice Binds Registry dependencies once, after all components are deployed.
    /// @param hook TSV Hook authorized for pool callbacks.
    /// @param lpManager LP Manager authorized to register exact pool keys before initialization.
    /// @param factory Real issuer Factory used to verify W provenance and derive PoolManager.
    /// @param sbt Fixed SBT contract supplying participant identities.
    function bindComponents(address hook, address lpManager, address factory, address sbt) external;
}
