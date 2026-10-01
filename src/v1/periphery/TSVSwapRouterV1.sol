// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";

/// @notice One-pool credential-gated swap entry; the participant settles each PoolKey currency directly.
contract TSVSwapRouterV1 is TSVGoverned {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the swap request contains invalid amounts, bounds, or parameters.
    error InvalidRequest();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();
    /// @dev Reverts when the actual amount falls outside the caller supplied bounds.
    error SlippageExceeded();
    /// @dev Reverts when the input amount cannot be represented by the PoolManager delta type.
    error InputAmountTooLarge();
    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();
    /// @dev Reverts when a second operation was attempted while another operation is active.
    error Reentrancy();

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    bool private entered;

    /// @notice Emitted when a validated one-pool swap completed and its actual deltas were recorded.
    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    /// @notice Initializes governance and binds the PoolManager, Registry, and Volume Ledger.
    /// @param authority Business authority used by the governed base contract.
    /// @param timelock Upgrade timelock used by the governed base contract.
    /// @param controller Emergency upgrade controller used by the governed base contract.
    /// @param poolManager_ V4 PoolManager used to execute swaps and settle deltas.
    /// @param registry_ Registry used for SBT eligibility and pool tradability checks.
    /// @param ledger_ Volume Ledger used to read the trade day for swap events.
    function initialize(
        address authority,
        address timelock,
        address controller,
        address poolManager_,
        address registry_,
        address ledger_
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        if (poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0) {
            revert InvalidRequest();
        }
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    /// @dev Prevents nested user swaps while the PoolManager invokes the unlock callback.
    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Executes a direct, single-pool swap with an exact input amount.
    /// @param request Pool, direction, input amount, minimum output, price limit, and deadline.
    /// @return actualIn Input Currency amount actually paid by the caller.
    /// @return actualOut Output Currency amount actually received by the caller.
    function swapExactInput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, true);
    }

    /// @notice Executes a direct, single-pool swap for an exact output amount.
    /// @param request Pool, direction, output amount, maximum input, price limit, and deadline.
    /// @return actualIn Input Currency amount actually paid by the caller.
    /// @return actualOut Output Currency amount actually received by the caller.
    function swapExactOutput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, false);
    }

    /// @notice Executes the validated swap and settles both currency deltas during PoolManager unlock.
    /// @dev Accepts callbacks only from the configured PoolManager while a router call is active.
    /// @param data Encoded swap request, participant, and exact-input mode supplied by `_swap`.
    /// @return Encoded actual input, actual output, and the PoolManager balance delta.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !entered) revert Unauthorized();
        (SwapRequest memory request, address participant, bool exactInput) =
            abi.decode(data, (SwapRequest, address, bool));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            request.zeroForOne,
            exactInput ? -int256(uint256(request.amountSpecified)) : int256(uint256(request.amountSpecified)),
            request.sqrtPriceLimitX96
        );
        BalanceDelta delta = poolManager.swap(request.key, params, bytes(""));
        int128 inDelta = request.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = request.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert SlippageExceeded();
        if (inDelta == type(int128).min) revert InputAmountTooLarge();
        uint256 actualIn = uint256(-int256(inDelta));
        uint256 actualOut = uint256(int256(outDelta));
        if (exactInput) {
            if (actualIn > request.amountSpecified || actualOut < request.limitAmount) revert SlippageExceeded();
        } else if (actualOut != request.amountSpecified || actualIn > request.limitAmount) {
            revert SlippageExceeded();
        }

        _settle(request.key.currency0, delta.amount0(), participant);
        _settle(request.key.currency1, delta.amount1(), participant);
        return abi.encode(actualIn, actualOut, delta);
    }

    /// @dev Validates the caller and request, runs the PoolManager unlock, and emits the executed delta.
    /// @param request User-supplied one-pool swap parameters.
    /// @param exactInput True for exact input; false for exact output.
    /// @return actualIn Input Currency amount actually paid.
    /// @return actualOut Output Currency amount actually received.
    function _swap(SwapRequest calldata request, bool exactInput)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        address participant = msg.sender;
        bytes32 poolId = _validate(request, participant);
        bytes memory result = poolManager.unlock(abi.encode(request, participant, exactInput));
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        (, uint32 day) = ledger.currentTradeDay();
        emit SwapExecuted(poolId, participant, request.zeroForOne, delta.amount0(), delta.amount1(), day);
    }

    /// @dev Enforces deadline, amount bounds, SBT eligibility, and current pool tradability.
    /// @param request Swap parameters to validate.
    /// @param participant Address that pays for and receives the swap.
    /// @return poolId Identifier derived from the request's PoolKey.
    function _validate(SwapRequest calldata request, address participant) private view returns (bytes32 poolId) {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
        if (!registry.isEligible(participant)) revert Unauthorized();
        poolId = PoolId.unwrap(request.key.toId());
        if (!registry.isTradable(poolId)) revert InvalidPool();
    }

    /// @dev Pays a negative delta from the participant or takes a positive delta to the participant.
    /// @param currency Currency whose delta is being settled.
    /// @param delta Signed PoolManager delta for that Currency.
    /// @param participant Caller who directly pays or receives the Currency.
    function _settle(Currency currency, int128 delta, address participant) private {
        address token = Currency.unwrap(currency);
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        if (delta < 0) {
            TSVDirectSettlementLib.settleFrom(poolManager, currency, token, participant, amount);
        } else {
            TSVDirectSettlementLib.takeTo(poolManager, currency, token, participant, amount);
        }
    }
}
