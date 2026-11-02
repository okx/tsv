// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IPoolManager,
    IPermissionsAdapterFactory,
    IPermissionsAdapter,
    Currency,
    PoolKey,
    Actions,
    PermissionFlags,
    IHooks
} from "../vendor/permissionedPools/PermissionedPositionManager.sol";
import {ITSVPermissionedRegistry} from "../interfaces/ITSVPermissionedRegistry.sol";
import {CalldataDecoder} from "v4-periphery/libraries/CalldataDecoder.sol";
import {PositionInfo} from "v4-periphery/libraries/PositionInfoLibrary.sol";
import {ActionConstants} from "v4-periphery/libraries/ActionConstants.sol";
import {ISubscriber} from "v4-periphery/interfaces/ISubscriber.sol";
import {INotifier} from "v4-periphery/interfaces/INotifier.sol";
import {CustomRevert} from "../vendor/permissionedPools/base/Notifier.sol";
import {TSVPermissionedSettlementLib} from "./TSVPermissionedSettlementLib.sol";
import {PoolId} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";

/// @notice Linked copies of TSV LP and inherited periphery routines, executed in the manager's context.
/// @dev Holds no persistent state. Callback authorization uses the manager's existing transient slot.
library TSVLPManagerLib {
    using CalldataDecoder for bytes;
    using CustomRevert for *;

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error Unauthorized();
    error LpUnWindable();
    error PoolDelisted();
    error PoolTickCountUpdateFailed();
    error UnsupportedAction(uint256 action);
    error InvalidHook();
    error NoVerifiedAdapter();
    error PermissionedAdapterWithoutOwner();
    error NonContractCurrency();
    error PoolNotAllowed();
    error RegistryPaused();
    error UnAcceptableScenario();

    event IssuerPositionUnwound(
        uint256 indexed tokenId,
        address indexed lpOwner,
        address indexed issuer,
        address token0,
        address token1,
        uint256 lpReceivedAmount0,
        uint256 issuerReceivedAmount0,
        uint256 lpReceivedAmount1,
        uint256 issuerReceivedAmount1
    );

    event TsvPositionUnwound(
        uint256 indexed tokenId,
        address indexed lpOwner,
        address indexed issuer,
        address token0,
        address token1,
        uint256 lpReceivedAmount0,
        uint256 issuerReceivedAmount0,
        uint256 lpReceivedAmount1,
        uint256 issuerReceivedAmount1
    );

    event CurrencyUnwound(
        uint256 indexed tokenId,
        Currency indexed currency,
        address indexed recipient,
        address caller,
        address lp,
        uint256 amount,
        bool asClaim
    );

    /// @dev Pending callback hash, 1 during an authorized position burn, or 0 when inactive.
    bytes32 private constant UNWIND_CALLBACK_SLOT = bytes32(uint256(keccak256("tsv.lpmanager.unwind.callback")) - 1);

    struct UnwindParams {
        IPoolManager poolManager;
        IPermissionsAdapterFactory factory;
        uint256 deliveryGasLimit;
        uint256 unsubscribeGasLimit;
        PoolKey poolKey;
        uint256 tokenId;
        address lp;
        uint128 amount0Min;
        uint128 amount1Min;
        bytes hookData;
    }

    struct RecipientBalances {
        uint256 lp0;
        uint256 issuer0;
        uint256 lp1;
        uint256 issuer1;
    }

    function requireRole(ITSVPermissionedRegistry registry, bytes32 role) external view {
        if (!registry.hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);
    }

    function requireRegistryNotPaused(ITSVPermissionedRegistry registry) external view {
        if (registry.isPaused()) revert RegistryPaused();
    }

    /// @dev Original TSV exit body; state mappings and immutable dependencies are explicit parameters.
    function unwindPositionByTsv(
        UnwindParams memory p,
        mapping(uint256 => PositionInfo) storage positionInfo,
        mapping(uint256 => ISubscriber) storage subscriber,
        mapping(uint256 => address) storage approvals
    ) external {
        PoolKey memory poolKey = p.poolKey;
        uint256 tokenId = p.tokenId;
        address lp = p.lp;
        uint128 amount0Min = p.amount0Min;
        uint128 amount1Min = p.amount1Min;
        bytes memory hookData = p.hookData;
        bool isUnwindable0 = _getLpStatus(p.factory, poolKey.currency0, lp);
        bool isUnwindable1 = _getLpStatus(p.factory, poolKey.currency1, lp);
        if (!isUnwindable0 && !isUnwindable1) revert LpUnWindable();
        address issuer = _getPoolIssuer(p.factory, poolKey);
        Currency settlement0 = _settlementCurrency(p.factory, poolKey.currency0);
        Currency settlement1 = _settlementCurrency(p.factory, poolKey.currency1);
        uint256 lpBalance0Before = settlement0.balanceOf(lp);
        uint256 lpBalance1Before = settlement1.balanceOf(lp);

        // Unsubscribe with the PoolManager locked so notifyUnsubscribe can't strand a delta and brick the unlock.
        if (positionInfo[tokenId].hasSubscriber()) {
            unsubscribe(positionInfo, subscriber, tokenId, p.unsubscribeGasLimit);
            // The locked callback can still re-attach via subscribe; clear it so a reverting notifyBurn can't brick the burn.
            // Its notifyUnsubscribe is deliberately not called (attacker-chosen), but emit Unsubscription so indexers stay balanced.
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
                emit INotifier.Unsubscription(tokenId, reattached);
            }
        }

        // Approve so BURN_POSITION passes onlyIfApproved.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        approvals[tokenId] = msg.sender;

        // Burn the position and take both currencies, including accrued fees, directly to the LP.
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);
        _unlockWithAuthorizedCallback(p.poolManager, abi.encode(actions, params));
        emit TsvPositionUnwound(
            tokenId,
            lp,
            issuer,
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            settlement0.balanceOf(lp) > lpBalance0Before ? settlement0.balanceOf(lp) - lpBalance0Before: 0,
            0,
            settlement1.balanceOf(lp) > lpBalance1Before ? settlement1.balanceOf(lp) - lpBalance1Before: 0,
            0
        );
    }

    /// @dev Original TSV exit body; state mappings and immutable dependencies are explicit parameters.
    function unwindPosition(
        UnwindParams memory p,
        mapping(uint256 => PositionInfo) storage positionInfo,
        mapping(uint256 => ISubscriber) storage subscriber,
        mapping(uint256 => address) storage approvals
    ) external {
        PoolKey memory poolKey = p.poolKey;
        uint256 tokenId = p.tokenId;
        address lp = p.lp;
        uint128 amount0Min = p.amount0Min;
        uint128 amount1Min = p.amount1Min;
        bytes memory hookData = p.hookData;
        bool isUnwindable0 = _getLpStatus(p.factory, poolKey.currency0, lp);
        bool isUnwindable1 = _getLpStatus(p.factory, poolKey.currency1, lp);
        if (!isUnwindable0 && !isUnwindable1) revert LpUnWindable();
        address issuer = _getPoolIssuer(p.factory, poolKey);
        Currency settlement0 = _settlementCurrency(p.factory, poolKey.currency0);
        Currency settlement1 = _settlementCurrency(p.factory, poolKey.currency1);
        RecipientBalances memory beforeBalances = _recipientBalances(settlement0, settlement1, lp, issuer);
        // Unsubscribe with the PoolManager locked so notifyUnsubscribe can't strand a delta and brick the unlock.
        if (positionInfo[tokenId].hasSubscriber()) {
            unsubscribe(positionInfo, subscriber, tokenId, p.unsubscribeGasLimit);
            // The locked callback can still re-attach via subscribe; clear it so a reverting notifyBurn can't brick the burn.
            // Its notifyUnsubscribe is deliberately not called (attacker-chosen), but emit Unsubscription so indexers stay balanced.
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
                emit INotifier.Unsubscription(tokenId, reattached);
            }
        }

        // Approve so BURN_POSITION passes onlyIfApproved.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        approvals[tokenId] = msg.sender;

        // Burn the position; settle both currencies as 6909 claims to this contract.
        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.MINT_6909), uint8(Actions.MINT_6909));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        _unlockWithAuthorizedCallback(p.poolManager, abi.encode(actions, params));

        // Reads the full 6909 balance, not a burn delta: the burn output plus any stray MINT_6909 claims
        // parked in this contract.
        uint256 amount0 = p.poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = p.poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // Deliver the real asset to the LP, then the adapter owner; revert the unwind if neither accepts it.
        bool issuerReceived0 = _deliverCurrency(p, poolKey.currency0, amount0);
        bool issuerReceived1 = _deliverCurrency(p, poolKey.currency1, amount1);
        RecipientBalances memory afterBalances = _recipientBalances(settlement0, settlement1, lp, issuer);
        emit IssuerPositionUnwound(
            tokenId,
            lp,
            issuer,
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            issuerReceived0 ? 0 : (afterBalances.lp0 > beforeBalances.lp0 ? afterBalances.lp0 - beforeBalances.lp0 : 0),
            issuerReceived0 ? (afterBalances.issuer0 > beforeBalances.issuer0 ? afterBalances.issuer0 - beforeBalances.issuer0 : 0) : 0,
            issuerReceived1 ? 0 : (afterBalances.lp1 > beforeBalances.lp1 ? afterBalances.lp1 - beforeBalances.lp1 : 0),
            issuerReceived1 ? (afterBalances.issuer1 > beforeBalances.issuer1 ? afterBalances.issuer1 - beforeBalances.issuer1 : 0) : 0
        );
    }
    /// @dev Resolve once before delivery so both snapshots observe the same settlement assets.
    ///      Permissioned currencies unwrap on delivery; recipients hold U, not W.
    function _settlementCurrency(IPermissionsAdapterFactory factory, Currency currency)
        private
        view
        returns (Currency)
    {
        address underlying = factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        return underlying == address(0) ? currency : Currency.wrap(underlying);
    }


    function _recipientBalances(Currency currency0, Currency currency1, address lp, address issuer)
        private
        view
        returns (RecipientBalances memory balances)
    {
        balances.lp0 = currency0.balanceOf(lp);
        balances.issuer0 = currency0.balanceOf(issuer);
        balances.lp1 = currency1.balanceOf(lp);
        balances.issuer1 = currency1.balanceOf(issuer);
    }


    function _getPoolIssuer(IPermissionsAdapterFactory factory, PoolKey memory poolKey)
        private
        view
        returns (address issuer)
    {
        issuer = _getOwner(factory, poolKey.currency0);
        if (issuer == address(0)) issuer = _getOwner(factory, poolKey.currency1);
    }

    function _unlockWithAuthorizedCallback(IPoolManager poolManager, bytes memory data) private {
        authorizeCallback(keccak256(data));
        poolManager.unlock(data);
        authorizeCallback(bytes32(0));
    }

    /// @dev Lifted from PermissionedPositionManager._deliverCurrency without changing the fallback order.
    ///      Risk disclaimer (issue #6, item 4): an ordinary quote has no adapter owner and no delivery fallback.
    ///      If its LP recipient can reject a transfer, delivery failure reverts the burn and NFT count update.
    ///      Quote admission must exclude receiver-controlled rejection; this routine does not enforce it.
    function _deliverCurrency(UnwindParams memory p, Currency currency, uint256 amount)
        private
        returns (bool issuerReceived)
    {
        address lp = p.lp;
        uint256 tokenId = p.tokenId;
        if (amount == 0) return false;

        // Real asset to the LP.
        if (tryDeliverAsset(p.poolManager, p.deliveryGasLimit, currency, lp, amount)) {
            emit CurrencyUnwound(tokenId, currency, lp, msg.sender, lp, amount, false);
            return false;
        }
        // Then the admin (permissioned currencies only; renounce is disabled, so a permissioned admin is never zero).
        address admin = _getOwner(p.factory, currency);
        if (admin != address(0) && tryDeliverAsset(p.poolManager, p.deliveryGasLimit, currency, admin, amount)) {
            emit CurrencyUnwound(tokenId, currency, admin, msg.sender, lp, amount, false);
            return true;
        }
        revert UnAcceptableScenario();
    }

    function tryDeliverAsset(
        IPoolManager poolManager,
        uint256 deliveryGasLimit,
        Currency currency,
        address to,
        uint256 amount
    ) public returns (bool delivered) {
        bytes memory actions = abi.encodePacked(uint8(Actions.UNWIND_WITH_FALLBACK));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency, to, amount);
        bytes memory data = abi.encode(actions, params);
        authorizeCallback(keccak256(data));
        try poolManager.unlock{gas: deliveryGasLimit}(data) {
            delivered = true;
        } catch {
            delivered = false;
        }
        authorizeCallback(bytes32(0));
    }

    function authorizeCallback(bytes32 callbackHash) internal {
        bytes32 slot = UNWIND_CALLBACK_SLOT;
        assembly ("memory-safe") { tstore(slot, callbackHash) }
    }

    function authorizedCallbackHash() internal view returns (bytes32 callbackHash) {
        bytes32 slot = UNWIND_CALLBACK_SLOT;
        assembly ("memory-safe") { callbackHash := tload(slot) }
    }

    /// @dev User-funded ERC20 payments pull directly using an allowance to the LP Manager.
    ///      Permissioned underlyings are paid to their adapter and wrapped; quotes are paid to PoolManager.
    function pay(
        IPoolManager poolManager,
        IPermissionsAdapterFactory factory,
        Currency currency,
        address payer,
        uint256 amount,
        address executor
    ) external {
        address permissionedToken = factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            if (payer == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                TSVPermissionedSettlementLib.transferFromPayer(
                    Currency.unwrap(currency), payer, address(poolManager), amount
                );
            }
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        // Check liquidity permission for the actual user
        if (!permissionsAdapter.isAllowed(executor, PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
        } else {
            TSVPermissionedSettlementLib.transferFromPayer(
                permissionedToken, payer, address(permissionsAdapter), amount
            );
        }
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function checkPositionAction(
        ITSVPermissionedRegistry registry,
        uint256 action,
        bytes calldata params,
        address executor,
        mapping(uint256 => address) storage owners,
        mapping(uint256 => PositionInfo) storage positionInfo,
        mapping(bytes25 => PoolKey) storage poolKeys
    ) external view returns (PoolKey memory poolKey) {
        _requireLiquidityPermission(registry, executor);
        address owner;
        if (action == Actions.MINT_POSITION) {
            (PoolKey calldata key,,,,,, address recipient,) = params.decodeMintParams();
            poolKey = key;
            owner = _mapRecipient(recipient, executor);
        } else {
            uint256 tokenId = abi.decode(params, (uint256));
            require((owner = owners[tokenId]) != address(0), "NOT_MINTED");
            poolKey = poolKeys[positionInfo[tokenId].poolId()];
        }
        _requireLiquidityPermission(registry, owner);
        if (!registry.isLPAllowed(PoolId.unwrap(poolKey.toId()))) revert PoolNotAllowed();
    }

    function checkSettlementAction(
        ITSVPermissionedRegistry registry,
        uint256 action,
        bytes calldata params,
        address executor
    ) external view {
        // Contract-owned claims are created and spent only by authorized unwind callbacks.
        if (action == Actions.MINT_6909 || action == Actions.UNWIND_WITH_FALLBACK) revert Unauthorized();

        _requireLiquidityPermission(registry, executor);
        if (action == Actions.TAKE_PAIR) {
            (,, address recipient) = params.decodeCurrencyPairAndAddress();
            _requireLiquidityPermission(registry, _mapRecipient(recipient, executor));
        } else if (action == Actions.TAKE) {
            (, address recipient,) = params.decodeCurrencyAddressAndUint256();
            _requireLiquidityPermission(registry, _mapRecipient(recipient, executor));
        } else if (action == Actions.SWEEP) {
            (, address recipient) = params.decodeCurrencyAndAddress();
            _requireLiquidityPermission(registry, _mapRecipient(recipient, executor));
        } else if (
            action != Actions.SETTLE && action != Actions.SETTLE_PAIR && action != Actions.CLOSE_CURRENCY
                && action != Actions.CLEAR_OR_TAKE && action != Actions.WRAP && action != Actions.UNWRAP
        ) {
            revert UnsupportedAction(action);
        }
    }

    function _mapRecipient(address recipient, address executor) private view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) return executor;
        if (recipient == ActionConstants.ADDRESS_THIS) return address(this);
        return recipient;
    }

    function _requireLiquidityPermission(ITSVPermissionedRegistry registry, address account) private view {
        if (!registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, account)) revert Unauthorized();
    }

    /// @dev Identical validation order and errors to PermissionedPositionManager._validateLiquidityCurrency.
    function validateLiquidityCurrency(
        IPermissionsAdapterFactory factory,
        Currency currency,
        IHooks hooks,
        address owner
    ) external view returns (bool isVerifiedAdapter) {
        address currencyAddress = Currency.unwrap(currency);
        if (factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) {
            if (factory.permissionsAdapterOf(currencyAddress) != address(0)) {
                revert NoVerifiedAdapter();
            }
            // a non-adapter currency must be a real contract (native ETH excepted)
            if (currencyAddress != address(0) && currencyAddress.code.length == 0) revert NonContractCurrency();
            return false;
        }
        IPermissionsAdapter adapter = IPermissionsAdapter(currencyAddress);
        if (!adapter.allowedHooks(hooks)) revert InvalidHook();
        if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();
        return true;
    }

    /// @dev Forced exits use this internal path without the public entry point's owner approval check.
    function unsubscribe(
        mapping(uint256 => PositionInfo) storage positionInfo,
        mapping(uint256 => ISubscriber) storage subscriber,
        uint256 tokenId,
        uint256 unsubscribeGasLimit
    ) public {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber == NO_SUBSCRIBER) revert INotifier.NotSubscribed();
        positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // require that the remaining gas is sufficient to notify the subscriber
            // otherwise, users can select a gas limit where .notifyUnsubscribe hits OutOfGas yet the
            // transaction/unsubscription can still succeed
            if (gasleft() < unsubscribeGasLimit) INotifier.GasLimitTooLow.selector.revertWith();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {}
        }

        emit INotifier.Unsubscription(tokenId, address(_subscriber));
    }

    function _getLpStatus(IPermissionsAdapterFactory factory, Currency currency, address lp)
        private
        view
        returns (bool)
    {
        address underlying = factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (underlying == address(0)) return false;
        return IPermissionsAdapter(Currency.unwrap(currency)).isAllowed(lp, PermissionFlags.UNWIND_ALLOWED);
    }

    function initializePool(
        IPoolManager poolManager,
        IPermissionsAdapterFactory factory,
        ITSVPermissionedRegistry registry,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external returns (int24) {
        address permissionedToken0 = factory.verifiedPermissionsAdapterOf(Currency.unwrap(key.currency0));
        address permissionedToken1 = factory.verifiedPermissionsAdapterOf(Currency.unwrap(key.currency1));
        bool verified = false;
        if (permissionedToken0 != address(0)) {
            address owner0 = IPermissionsAdapter(Currency.unwrap(key.currency0)).owner();
            if (owner0 == address(0)) revert PermissionedAdapterWithoutOwner();
            verified = true;
        }
        if (permissionedToken1 != address(0)) {
            address owner1 = IPermissionsAdapter(Currency.unwrap(key.currency1)).owner();
            if (owner1 == address(0)) revert PermissionedAdapterWithoutOwner();
            verified = true;
        }
        if (!verified) revert NoVerifiedAdapter();
        registry.registerPool(key);
        return poolManager.initialize(key, sqrtPriceX96);
    }

    function requireUnwindAdmin(IPermissionsAdapterFactory factory, Currency currency0, Currency currency1)
        external
        view
    {
        address admin0 = _getOwner(factory, currency0);
        address admin1 = _getOwner(factory, currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();
    }

    function _getOwner(IPermissionsAdapterFactory factory, Currency currency) private view returns (address) {
        if (factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return address(0);
        return IPermissionsAdapter(Currency.unwrap(currency)).owner();
    }

    function updatePoolTickCount(ITSVPermissionedRegistry registry, PoolKey memory poolKey, int256 delta) external {
        if (!registry.updatePoolTickCount(poolKey, delta)) revert PoolTickCountUpdateFailed();
    }

    /// @dev Lifted from PermissionedPositionManager._sweep and PositionManager._sweep.
    function sweep(IPermissionsAdapterFactory factory, Currency currency, address to) external {
        address permissionedToken = factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            _sweepOrdinary(currency, to);
            return;
        }
        Currency underlying = Currency.wrap(permissionedToken);
        uint256 balance = underlying.balanceOfSelf();
        if (balance > 0) underlying.transfer(to, balance);
    }

    function _sweepOrdinary(Currency currency, address to) private {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }
}
