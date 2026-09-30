// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TokenConfig, PoolConfig, AssetBounds, SettlementMode, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSBTAdapterV1} from "tsv-v1/periphery/TSVSBTAdapterV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";

/// @notice One-pool authorized swap entry; users settle each PoolKey currency directly.
contract TSVSwapRouterV1 is TSVGoverned, EIP712Upgradeable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error Unauthorized();
    error InvalidRequest();
    error InvalidPool();
    error InvalidSignature();
    error NonceUnavailable();
    error Expired();
    error SlippageExceeded();
    error SettlementMismatch();
    error Reentrancy();

    bytes32 public constant SWAP_TYPEHASH = keccak256(
        "SwapAuthorization(address participant,address payer,address recipient,address authorizedCaller,bytes32 poolId,bool zeroForOne,bool exactInput,uint128 amountSpecified,uint128 limitAmount,uint160 sqrtPriceLimitX96,uint256 maxSharesIn0,uint256 minSharesOut0,uint256 maxDisplayedDebit0,uint256 minDisplayedCredit0,uint256 maxSharesIn1,uint256 minSharesOut1,uint256 maxDisplayedDebit1,uint256 minDisplayedCredit1,uint256 nonce,uint64 deadline)"
    );

    struct Authorization {
        address participant;
        address payer;
        address recipient;
        address authorizedCaller;
        bytes32 poolId;
        bool zeroForOne;
        bool exactInput;
        uint128 amountSpecified;
        uint128 limitAmount;
        uint160 sqrtPriceLimitX96;
        uint256 maxSharesIn0;
        uint256 minSharesOut0;
        uint256 maxDisplayedDebit0;
        uint256 minDisplayedCredit0;
        uint256 maxSharesIn1;
        uint256 minSharesOut1;
        uint256 maxDisplayedDebit1;
        uint256 minDisplayedCredit1;
        uint256 nonce;
        uint64 deadline;
    }

    struct Active {
        bytes32 operationId;
        bytes32 requestHash;
        bytes32 poolId;
        address participant;
        address currency0;
        address currency1;
        bool zeroForOne;
        bool exactInput;
    }

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    TSVSBTAdapterV1 public sbtAdapter;
    TSVHookV1 public hook;
    bool private entered;
    Active private active;
    mapping(address => mapping(uint256 => bool)) public nonceUnavailable;
    mapping(address => bool) public authorizedCallerAllowed;

    event SwapExecuted(
        bytes32 indexed operationId,
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );
    event SwapNonceCancelled(address indexed participant, uint256 indexed nonce);
    event AuthorizedCallerChanged(address indexed caller, bool allowed);

    function initialize(
        address authority,
        address timelock,
        address controller,
        address poolManager_,
        address registry_,
        address ledger_,
        address sbtAdapter_,
        address hook_
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        __EIP712_init("TSVSwapRouter", "2");
        if (
            poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0
                || sbtAdapter_.code.length == 0 || hook_ == address(0)
        ) revert InvalidRequest();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        sbtAdapter = TSVSBTAdapterV1(sbtAdapter_);
        hook = TSVHookV1(hook_);
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyGovernor {
        if (caller == address(0)) revert InvalidRequest();
        authorizedCallerAllowed[caller] = allowed;
        emit AuthorizedCallerChanged(caller, allowed);
    }

    function cancelSwapNonce(uint256 nonce) external {
        if (nonceUnavailable[msg.sender][nonce]) revert NonceUnavailable();
        nonceUnavailable[msg.sender][nonce] = true;
        emit SwapNonceCancelled(msg.sender, nonce);
    }

    function swapExactInput(SwapRequest calldata request, bytes calldata participantSignature)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (!request.exactInput) revert InvalidRequest();
        return _swap(request, participantSignature);
    }

    function swapExactOutput(SwapRequest calldata request, bytes calldata participantSignature)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (request.exactInput) revert InvalidRequest();
        return _swap(request, participantSignature);
    }

    function activeSwapOperation(bytes32 operationId)
        external
        view
        returns (bytes32 poolId, address participant, bool zeroForOne, bool exactInput)
    {
        if (active.operationId != operationId || operationId == 0) return (0, address(0), false, false);
        return (active.poolId, active.participant, active.zeroForOne, active.exactInput);
    }

    function activeAssetOperation(bytes32 operationId, address currency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit)
    {
        if (
            active.operationId != operationId || operationId == 0
                || (currency != active.currency0 && currency != active.currency1)
        ) return (0, address(0), address(0), false);
        return (active.poolId, active.participant, active.participant, false);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || active.operationId == 0 || keccak256(data) != active.requestHash) {
            revert Unauthorized();
        }
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            request.zeroForOne,
            request.exactInput ? -int256(uint256(request.amountSpecified)) : int256(uint256(request.amountSpecified)),
            request.sqrtPriceLimitX96
        );
        BalanceDelta delta = poolManager.swap(request.key, params, abi.encode(active.operationId));
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
        hook.assertCurrentAndClear(active.operationId);
        return abi.encode(actualIn, actualOut, delta);
    }

    function _swap(SwapRequest calldata request, bytes calldata signature)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        bytes32 poolId = _validateAndConsume(request, signature);
        bytes32 operationId =
            keccak256(abi.encode(block.chainid, address(this), request.participant, request.nonce, poolId));
        active = Active(
            operationId,
            keccak256(abi.encode(request)),
            poolId,
            request.participant,
            Currency.unwrap(request.key.currency0),
            Currency.unwrap(request.key.currency1),
            request.zeroForOne,
            request.exactInput
        );
        bytes memory result = poolManager.unlock(abi.encode(request));
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        (bool exists, uint32 day) = ledger.currentTradeDay();
        if (!exists) revert InvalidPool();
        emit SwapExecuted(
            operationId, poolId, request.participant, request.zeroForOne, delta.amount0(), delta.amount1(), day
        );
        delete active;
    }

    function _validateAndConsume(SwapRequest calldata request, bytes calldata signature)
        private
        returns (bytes32 poolId)
    {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.participant == address(0) || request.participant != request.payer
                || request.participant != request.recipient || request.amountSpecified == 0
                || request.amountSpecified > uint128(type(int128).max) || request.limitAmount == 0
        ) revert InvalidRequest();
        if (!sbtAdapter.isEligible(request.participant)) revert Unauthorized();
        poolId = PoolId.unwrap(request.key.toId());
        if (!registry.isTradable(poolId)) revert InvalidPool();
        PoolConfig memory pool = registry.getPool(poolId);
        if (keccak256(abi.encode(pool.key)) != keccak256(abi.encode(request.key))) revert InvalidPool();
        (bool dayExists,) = ledger.currentTradeDay();
        if (!dayExists) revert InvalidPool();
        _validateBounds(Currency.unwrap(request.key.currency0), request.bounds0);
        _validateBounds(Currency.unwrap(request.key.currency1), request.bounds1);
        if (nonceUnavailable[request.participant][request.nonce]) revert NonceUnavailable();
        if (request.authorizedCaller == address(0)) {
            if (msg.sender != request.participant || signature.length != 0) revert Unauthorized();
        } else {
            if (
                msg.sender != request.authorizedCaller || !authorizedCallerAllowed[msg.sender]
                    || !SignatureChecker.isValidSignatureNow(
                        request.participant, _hashTypedDataV4(_requestStructHash(request, poolId)), signature
                    )
            ) revert InvalidSignature();
        }
        nonceUnavailable[request.participant][request.nonce] = true;
    }

    function _validateBounds(address currency, AssetBounds calldata bounds) private view {
        TokenConfig memory config = registry.getToken(currency);
        if (
            config.settlementMode != SettlementMode.DIRECT_ERC20 || config.userToken != currency
                || bounds.maxSharesIn != 0 || bounds.minSharesOut != 0 || bounds.maxDisplayedDebit != 0
                || bounds.minDisplayedCredit != 0
        ) revert InvalidRequest();
    }

    function _settle(Currency currency, int128 delta, address participant) private {
        address token = Currency.unwrap(currency);
        TokenConfig memory config = registry.getToken(token);
        if (config.settlementMode != SettlementMode.DIRECT_ERC20 || config.userToken != token) revert InvalidPool();
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        if (delta < 0) {
            poolManager.sync(currency);
            uint256 payerBefore = IERC20(token).balanceOf(participant);
            uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
            IERC20(token).safeTransferFrom(participant, address(poolManager), amount);
            uint256 payerAfter = IERC20(token).balanceOf(participant);
            uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
            if (
                payerAfter > payerBefore || payerBefore - payerAfter != amount || poolAfter < poolBefore
                    || poolAfter - poolBefore != amount || poolManager.settle() != amount
            ) revert SettlementMismatch();
        } else {
            uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
            uint256 recipientBefore = IERC20(token).balanceOf(participant);
            poolManager.take(currency, participant, amount);
            uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
            uint256 recipientAfter = IERC20(token).balanceOf(participant);
            if (
                poolAfter > poolBefore || poolBefore - poolAfter != amount || recipientAfter < recipientBefore
                    || recipientAfter - recipientBefore != amount
            ) {
                revert SettlementMismatch();
            }
        }
    }

    function _requestStructHash(SwapRequest calldata request, bytes32 poolId) private pure returns (bytes32) {
        Authorization memory auth;
        auth.participant = request.participant;
        auth.payer = request.payer;
        auth.recipient = request.recipient;
        auth.authorizedCaller = request.authorizedCaller;
        auth.poolId = poolId;
        auth.zeroForOne = request.zeroForOne;
        auth.exactInput = request.exactInput;
        auth.amountSpecified = request.amountSpecified;
        auth.limitAmount = request.limitAmount;
        auth.sqrtPriceLimitX96 = request.sqrtPriceLimitX96;
        auth.maxSharesIn0 = request.bounds0.maxSharesIn;
        auth.minSharesOut0 = request.bounds0.minSharesOut;
        auth.maxDisplayedDebit0 = request.bounds0.maxDisplayedDebit;
        auth.minDisplayedCredit0 = request.bounds0.minDisplayedCredit;
        auth.maxSharesIn1 = request.bounds1.maxSharesIn;
        auth.minSharesOut1 = request.bounds1.minSharesOut;
        auth.maxDisplayedDebit1 = request.bounds1.maxDisplayedDebit;
        auth.minDisplayedCredit1 = request.bounds1.minDisplayedCredit;
        auth.nonce = request.nonce;
        auth.deadline = request.deadline;
        return keccak256(abi.encode(SWAP_TYPEHASH, auth));
    }
}
