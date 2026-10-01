// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

enum TokenStatus {
    UNREVIEWED,
    APPROVED,
    DISABLED
}
enum PoolStatus {
    ABSENT,
    PENDING,
    ACTIVE,
    DISABLED
}
enum MarketStatus {
    UNINITIALIZED,
    OPEN,
    HALTED
}
enum MarketAction {
    INITIAL_OPEN,
    INITIAL_HALTED,
    HALT,
    RESUME
}
enum PauseScope {
    GLOBAL,
    SECURITY,
    TOKEN,
    POOL
}
enum LPOperationMode {
    OPEN,
    INCREASE,
    DECREASE,
    COLLECT,
    CLOSE,
    FORCE_EXIT
}

struct TokenConfig {
    address poolCurrency;
    uint8 poolDecimals;
    bytes32 securityId;
    address legalShareAdapter;
    uint32 legalAdapterVersion;
    TokenStatus status;
    bytes32 poolRuntimeCodeHash;
    bytes32 legalAdapterCodeHash;
    bytes32 poolImplementationHash;
    bytes32 reviewHash;
    bytes32 restrictionsHash;
    bytes32 legalSharePolicyHash;
}

struct SecurityConfig {
    bytes32 securityId;
    bytes32 symbolHash;
    uint8 tierId;
    bool listed;
    uint32 activePoolCount;
    uint32 version;
}

struct PoolConfig {
    PoolKey key;
    bytes32 securityId0;
    bytes32 securityId1;
    PoolStatus status;
    uint32 version;
}

struct LPContext {
    bytes32 poolId;
    uint256 positionId;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;
    LPOperationMode mode;
    address owner;
    int256 liquidityDelta;
}

struct SwapRequest {
    PoolKey key;
    address participant;
    address payer;
    address recipient;
    bool zeroForOne;
    bool exactInput;
    uint128 amountSpecified;
    uint128 limitAmount;
    uint160 sqrtPriceLimitX96;
    uint64 deadline;
}

struct LPBounds {
    uint256 maxPoolIn0;
    uint256 maxPoolIn1;
    uint256 minPoolOut0;
    uint256 minPoolOut1;
    uint64 deadline;
}
