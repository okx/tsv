// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PermissionFlag} from "../vendor/permissionedPools/libraries/PermissionFlags.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Selects which operation pause bits applySecurityStatus updates.
/// @dev These enum ordinals are API selectors, NOT the stored mask values:
///      TRADE=0 selects bit 0 (mask 1), LP=1 selects bit 1 (mask 2), ALL=2 selects both (mask 3).
///      Resume both operations with ALL/false; there is no NONE selector.
enum SecurityPauseMode {
    TRADE,
    LP,
    ALL
}

/// @notice Operation type checked by Registry operation gates.
enum SecurityOperationCheckType {
    LP, // Ordinary LP operations.
    TRADE // Swap operations.
}
/// @notice Explicit lifecycle of a registered TSV pool.
enum PoolLifecycle {
    DELIST, // Ordinary swaps and ordinary LP operations are blocked.
    LIST, // Ordinary swaps and ordinary LP operations may continue through later gates.
    PAUSE // Ordinary LP operations may continue through later gates; swaps are blocked.
}

/// @notice Canonical security, precision and legal-share conversion for an underlying (U).
struct UnderlyingRecord {
    bytes32 securityId;
    address legalShareAdapter;
    uint8 rawDecimals;
    /// @notice Whether this underlying may be used when registering new pools.
    bool registered;
}

/// @notice An independently registered original quote ERC-20 (Q).
struct QuoteTokenRecord {
    uint8 rawDecimals;
    /// @notice Whether this quote token may be used when registering new pools.
    bool registered;
}

/// @notice Reviewed permissioned stock registration input; U and decimals are derived from trusted contracts.
struct PermissionedRegisterParam {
    address currency;
    bytes32 securityId;
    address legalShareAdapter;
}

/// @notice Stores the listing limit and current listed count for a security tier.
struct TierPolicyRecord {
    /// @notice Maximum number of securities that may be listed in this tier.
    uint32 maxListed;
    /// @notice Number of securities currently assigned to this tier.
    uint32 listedCount;
}

/// @notice Aggregates one security's listing state, pool counters, and operation state.
struct SecurityRecord {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
    /// @notice Tier whose capacity tracks the listed security.
    uint8 tierId;
    /// @notice Whether the security is currently listed for pool and report use.
    bool listed;
    /// @notice Append-only pool ID list permanently associated with this security.
    bytes32[] poolIds;
    /// @notice Number of associated pools whose lifecycle is not DELIST.
    uint32 listedPoolCount;
    /// @notice Two-bit pause mask: 0=unpaused, 1=TRADE, 2=LP, 3=ALL.
    /// @dev Only bit 0 (TRADE) and bit 1 (LP) are stored; a set bit blocks its operation.
    ///      ALL is the combination of both bits, not an extra stored flag.
    ///      SecurityPauseMode is a setter selector, so do not cast this mask to that enum.
    ///      Flattening the former nested state changes storage packing; existing proxy
    ///      deployments must migrate their old pause state before using this layout.
    uint8 pauseMode;
}

/// @notice Stores one registered V4 pool's identity and lifecycle-owned state.
struct PoolRecord {
    /// @notice Full V4 pool key.
    PoolKey key;
    /// @notice Single nonzero stock security assigned to this W/Q pool.
    bytes32 securityId;
    /// @notice Security tier captured when this pool was registered.
    uint8 tierId;
    /// @notice Explicit lifecycle for this registered pool.
    PoolLifecycle lifecycle;
    /// @notice Current active tick/NFT count tracked for this registered pool.
    uint256 tickCount;
    /// @notice One-based index inside `SecurityRecord.poolIds`; zero means absent.
    uint256 poolSecurityIndex;
}

/// @notice One-pool exact-input request for permissioned-stock/original-quote swaps.
/// @dev W raw equals U raw; approved DEX Adapters exchange U for the stock leg.
/// @dev The Router derives a full-range V4 price limit from `zeroForOne`.
struct SwapRequest {
    /// @notice Full V4 pool key; the Registry must recognize it as tradable.
    PoolKey key;
    /// @notice True for currency0-to-currency1, false for the reverse direction.
    bool zeroForOne;
    /// @notice Exact input amount in the input Currency's raw units.
    uint128 amountSpecified;
    /// @notice Minimum output amount in the output Currency's raw units.
    uint128 limitAmount;
    /// @notice Latest timestamp at which the swap may execute.
    uint64 deadline;
    /// @notice Multiplier observed when the user or Adapter quoted this swap.
    /// @dev Must equal the stock adapter's currentMultiplier value; zero is invalid.
    uint256 expectedMultiplier;
}

/// @notice A recognized SBT identity and the operations it currently authorizes.
struct SbtIdentityConfig {
    bool registered;
    PermissionFlag permissions;
}
