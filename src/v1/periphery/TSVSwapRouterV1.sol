// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolConfig, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";

/// @notice One-pool credential-gated swap entry; the participant settles each PoolKey currency directly.
contract TSVSwapRouterV1 is TSVGoverned {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error Unauthorized();
    error InvalidRequest();
    error InvalidPool();
    error Expired();
    error SlippageExceeded();
    error SettlementMismatch();
    error Reentrancy();

    struct Active {
        bytes32 poolId;
        address participant;
    }

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    TSVHookV1 public hook;
    bool private entered;
    Active private active;

    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    function initialize(
        address authority,
        address timelock,
        address controller,
        address poolManager_,
        address registry_,
        address ledger_,
        address hook_
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        if (
            poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0
                || hook_ == address(0)
        ) revert InvalidRequest();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        hook = TSVHookV1(hook_);
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    function swapExactInput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (!request.exactInput) revert InvalidRequest();
        return _swap(request);
    }

    function swapExactOutput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (request.exactInput) revert InvalidRequest();
        return _swap(request);
    }

    function activeSwapContext() external view returns (bool isActive, bytes32 poolId, address participant) {
        if (!entered || active.poolId == 0) return (false, 0, address(0));
        return (true, active.poolId, active.participant);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !entered || active.poolId == 0) revert Unauthorized();
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        if (PoolId.unwrap(request.key.toId()) != active.poolId || request.participant != active.participant) {
            revert Unauthorized();
        }
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            request.zeroForOne,
            request.exactInput ? -int256(uint256(request.amountSpecified)) : int256(uint256(request.amountSpecified)),
            request.sqrtPriceLimitX96
        );
        BalanceDelta delta = poolManager.swap(request.key, params, bytes(""));
        int128 inDelta = request.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = request.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert SlippageExceeded();
        uint256 actualIn = uint256(-int256(inDelta));
        uint256 actualOut = uint256(int256(outDelta));
        if (request.exactInput) {
            if (actualIn > request.amountSpecified || actualOut < request.limitAmount) revert SlippageExceeded();
        } else if (actualOut != request.amountSpecified || actualIn > request.limitAmount) {
            revert SlippageExceeded();
        }

        _settle(request.key.currency0, delta.amount0(), request.participant);
        _settle(request.key.currency1, delta.amount1(), request.participant);
        hook.assertCurrentAndClear();
        return abi.encode(actualIn, actualOut, delta);
    }

    function _swap(SwapRequest calldata request) private returns (uint256 actualIn, uint256 actualOut) {
        bytes32 poolId = _validate(request);
        active = Active(poolId, request.participant);
        bytes memory result = poolManager.unlock(abi.encode(request));
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        (bool exists, uint32 day) = ledger.currentTradeDay();
        if (!exists) revert InvalidPool();
        emit SwapExecuted(poolId, request.participant, request.zeroForOne, delta.amount0(), delta.amount1(), day);
        delete active;
    }

    function _validate(SwapRequest calldata request) private view returns (bytes32 poolId) {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.participant == address(0) || request.participant != msg.sender
                || request.participant != request.payer || request.participant != request.recipient
                || request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
        if (!registry.isEligible(request.participant)) revert Unauthorized();
        poolId = PoolId.unwrap(request.key.toId());
        if (!registry.isTradable(poolId)) revert InvalidPool();
        PoolConfig memory pool = registry.getPool(poolId);
        if (keccak256(abi.encode(pool.key)) != keccak256(abi.encode(request.key))) revert InvalidPool();
        (bool dayExists,) = ledger.currentTradeDay();
        if (!dayExists) revert InvalidPool();
    }

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
