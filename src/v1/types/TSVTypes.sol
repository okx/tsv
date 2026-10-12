// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Operation status derived from a known security's current pause mask.
enum SecurityOperationStatus {
    OPEN, // Security operations may proceed when all other gates pass.
    HALTED // Trading, ordinary LP actions, or both are paused.
}
/// @notice Allowed security operation transitions; newly registered securities default to open.
enum SecurityOperationType {
    HALT, // Adds the selected trading and/or LP pause to a listed security.
    RESUME // Removes the selected pause; the security is open once all operation pauses clear.
}
/// @notice Operations affected by a security pause; values also form the operation pause bitmask.
enum SecurityPauseMode {
    NONE, // No operation pause; invalid as the mode of a pause or resume request.
    TRADE, // Blocks swaps only.
    LP, // Blocks all ordinary LP actions only.
    ALL // Blocks swaps and all ordinary LP actions.
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
}

/// @notice An independently registered original quote ERC-20 (Q).
struct QuoteTokenRecord {
    uint8 rawDecimals;
    /// @dev Explicit presence is required because rawDecimals may be zero.
    bool registered;
}

/// @notice Reviewed permissioned stock registration input; U and decimals are derived from trusted contracts.
struct PermissionedRegisterParam {
    address currency;
    bytes32 securityId;
    address legalShareAdapter;
}

/// @notice Stores the listing limit and quota multiplier for a security tier.
struct TierPolicyRecord {
    /// @notice ADTV hard-cap multiplier in basis points.
    uint16 tierBps;
    /// @notice Maximum number of securities that may be listed in this tier.
    uint32 maxListed;
    /// @notice Number of securities currently assigned to this tier.
    uint32 listedCount;
}

/// @notice DataInbox-driven security operation state for one security.
struct SecurityStateRecord {
    /// @notice Current security operation pause mask.
    SecurityPauseMode pauseMode;
}

/// @notice Aggregates one security's listing state, pool counters, and operation state.
struct SecurityRecord {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
    /// @notice Tier whose multiplier sets the security's hard daily volume cap.
    uint8 tierId;
    /// @notice Whether the security is currently listed for pool and report use.
    bool listed;
    /// @notice Append-only pool ID list permanently associated with this security.
    bytes32[] poolIds;
    /// @notice Number of associated pools whose lifecycle is not DELIST.
    uint32 listedPoolCount;
    /// @notice DataInbox-driven operation state for this security.
    SecurityStateRecord securityState;
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
