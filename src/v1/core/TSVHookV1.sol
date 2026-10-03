// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolConfig, PoolStatus, TokenConfig, LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @dev Exposes the active LP operation context used to authorize Hook callbacks.
interface IActiveLPContextV1 {
    /// @notice Returns the LP Manager's active operation context for Hook validation.
    function activeLPContext() external view returns (LPHookContext memory);
}

/// @notice Upgradeable hook whose proxy address carries the V4 permission bits.
contract TSVHookV1 is TSVGoverned, IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Reserve all V4 callback and return-delta permissions at the proxy address.
    // V1 returns zero deltas; nonzero deltas require a separately reviewed accounting upgrade.
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    /// @dev Reverts when the callback caller or context is not authorized.
    error UnauthorizedCallback();
    /// @dev Reverts when the Hook proxy address does not contain the required V4 permission bits.
    error InvalidHookAddress();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the requested operation is not valid in the current state or callback context.
    error InvalidOperation();
    /// @dev Reverts when the requested Hook callback is not supported.
    error UnsupportedCallback();

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    address public router;
    address public lpManager;

    /// @notice Initializes the Hook's trusted component addresses and verifies its V4 permission bits.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param poolManager_ V4 PoolManager that invokes Hook callbacks.
    /// @param registry_ Registry used for pool, token, and market validation.
    /// @param ledger_ Volume Ledger that records completed swaps.
    /// @param router_ Only router permitted to execute swaps through this Hook.
    /// @param lpManager_ Only LP Manager permitted to initialize pools and modify liquidity.
    function initialize(
        address anchor,
        address poolManager_,
        address registry_,
        address ledger_,
        address router_,
        address lpManager_
    ) external initializer {
        __TSVGoverned_init(anchor);
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

    /// @dev Restricts V4 callback implementations to the configured PoolManager.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        _;
    }

    /// @notice Allows initialization only for a pending pool created by the LP Manager.
    /// @param sender Contract that initiated PoolManager.initialize.
    /// @param key Full V4 pool key being initialized.
    /// @return V4 callback selector acknowledging this Hook callback.
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

    /// @notice Confirms that PoolManager completed initialization for a pending TSV pool.
    /// @param sender Contract that initiated PoolManager.initialize.
    /// @param key Full V4 pool key that was initialized.
    /// @return V4 callback selector acknowledging this Hook callback.
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

    /// @notice Allows positive liquidity changes only for an authorized operation passing LP admission and pause checks.
    /// @param sender Contract that initiated PoolManager.modifyLiquidity.
    /// @param key Full V4 pool key being modified.
    /// @param params Tick range, salt, and liquidity change requested by the manager.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPHookContext memory ctx = _checkLP(sender, key, params, hookData);
        if (
            params.liquidityDelta <= 0 || (ctx.mode != LPOperationMode.OPEN && ctx.mode != LPOperationMode.INCREASE)
                || !registry.isLPAllowed(ctx.poolId)
        ) revert InvalidOperation();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Returns zero Hook delta after a validated liquidity addition.
    /// @dev V1 does not apply a Hook delta to the liquidity caller or accrued fees.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not adjust liquidity deltas.
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

    /// @notice Validates removal context and allows forced exits to bypass ordinary LP admission and pause checks.
    /// @param sender Contract that initiated PoolManager.modifyLiquidity.
    /// @param key Full V4 pool key being modified.
    /// @param params Tick range, salt, and liquidity change requested by the manager.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPHookContext memory ctx = _checkLP(sender, key, params, hookData);
        if (params.liquidityDelta > 0 || ctx.mode == LPOperationMode.OPEN || ctx.mode == LPOperationMode.INCREASE) {
            revert InvalidOperation();
        }
        if (ctx.mode == LPOperationMode.FORCE_EXIT) {
            if (params.liquidityDelta >= 0) revert InvalidOperation();
        } else if (!registry.isLPAllowed(ctx.poolId)) {
            revert InvalidPool();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Returns zero Hook delta after a validated liquidity removal.
    /// @dev V1 does not apply a Hook delta to the liquidity caller or accrued fees.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not adjust liquidity deltas.
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

    /// @notice Allows the configured Router to swap only through an active, tradable registered pool.
    /// @param sender Contract that initiated the swap; must equal the configured Router.
    /// @param key Full V4 pool key being swapped.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not alter the swap delta.
    /// @return Zero because V1 does not override the pool fee.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != router || hookData.length != 0) revert UnauthorizedCallback();
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (!registry.isTradable(poolId)) revert InvalidOperation();
        _requireExactKey(key, poolId);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /// @notice Converts actual stock-side swap deltas to legal shares and records them in the Ledger.
    /// @param sender Contract that initiated the swap; must equal the configured Router.
    /// @param key Full V4 pool key that was swapped.
    /// @param delta Actual PoolManager balance delta for both currencies.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not alter the swap delta.
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

    /// @notice Rejects donations because TSV V1 exposes no donation operation.
    /// @dev All callback inputs are ignored because donations are unsupported.
    /// @return Unreachable; the callback always reverts with `UnsupportedCallback`.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    /// @notice Rejects post-donation callbacks because TSV V1 does not support donations.
    /// @dev All callback inputs are ignored because donations are unsupported.
    /// @return Unreachable; the callback always reverts with `UnsupportedCallback`.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    /// @dev Requires initialization to originate from the LP Manager for an exactly registered pending key.
    /// @param sender Contract that invoked the PoolManager operation.
    /// @param key Pool key being initialized.
    function _requirePending(address sender, PoolKey calldata key) private view {
        if (
            sender != lpManager || address(key.hooks) != address(this)
                || registry.getPool(PoolId.unwrap(key.toId())).status != PoolStatus.PENDING
        ) revert InvalidPool();
        _requireExactKey(key, PoolId.unwrap(key.toId()));
    }

    /// @dev Prevents a caller from reusing a registered pool ID with a different key.
    /// @param key Pool key supplied to the current PoolManager callback.
    /// @param poolId Identifier derived from that key.
    function _requireExactKey(PoolKey calldata key, bytes32 poolId) private view {
        PoolConfig memory pool = registry.getPool(poolId);
        if (keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))) revert InvalidPool();
    }

    /// @dev Matches the PoolManager callback against the LP Manager's one-operation context.
    /// @param sender Contract that invoked the liquidity modification.
    /// @param key Pool key being modified.
    /// @param params Tick range, salt, and liquidity delta from PoolManager.
    /// @param hookData Additional callback data, which must be empty.
    /// @return ctx Validated LP context for the current operation.
    function _checkLP(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) private view returns (LPHookContext memory ctx) {
        if (sender != lpManager || hookData.length != 0) revert UnauthorizedCallback();
        ctx = IActiveLPContextV1(lpManager).activeLPContext();
        if (
            ctx.poolId == 0 || ctx.poolId != PoolId.unwrap(key.toId()) || ctx.salt != params.salt
                || ctx.tickLower != params.tickLower || ctx.tickUpper != params.tickUpper
                || ctx.liquidityDelta != params.liquidityDelta
        ) revert InvalidOperation();
        _requireExactKey(key, ctx.poolId);
    }

    /// @dev Converts the absolute raw delta of a stock leg; non-stock and zero deltas account as zero.
    /// @param securityId Security assigned to the pool leg, or zero for an ordinary Currency.
    /// @param currency Pool Currency whose adapter performs the legal-share conversion.
    /// @param delta Actual signed PoolManager delta for this leg.
    /// @return Legal-share amount in WAD for the Ledger.
    function _sharesForLeg(bytes32 securityId, address currency, int128 delta) private view returns (uint256) {
        if (securityId == 0 || delta == 0) return 0;
        TokenConfig memory config = registry.getToken(currency);
        if (config.securityId != securityId || config.legalShareAdapter == address(0)) revert InvalidPool();
        uint256 rawAmount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        return IDirectLegalShareAdapter(config.legalShareAdapter).toLegalShares(currency, rawAmount);
    }
}
