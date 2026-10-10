// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Explicit lifecycle of a registered TSV pool.
enum PoolLifecycle {
    DELIST, // Ordinary swaps and ordinary LP operations are blocked.
    LIST, // Ordinary swaps and ordinary LP operations may continue through later gates.
    PAUSE // Ordinary LP operations may continue through later gates; swaps are blocked.
}

/// @notice Market state derived from a known security's current pause mask.
enum MarketStatus {
    OPEN, // Market operations may proceed when all other gates pass.
    HALTED // Trading, ordinary LP actions, or both are paused.
}
/// @notice Allowed market pause transitions after admission defaults to open.
enum MarketAction {
    HALT, // Adds the selected trading and/or LP pause to a listed security.
    RESUME // Removes the selected pause; the security is open once all market pauses clear.
}
/// @notice Scope used to target an emergency pause record.
enum PauseScope {
    GLOBAL, // Applies to all TSV pools and assets.
    SECURITY, // Applies to pools containing one security.
    TOKEN, // Applies to pools containing one Currency.
    POOL // Applies to one V4 pool ID.
}
/// @notice Operations affected by a pause; values also form the market pause bitmask.
enum PauseMode {
    NONE, // No market pause; invalid as the mode of a pause or resume request.
    TRADE, // Blocks swaps only.
    LP, // Blocks all ordinary LP actions only.
    ALL // Blocks swaps and all ordinary LP actions.
}
/// @notice Operation mode bound to an LP Manager callback context.
enum LPOperationMode {
    OPEN, // Adds the initial positive liquidity to a new position.
    INCREASE, // Adds liquidity to an existing position.
    DECREASE, // Removes part of existing liquidity.
    COLLECT, // Collects accrued fees without changing liquidity.
    CLOSE, // Removes all liquidity at the owner's request.
    FORCE_EXIT // Removes all liquidity through the authorized forced-exit path.
}

/// @notice A registered stock PermissionsAdapter (W); underlying identity is permanent.
struct PermissionedCurrencyConfig {
    address underlying;
    address expectedOwner;
}

/// @notice Canonical security, precision and legal-share conversion for an underlying (U).
struct UnderlyingConfig {
    bytes32 securityId;
    address legalShareAdapter;
    uint8 rawDecimals;
}

/// @notice An independently registered original quote ERC-20 (Q).
struct QuoteTokenConfig {
    uint8 rawDecimals;
    /// @dev Explicit presence is required because rawDecimals may be zero.
    bool registered;
}

/// @notice Reviewed stock admission input; U and decimals are derived from trusted contracts.
struct PermissionedAdmission {
    address currency;
    bytes32 securityId;
    address expectedOwner;
    address legalShareAdapter;
}

/// @notice Registry state for one listed or delisted security.
struct SecurityConfig {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
    /// @notice Tier whose multiplier sets the security's hard daily volume cap.
    uint8 tierId;
    /// @notice Whether the security is currently listed for pool and report use.
    bool listed;
}

/// @notice Registered key and permanent security legs for a V4 pool.
struct PoolConfig {
    /// @notice Full V4 pool key.
    PoolKey key;
    /// @notice Security ID for currency0, or zero for an ordinary Currency.
    bytes32 securityId0;
    /// @notice Security ID for currency1, or zero for an ordinary Currency.
    bytes32 securityId1;
}

/// @notice LP Manager state exposed to the Hook while one liquidity operation is in progress.
struct LPContext {
    /// @notice Pool identifier derived from the position's V4 key.
    bytes32 poolId;
    /// @notice TSV position identifier.
    uint256 positionId;
    /// @notice Lower tick boundary of the position.
    int24 tickLower;
    /// @notice Upper tick boundary of the position.
    int24 tickUpper;
    /// @notice Operation being performed on this position.
    LPOperationMode mode;
    /// @notice Unique V4 salt assigned to the position.
    bytes32 salt;
    /// @notice Signed liquidity change expected in the PoolManager callback.
    int256 liquidityDelta;
}

/// @notice Reduced LP operation context returned to the Hook for callback validation.
struct LPHookContext {
    /// @notice Pool identifier derived from the position's V4 key.
    bytes32 poolId;
    /// @notice Lower tick boundary of the position.
    int24 tickLower;
    /// @notice Upper tick boundary of the position.
    int24 tickUpper;
    /// @notice Operation being performed on this position.
    LPOperationMode mode;
    /// @notice Unique V4 salt assigned to the position.
    bytes32 salt;
    /// @notice Signed liquidity change expected in the PoolManager callback.
    int256 liquidityDelta;
}

/// @notice One-pool user request for permissioned-stock/original-quote exact-in/out swaps.
/// @dev W raw equals U raw; users or approved DEX Adapters approve and exchange U for the stock leg.
/// @dev The Router derives a full-range V4 price limit from `zeroForOne`.
struct SwapRequest {
    /// @notice Full V4 pool key; the Registry must recognize it as tradable.
    PoolKey key;
    /// @notice True for currency0-to-currency1, false for the reverse direction.
    bool zeroForOne;
    /// @notice Exact input amount or exact output amount, depending on the entry point.
    uint128 amountSpecified;
    /// @notice Minimum output for exact-input swaps or maximum input for exact-output swaps.
    uint128 limitAmount;
    /// @notice Latest timestamp at which the swap may execute.
    uint64 deadline;
    /// @notice Multiplier observed when the user or Adapter quoted this swap.
    /// @dev Must equal the stock adapter's currentMultiplier value; zero is invalid.
    uint256 expectedMultiplier;
}

/// @notice Raw-unit settlement limits and deadline for an LP operation.
struct LPBounds {
    /// @notice Maximum currency0 amount the owner may be charged.
    uint256 maxPoolIn0;
    /// @notice Maximum currency1 amount the owner may be charged.
    uint256 maxPoolIn1;
    /// @notice Minimum currency0 amount that must be returned to the owner.
    uint256 minPoolOut0;
    /// @notice Minimum currency1 amount that must be returned to the owner.
    uint256 minPoolOut1;
    /// @notice Latest timestamp at which the LP operation may execute.
    uint64 deadline;
}

/// @notice A recognized SBT identity and the operations it currently authorizes.
struct SbtIdentityConfig {
    bool registered;
    PermissionFlag permissions;
}
