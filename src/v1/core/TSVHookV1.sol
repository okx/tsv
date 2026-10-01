// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolConfig, PoolStatus, TokenConfig, LPContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

interface IActiveSwapContextV1 {
    function activeSwapContext() external view returns (bool isActive, bytes32 poolId, address participant);
}

interface IActiveLPContextV1 {
    function activeLPContext(bytes32 operationId) external view returns (LPContext memory);
}

/// @notice Upgradeable hook whose proxy address carries the V4 permission bits.
contract TSVHookV1 is TSVGoverned, IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Reserve all V4 callback and return-delta permissions at the proxy address.
    // V1 returns zero deltas; nonzero deltas require a separately reviewed accounting upgrade.
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    error UnauthorizedCallback();
    error InvalidHookAddress();
    error InvalidPool();
    error InvalidOperation();
    error UnsupportedCallback();

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    address public router;
    address public lpManager;

    function initialize(
        address authority,
        address timelock,
        address controller,
        address poolManager_,
        address registry_,
        address ledger_,
        address router_,
        address lpManager_
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        if ((uint160(address(this)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS) revert InvalidHookAddress();
        if (
            poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0
                || router_.code.length == 0 || lpManager_.code.length == 0
        ) revert InvalidOperation();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        router = router_;
        lpManager = lpManager_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requirePending(sender, key);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requirePending(sender, key);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPContext memory ctx = _checkLP(sender, key, params, hookData);
        if (
            params.liquidityDelta <= 0 || (ctx.mode != LPOperationMode.OPEN && ctx.mode != LPOperationMode.INCREASE)
                || !registry.isTradable(ctx.poolId)
        ) revert InvalidOperation();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPContext memory ctx = _checkLP(sender, key, params, hookData);
        if (params.liquidityDelta > 0 || ctx.mode == LPOperationMode.OPEN || ctx.mode == LPOperationMode.INCREASE) {
            revert InvalidOperation();
        }
        if (ctx.mode == LPOperationMode.FORCE_EXIT) {
            if (params.liquidityDelta >= 0) revert InvalidOperation();
        } else if (!registry.isTradable(ctx.poolId)) {
            revert InvalidPool();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != router || hookData.length != 0) revert UnauthorizedCallback();
        bytes32 poolId = PoolId.unwrap(key.toId());
        (bool isActive, bytes32 activePoolId, address participant) = IActiveSwapContextV1(router).activeSwapContext();
        if (!isActive || activePoolId != poolId || participant == address(0) || !registry.isTradable(poolId)) {
            revert InvalidOperation();
        }
        _requireExactKey(key, poolId);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (sender != router || hookData.length != 0) revert UnauthorizedCallback();
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolConfig memory pool = registry.getPool(poolId);
        uint256 shares0 = _sharesForLeg(pool.securityId0, Currency.unwrap(key.currency0), delta.amount0());
        uint256 shares1 = _sharesForLeg(pool.securityId1, Currency.unwrap(key.currency1), delta.amount1());
        ledger.recordSwap(poolId, delta.amount0(), delta.amount1(), shares0, shares1);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    function _requirePending(address sender, PoolKey calldata key) private view {
        if (
            sender != lpManager || address(key.hooks) != address(this)
                || registry.getPool(PoolId.unwrap(key.toId())).status != PoolStatus.PENDING
        ) revert InvalidPool();
        _requireExactKey(key, PoolId.unwrap(key.toId()));
    }

    function _requireExactKey(PoolKey calldata key, bytes32 poolId) private view {
        PoolConfig memory pool = registry.getPool(poolId);
        if (keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))) revert InvalidPool();
    }

    function _checkLP(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) private view returns (LPContext memory ctx) {
        if (sender != lpManager || hookData.length != 32) revert UnauthorizedCallback();
        bytes32 operationId = abi.decode(hookData, (bytes32));
        ctx = IActiveLPContextV1(lpManager).activeLPContext(operationId);
        if (
            ctx.poolId == 0 || ctx.poolId != PoolId.unwrap(key.toId()) || ctx.salt != params.salt
                || ctx.tickLower != params.tickLower || ctx.tickUpper != params.tickUpper
                || ctx.liquidityDelta != params.liquidityDelta
        ) revert InvalidOperation();
        _requireExactKey(key, ctx.poolId);
    }

    function _sharesForLeg(bytes32 securityId, address currency, int128 delta) private view returns (uint256) {
        if (securityId == 0 || delta == 0) return 0;
        TokenConfig memory config = registry.getToken(currency);
        if (config.securityId != securityId || config.legalShareAdapter == address(0)) revert InvalidPool();
        uint256 rawAmount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        return IDirectLegalShareAdapter(config.legalShareAdapter).toLegalShares(currency, rawAmount);
    }
}
