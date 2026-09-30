// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

enum AssetClass {
    QUOTE_ERC20,
    FIXED_BALANCE_STOCK,
    ISSUER_WRAPPED_DYNAMIC,
    ONCHAIN_DYNAMIC
}
enum SettlementMode {
    DIRECT_ERC20,
    ISSUER_SHARE_WRAPPED
}
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
enum RoundingMode {
    FLOOR,
    CEIL
}
enum LegalShareMode {
    STATIC_RATIO,
    ONCHAIN_DYNAMIC
}
enum RawBoundMode {
    MIN_RAW_FOR_AT_LEAST_SHARES,
    MAX_RAW_FOR_AT_MOST_SHARES
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
    address userToken;
    address poolCurrency;
    uint8 userDecimals;
    uint8 poolDecimals;
    AssetClass assetClass;
    bytes32 securityId;
    SettlementMode settlementMode;
    address settlementAdapter;
    uint32 settlementVersion;
    address legalShareAdapter;
    uint32 legalAdapterVersion;
    uint256 sharesPerWholeTokenWad;
    bytes32 ratioEvidenceHash;
    TokenStatus status;
    bytes32 userRuntimeCodeHash;
    bytes32 poolRuntimeCodeHash;
    bytes32 settlementAdapterCodeHash;
    bytes32 legalAdapterCodeHash;
    bytes32 userImplementationHash;
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

struct AssetBounds {
    uint256 maxSharesIn;
    uint256 minSharesOut;
    uint256 maxDisplayedDebit;
    uint256 minDisplayedCredit;
}

struct RateSnapshot {
    bytes32 rateId;
    uint256 numerator;
    uint256 denominator;
    uint32 adapterVersion;
    RoundingMode rounding;
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
    address authorizedCaller;
    bool zeroForOne;
    bool exactInput;
    uint128 amountSpecified;
    uint128 limitAmount;
    uint160 sqrtPriceLimitX96;
    AssetBounds bounds0;
    AssetBounds bounds1;
    uint256 nonce;
    uint64 deadline;
}

struct LPBounds {
    uint256 maxPoolIn0;
    uint256 maxPoolIn1;
    uint256 minPoolOut0;
    uint256 minPoolOut1;
    AssetBounds bounds0;
    AssetBounds bounds1;
    uint64 deadline;
}
