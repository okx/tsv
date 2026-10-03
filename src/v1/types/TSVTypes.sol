// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Admission state for a pool Currency registered in the Registry.
enum TokenStatus {
    UNREVIEWED, // Registered but not approved for pools.
    APPROVED, // Reviewed and permitted for new pool operations.
    DISABLED // Temporarily or permanently blocked from new pool operations.
}
/// @notice Lifecycle state for a Registry pool.
enum PoolStatus {
    ABSENT, // No pool record exists.
    PENDING, // Registered while PoolManager initialization is in progress.
    ACTIVE, // Initialized and available when all other trading gates pass.
    DISABLED // Registered but blocked from ordinary user operations.
}
/// @notice Trading state reported for a listed security.
enum MarketStatus {
    UNINITIALIZED, // No initial market report has been accepted.
    OPEN, // Market operations may proceed when all other gates pass.
    HALTED // New swaps and ordinary LP actions are blocked.
}
/// @notice Allowed first-state and subsequent market-state transitions.
enum MarketAction {
    INITIAL_OPEN, // Initializes an uninitialized security as open.
    INITIAL_HALTED, // Initializes an uninitialized security as halted.
    HALT, // Changes an open security to halted.
    RESUME // Changes a halted security to open.
}
/// @notice Scope used to target an emergency pause record.
enum PauseScope {
    GLOBAL, // Applies to all TSV pools and assets.
    SECURITY, // Applies to pools containing one security.
    TOKEN, // Applies to pools containing one Currency.
    POOL // Applies to one V4 pool ID.
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

/// @notice Registry configuration and review metadata for a pool Currency.
struct TokenConfig {
    /// @notice ERC-20 address used directly as the V4 Currency.
    address poolCurrency;
    /// @notice Token decimals checked against the token at registration.
    uint8 poolDecimals;
    /// @notice Listed security ID, or zero for a non-security Currency.
    bytes32 securityId;
    /// @notice Adapter converting this Currency's raw amount to legal shares; zero for non-security tokens.
    address legalShareAdapter;
    /// @notice Reviewed version of `legalShareAdapter`; zero for non-security tokens.
    uint32 legalAdapterVersion;
    /// @notice Current approval or disablement state of the Currency.
    TokenStatus status;
    /// @notice Runtime code hash required when the token is registered and approved.
    bytes32 poolRuntimeCodeHash;
    /// @notice Runtime code hash recorded for the legal-share adapter.
    bytes32 legalAdapterCodeHash;
    /// @notice Off-chain implementation evidence retained for review.
    bytes32 poolImplementationHash;
    /// @notice Nonzero digest of the token admission review required for approval.
    bytes32 reviewHash;
    /// @notice Off-chain digest of the token's restrictions review.
    bytes32 restrictionsHash;
    /// @notice Nonzero digest of the legal-share conversion policy.
    bytes32 legalSharePolicyHash;
}

/// @notice Registry state for one listed or delisted security.
struct SecurityConfig {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
    /// @notice Unique digest of the display symbol or ticker.
    bytes32 symbolHash;
    /// @notice Tier whose multiplier sets the security's hard daily volume cap.
    uint8 tierId;
    /// @notice Whether the security is currently listed for pool and report use.
    bool listed;
    /// @notice Number of active pools containing this security.
    uint32 activePoolCount;
    /// @notice Incremented whenever listing or tier configuration changes.
    uint32 version;
}

/// @notice Stored key, security legs, status, and version for a V4 pool.
struct PoolConfig {
    /// @notice Full V4 pool key.
    PoolKey key;
    /// @notice Security ID for currency0, or zero for an ordinary Currency.
    bytes32 securityId0;
    /// @notice Security ID for currency1, or zero for an ordinary Currency.
    bytes32 securityId1;
    /// @notice Registry lifecycle state of the pool.
    PoolStatus status;
    /// @notice Incremented when the pool is activated or its status changes.
    uint32 version;
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

/// @notice One-pool swap request accepted by the TSV Router.
struct SwapRequest {
    /// @notice Full V4 pool key; the Registry must recognize it as tradable.
    PoolKey key;
    /// @notice True for currency0-to-currency1, false for the reverse direction.
    bool zeroForOne;
    /// @notice Exact input amount or exact output amount, depending on the entry point.
    uint128 amountSpecified;
    /// @notice Minimum output for exact-input swaps or maximum input for exact-output swaps.
    uint128 limitAmount;
    /// @notice Q64.96 square-root price boundary passed to PoolManager.
    uint160 sqrtPriceLimitX96;
    /// @notice Latest timestamp at which the swap may execute.
    uint64 deadline;
}

/// @notice Exact-input swap parameters accepted from an approved external Adapter.
/// @dev The Router chooses a full-range price limit and always settles to the Adapter.
struct AdapterSwapRequest {
    /// @notice Full V4 pool key; the Registry must recognize it as tradable.
    PoolKey key;
    /// @notice True for currency0-to-currency1, false for the reverse direction.
    bool zeroForOne;
    /// @notice Exact input amount supplied by the Adapter.
    uint128 amountIn;
    /// @notice Minimum output the Adapter must receive.
    uint128 minAmountOut;
    /// @notice Latest timestamp at which the swap may execute.
    uint64 deadline;
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
