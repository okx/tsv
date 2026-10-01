// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolConfig, PoolStatus, TokenConfig, LPContext, LPOperationMode, RateSnapshot} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {ILegalShareAdapter} from "tsv-v1/interfaces/ILegalShareAdapter.sol";

interface IActiveSwapContextV1 {
    function activeSwapOperation(bytes32 operationId)
        external
        view
        returns (bytes32 poolId, address participant, bool zeroForOne, bool exactInput);
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
    error StaleSnapshot();

    struct SwapState {
        bytes32 poolId;
        RateSnapshot rate0;
        RateSnapshot rate1;
        bool accounted;
    }

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    address public router;
    address public lpManager;
    mapping(bytes32 => SwapState) private swapStates;

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
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != router || hookData.length != 32) revert UnauthorizedCallback();
        bytes32 operationId = abi.decode(hookData, (bytes32));
        bytes32 poolId = PoolId.unwrap(key.toId());
        (bytes32 activeId, address participant,,) = IActiveSwapContextV1(router).activeSwapOperation(operationId);
        if (
            activeId != poolId || participant == address(0) || swapStates[operationId].poolId != 0
                || !registry.isTradable(poolId)
        ) revert InvalidOperation();
        _requireExactKey(key, poolId);
        SwapState storage state = swapStates[operationId];
        state.poolId = poolId;
        state.rate0 = _snapshot(Currency.unwrap(key.currency0));
        state.rate1 = _snapshot(Currency.unwrap(key.currency1));
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (sender != router || hookData.length != 32) revert UnauthorizedCallback();
        bytes32 operationId = abi.decode(hookData, (bytes32));
        SwapState storage state = swapStates[operationId];
        if (state.poolId == 0 || state.poolId != PoolId.unwrap(key.toId()) || state.accounted) {
            revert InvalidOperation();
        }
        ledger.recordSwap(state.poolId, delta.amount0(), delta.amount1(), state.rate0, state.rate1);
        state.accounted = true;
        return (IHooks.afterSwap.selector, 0);
    }

    function assertCurrentAndClear(bytes32 operationId) external {
        if (msg.sender != router) revert UnauthorizedCallback();
        SwapState storage state = swapStates[operationId];
        if (!state.accounted || state.poolId == 0) revert InvalidOperation();
        PoolConfig memory pool = registry.getPool(state.poolId);
        _assertCurrent(Currency.unwrap(pool.key.currency0), state.rate0);
        _assertCurrent(Currency.unwrap(pool.key.currency1), state.rate1);
        delete swapStates[operationId];
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

    function _snapshot(address currency) private view returns (RateSnapshot memory rate) {
        TokenConfig memory config = registry.getToken(currency);
        if (config.securityId != 0) {
            rate = ILegalShareAdapter(config.legalShareAdapter).snapshot(currency);
            if (rate.adapterVersion != config.legalAdapterVersion) revert StaleSnapshot();
        }
    }

    function _assertCurrent(address currency, RateSnapshot storage rate) private view {
        TokenConfig memory config = registry.getToken(currency);
        if (
            config.securityId != 0
                && (config.legalAdapterVersion != rate.adapterVersion
                    || !ILegalShareAdapter(config.legalShareAdapter).isCurrent(currency, rate))
        ) revert StaleSnapshot();
    }
}
