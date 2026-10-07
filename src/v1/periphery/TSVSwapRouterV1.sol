// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SwapRequest, AssetStatus} from "tsv-v1/types/TSVTypes.sol";
import {SettlementAssetKind, SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
import {ISwapHookViews} from "tsv-v1/libraries/TSVSwapValidationLib.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {IV4Router} from "tsv-v1/vendor/v4-router/interfaces/IV4Router.sol";
import {Actions} from "tsv-v1/vendor/v4-router/libraries/Actions.sol";
import {CalldataDecoder} from "tsv-v1/vendor/v4-router/libraries/CalldataDecoder.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice One-pool W/Q swaps. Users pay and receive U for stocks and original Q for quotes.
contract TSVSwapRouterV1 is TSVGoverned, PermissionedV4Router {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using CalldataDecoder for bytes;

    error InvalidRequest();
    error InvalidPool();
    error Expired();
    error SlippageExceeded();
    error InputAmountTooLarge();
    error SettlementMismatch();
    error Reentrancy();
    error WrappedExternalAdapterUnsupported();
    error InvalidCallbackContext();
    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    bool private entered;
    bytes32 private activeRequestHash;
    bytes32 private activePayloadHash;
    bytes32 private activePolicyHash;
    bytes32 private activePoolId;
    address private activeParticipant;
    address private activeSettlementParticipant;
    uint64 private activeDeadline;
    bool private activeExactInput;
    bool private callbackConsumed;
    uint256 private activeAmountIn;
    uint256 private activeAmountOut;
    address private activeInputCurrency;
    address private activeOutputCurrency;
    uint256 private activeStockSurplus;

    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    /// @dev PM and the Registry Factory interface are fixed in implementation bytecode.
    constructor(address pm, address registry_)
        PermissionedV4Router(IPoolManager(pm), IPermissionsAdapterFactory(registry_))
    {}

    /// @notice Linked stateless validator used for runtime policy snapshots.
    function permissionedValidationLibrary() external pure returns (address) {
        return address(PermissionedValidationLib);
    }

    function initialize(address anchor, address pm, address registry_, address ledger_) external initializer {
        __TSVGoverned_init(anchor);
        if (
            pm.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0 || pm != address(poolManager)
                || registry_ != address(PERMISSIONS_ADAPTER_FACTORY)
        ) revert InvalidRequest();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        if (
            address(registry.governanceAnchor()) != anchor || address(ledger.governanceAnchor()) != anchor
                || address(ledger.registry()) != registry_
        ) revert InvalidRequest();
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Exact input may fill partially; only realized input is paid.
    function swapExactInput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swapUser(request, true);
    }

    /// @notice Exact output must fill exactly the requested amount.
    function swapExactOutput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swapUser(request, false);
    }

    /// @notice Reserved rejection entry for external DEX consumers.
    function swapExactInputFromAdapter(SwapRequest calldata, address) external pure returns (uint256, uint256) {
        revert WrappedExternalAdapterUnsupported();
    }

    /// @notice Returns the real user during an active operation, or zero while idle.
    function msgSender() public view override returns (address) {
        return entered ? activeParticipant : address(0);
    }

    function _swapUser(SwapRequest memory request, bool exactInput)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        _checkRequest(request);
        if (msg.sender == address(this)) revert Unauthorized();
        activeParticipant = msg.sender;
        activeSettlementParticipant = msg.sender;
        (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy) = _plans(request.key, msg.sender);
        bytes memory payload = _payload(request, exactInput);
        activePoolId = PoolId.unwrap(request.key.toId());
        activeDeadline = request.deadline;
        activeExactInput = exactInput;
        activeInputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency0 : request.key.currency1);
        activeOutputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency1 : request.key.currency0);
        activePayloadHash = keccak256(payload);
        activePolicyHash = policy;
        activeRequestHash = _requestHash(request, p0, p1);
        TSVPermissionedSettlementLib.StockInventory memory before_ = _stockInventory(p0, p1);
        activeStockSurplus = before_.collateral - before_.supply;
        bytes memory result = poolManager.unlock(payload);
        if (!callbackConsumed) revert InvalidCallbackContext();
        // Memory survives unlock and covers U changes on either the stock or quote transfer path.
        TSVPermissionedSettlementLib.assertUnderlyingUnchanged(before_, _stockInventory(p0, p1));
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        if (
            actualIn != activeAmountIn || actualOut != activeAmountOut
                || BalanceDelta.unwrap(delta) != BalanceDelta.unwrap(_delta(request.zeroForOne))
        ) revert InvalidCallbackContext();
        (, uint32 day) = ledger.currentTradeDay();
        int128 amountIn = -int128(uint128(actualIn));
        int128 amountOut = int128(uint128(actualOut));
        emit SwapExecuted(
            activePoolId,
            activeParticipant,
            request.zeroForOne,
            request.zeroForOne ? amountIn : amountOut,
            request.zeroForOne ? amountOut : amountIn,
            day
        );
        _clearContext();
    }

    /// @dev SafeCallback retains the external onlyPoolManager gate. This adds one-operation binding.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (
            !entered || callbackConsumed || activeParticipant == address(0) || activeRequestHash == bytes32(0)
                || keccak256(data) != activePayloadHash
        ) revert InvalidCallbackContext();
        callbackConsumed = true;
        SwapRequest memory request = _decodePayload(data);
        _checkRequest(request);
        (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy) =
            _plans(request.key, activeParticipant);
        if (policy != activePolicyHash || _requestHash(request, p0, p1) != activeRequestHash) {
            revert InvalidCallbackContext();
        }
        super._unlockCallback(data);
        _checkAmounts(request, activeAmountIn, activeAmountOut);
        if (
            poolManager.currencyDelta(address(this), request.key.currency0) != 0
                || poolManager.currencyDelta(address(this), request.key.currency1) != 0
        ) revert SettlementMismatch();
        (p0, p1, policy) = _plans(request.key, activeParticipant);
        if (policy != activePolicyHash || _requestHash(request, p0, p1) != activeRequestHash) {
            revert InvalidCallbackContext();
        }
        TSVPermissionedSettlementLib.StockInventory memory inventory = _stockInventory(p0, p1);
        if (inventory.collateral - inventory.supply != activeStockSurplus) revert SettlementMismatch();
        return abi.encode(activeAmountIn, activeAmountOut, _delta(request.zeroForOne));
    }

    function _validatePoolKey(PoolKey memory key) internal view override {
        if (
            !entered || !callbackConsumed || PoolId.unwrap(key.toId()) != activePoolId
                || !registry.isTradable(activePoolId)
                || keccak256(abi.encode(registry.getPool(activePoolId).key)) != keccak256(abi.encode(key))
        ) revert InvalidPool();
        super._validatePoolKey(key);
    }

    /// @dev Captures both realized deltas before paying. Exactly one sync/pay/settle sequence.
    function _settle(Currency currency, address payer, uint256 amount) internal override {
        if (
            !entered || !callbackConsumed || payer != activeParticipant
                || Currency.unwrap(currency) != activeInputCurrency || activeAmountIn != 0 || amount == 0
                || amount != _getFullDebt(currency)
        ) revert InvalidCallbackContext();
        uint256 output = _getFullCredit(Currency.wrap(activeOutputCurrency));
        _checkRepresentable(amount, output);
        activeAmountIn = amount;
        activeAmountOut = output;
        poolManager.sync(currency);
        // Parent _pay enforces swappingEnabled and isAllowed, then calls a transfer-only implementation.
        _pay(currency, activeSettlementParticipant, amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        address q = Currency.unwrap(currency);
        if (
            q != activeInputCurrency || payer != activeSettlementParticipant || payer == address(this)
                || registry.getCurrency(q).underlying != address(0)
                || registry.getQuoteToken(q).status != AssetStatus.APPROVED
        ) revert UnsupportedAsset(q);
        TSVPermissionedSettlementLib.transferExact(q, payer, address(poolManager), amount);
    }

    function _payPermissionedFromPayer(address payer, IPermissionsAdapter permissionsAdapter, address u, uint256 amount)
        internal
        override
    {
        address w = address(permissionsAdapter);
        if (
            w != activeInputCurrency || payer != activeSettlementParticipant || payer == address(this)
                || registry.getCurrency(w).underlying != u
        ) revert InvalidPermissionedConfig();
        TSVPermissionedSettlementLib.payStock(w, u, address(poolManager), payer, amount);
    }

    function _take(Currency currency, address recipient, uint256 amount) internal override {
        address c = Currency.unwrap(currency);
        if (
            !entered || !callbackConsumed || recipient != activeParticipant || c != activeOutputCurrency
                || activeAmountIn == 0 || amount == 0 || amount != activeAmountOut || amount != _getFullCredit(currency)
        ) revert InvalidCallbackContext();
        recipient = activeSettlementParticipant;
        address u = registry.getCurrency(c).underlying;
        if (u == address(0)) {
            if (registry.getQuoteToken(c).status != AssetStatus.APPROVED) revert UnsupportedAsset(c);
            uint256 pmBefore = IERC20(c).balanceOf(address(poolManager));
            uint256 recipientBefore = IERC20(c).balanceOf(recipient);
            super._take(currency, recipient, amount);
            TSVPermissionedSettlementLib.assertDecrease(pmBefore, IERC20(c).balanceOf(address(poolManager)), amount);
            TSVPermissionedSettlementLib.assertIncrease(recipientBefore, IERC20(c).balanceOf(recipient), amount);
        } else {
            TSVPermissionedSettlementLib.StockInventory memory before_ =
                TSVPermissionedSettlementLib.stockInventory(c, u, address(poolManager), recipient);
            uint256 recipientBefore = IERC20(u).balanceOf(recipient);
            super._take(currency, recipient, amount);
            TSVPermissionedSettlementLib.assertStockTake(
                before_, recipientBefore, c, u, address(poolManager), recipient, amount
            );
        }
    }

    function _plans(PoolKey memory key, address participant)
        private
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy)
    {
        if (registry.hook() != address(0) && ISwapHookViews(registry.hook()).ledger() != address(ledger)) {
            revert InvalidPermissionedConfig();
        }
        return PermissionedValidationLib.swapPlans(address(registry), address(poolManager), key, participant);
    }

    function _stockInventory(SettlementLegPlan memory p0, SettlementLegPlan memory p1)
        private
        view
        returns (TSVPermissionedSettlementLib.StockInventory memory)
    {
        SettlementLegPlan memory stock = p0.kind == SettlementAssetKind.PERMISSIONED_STOCK ? p0 : p1;
        return TSVPermissionedSettlementLib.stockInventory(
            stock.currency, stock.underlying, address(poolManager), activeSettlementParticipant
        );
    }

    function _checkRequest(SwapRequest memory request) private view {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
    }

    function _checkRepresentable(uint256 amountIn, uint256 amountOut) private pure {
        if (amountIn > uint256(uint128(type(int128).max))) revert InputAmountTooLarge();
        if (amountIn == 0 || amountOut == 0 || amountOut > uint256(uint128(type(int128).max))) {
            revert SlippageExceeded();
        }
    }

    function _checkAmounts(SwapRequest memory request, uint256 amountIn, uint256 amountOut) private view {
        _checkRepresentable(amountIn, amountOut);
        if (activeExactInput) {
            if (amountIn > request.amountSpecified || amountOut < request.limitAmount) revert SlippageExceeded();
        } else if (amountOut != request.amountSpecified || amountIn > request.limitAmount) {
            revert SlippageExceeded();
        }
    }

    function _requestHash(SwapRequest memory request, SettlementLegPlan memory p0, SettlementLegPlan memory p1)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                request,
                activeExactInput,
                activeParticipant,
                activeSettlementParticipant,
                p0,
                p1,
                activePayloadHash
            )
        );
    }

    function _payload(SwapRequest memory request, bool exactInput) private pure returns (bytes memory) {
        bytes[] memory params = new bytes[](3);
        Currency input = request.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.zeroForOne ? request.key.currency1 : request.key.currency0;
        if (exactInput) {
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, bytes("")
                )
            );
        } else {
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, bytes("")
                )
            );
        }
        params[1] = abi.encode(input, exactInput ? request.amountSpecified : request.limitAmount);
        params[2] = abi.encode(output, exactInput ? request.limitAmount : request.amountSpecified);
        return abi.encode(
            abi.encodePacked(
                uint8(exactInput ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _decodePayload(bytes calldata data) private view returns (SwapRequest memory request) {
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        if (
            actions.length != 3 || params.length != 3
                || uint8(actions[0])
                    != (activeExactInput ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE)
                || uint8(actions[1]) != Actions.SETTLE_ALL || uint8(actions[2]) != Actions.TAKE_ALL
        ) revert InvalidCallbackContext();
        if (activeExactInput) {
            IV4Router.ExactInputSingleParams calldata p = params[0].decodeSwapExactInSingleParams();
            if (p.hookData.length != 0 || p.minHopPriceX36 != 0) revert InvalidCallbackContext();
            request = SwapRequest(p.poolKey, p.zeroForOne, p.amountIn, p.amountOutMinimum, activeDeadline);
        } else {
            IV4Router.ExactOutputSingleParams calldata p = params[0].decodeSwapExactOutSingleParams();
            if (p.hookData.length != 0 || p.minHopPriceX36 != 0) revert InvalidCallbackContext();
            request = SwapRequest(p.poolKey, p.zeroForOne, p.amountOut, p.amountInMaximum, activeDeadline);
        }
        (Currency input, uint256 maxIn) = params[1].decodeCurrencyAndUint256();
        (Currency output, uint256 minOut) = params[2].decodeCurrencyAndUint256();
        if (
            Currency.unwrap(input) != activeInputCurrency || Currency.unwrap(output) != activeOutputCurrency
                || maxIn != (activeExactInput ? request.amountSpecified : request.limitAmount)
                || minOut != (activeExactInput ? request.limitAmount : request.amountSpecified)
        ) revert InvalidCallbackContext();
    }

    function _delta(bool zeroForOne) private view returns (BalanceDelta) {
        int128 input = -int128(uint128(activeAmountIn));
        int128 output = int128(uint128(activeAmountOut));
        return toBalanceDelta(zeroForOne ? input : output, zeroForOne ? output : input);
    }

    function _clearContext() private {
        delete activeRequestHash;
        delete activePayloadHash;
        delete activePolicyHash;
        delete activePoolId;
        delete activeParticipant;
        delete activeSettlementParticipant;
        delete activeDeadline;
        delete activeExactInput;
        delete callbackConsumed;
        delete activeAmountIn;
        delete activeAmountOut;
        delete activeInputCurrency;
        delete activeOutputCurrency;
        delete activeStockSurplus;
    }

    /// @dev Future upgrades must preserve immutable PM/Registry identities and the new storage layout.
    function _authorizeUpgrade(address implementation) internal view override {
        super._authorizeUpgrade(implementation);
        if (entered) revert Reentrancy();
        if (
            address(TSVSwapRouterV1(implementation).poolManager()) != address(poolManager)
                || address(TSVSwapRouterV1(implementation).PERMISSIONS_ADAPTER_FACTORY()) != address(registry)
        ) revert InvalidRequest();
    }
}
