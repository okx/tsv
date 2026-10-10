// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PermissionedPositionManager,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    IPermissionsAdapter,
    PoolKey,
    Currency,
    Actions,
    IHooks,
    PermissionFlags
} from "../vendor/permissionedPools/PermissionedPositionManager.sol";
import {TSVGoverned} from "../governance/TSVGoverned.sol";
import {IStatusQuoter} from "../interfaces/IStatusQuoter.sol";
import {ITSVPermissionedRegistry} from "../interfaces/ITSVPermissionedRegistry.sol";
import {PoolLifecycle} from "../types/TSVTypes.sol";
import {ITokenApproveProxy} from "../interfaces/ITokenApproveProxy.sol";
import {CalldataDecoder} from "v4-periphery/libraries/CalldataDecoder.sol";
import {
    PermissionFlags as RegistryPermissionFlags
} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {ERC721, ERC721Permit_v4} from "../vendor/permissionedPools/base/ERC721Permit_v4.sol";
import {PositionManager} from "../vendor/permissionedPools/PositionManager.sol";
import {BaseActionsRouter} from "../vendor/permissionedPools/base/BaseActionsRouter.sol";
import {SafeCallback} from "../vendor/permissionedPools/base/SafeCallback.sol";
import {Permit2Forwarder} from "../vendor/permissionedPools/base/Permit2Forwarder.sol";
import {UnorderedNonce} from "../vendor/permissionedPools/base/UnorderedNonce.sol";
import {Notifier} from "../vendor/permissionedPools/base/Notifier.sol";
import {Multicall_v4} from "../vendor/permissionedPools/base/Multicall_v4.sol";
import {IERC721Permit_v4} from "v4-periphery/interfaces/IERC721Permit_v4.sol";
import {IPermit2Forwarder} from "v4-periphery/interfaces/IPermit2Forwarder.sol";
import {IUnorderedNonce} from "v4-periphery/interfaces/IUnorderedNonce.sol";
import {INotifier} from "v4-periphery/interfaces/INotifier.sol";
import {IMulticall_v4} from "v4-periphery/interfaces/IMulticall_v4.sol";
import {PoolInitializer_v4} from "../vendor/permissionedPools/base/PoolInitializer_v4.sol";
import {IPoolInitializer_v4} from "v4-periphery/interfaces/IPoolInitializer_v4.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract TSVLPManagerV1 is PermissionedPositionManager, TSVGoverned {
    using CalldataDecoder for bytes;

    error LpUnWindable();
    error InvalidRegistry();
    error PoolDelisted();
    error RegistryPaused();
    error PoolTickCountUpdateFailed();
    error IncompatibleImplementation();
    error InvalidApproveProxy();

    /// @notice Shared approval proxy; users approve its TokenApprove, not this LP Manager.
    ITokenApproveProxy public immutable TOKEN_APPROVE_PROXY;

    ITSVPermissionedRegistry public registry;

    // Authorizes exactly one internally constructed PoolManager callback, independently of proxy storage.
    bytes32 private constant UNWIND_CALLBACK_SLOT = bytes32(uint256(keccak256("tsv.lpmanager.unwind.callback")) - 1);

    uint256[48] private __gap;

    modifier whenRegistryNotPaused() {
        _requireRegistryNotPaused();
        _;
    }

    /// @dev Fixed integration parameters belong to the implementation. Upgrades must preserve them.
    ///      TSVGoverned's constructor disables initialization on the implementation itself.
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IPermissionsAdapterFactory _permissionsAdapterFactory,
        uint256 _deliveryGasLimit,
        ITSVPermissionedRegistry _registry,
        ITokenApproveProxy _tokenApproveProxy
    )
        PermissionedPositionManager(
            _poolManager,
            _permit2,
            _unsubscribeGasLimit,
            _tokenDescriptor,
            _weth9,
            _permissionsAdapterFactory,
            _deliveryGasLimit
        )
        TSVGoverned()
    {
        if (address(_registry).code.length == 0) revert InvalidRegistry();
        if (address(_tokenApproveProxy).code.length == 0) revert InvalidApproveProxy();
        if (_tokenApproveProxy.tokenApprove().code.length == 0) revert InvalidApproveProxy();
        TOKEN_APPROVE_PROXY = _tokenApproveProxy;
        registry = _registry;
        _disableInitializers();
    }

    /// @notice Initializes proxy governance, Registry and ERC-721 state exactly once.
    /// @dev Supply this call as the ERC-1967 proxy's constructor initialization data.
    function initialize(address anchor, ITSVPermissionedRegistry _registry) external initializer {
        if (address(_registry).code.length == 0) revert InvalidRegistry();
        __TSVGoverned_init(anchor);
        registry = _registry;
        nextTokenId = 1;
        // The EIP712 signing name remains "Uniswap v4 Positions NFT" for upstream compatibility.
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
    }

    /// @notice Registers and initializes a pool atomically at the supplied initial price.
    /// @dev Initialization failures propagate and roll back Registry registration.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96)
        public
        payable
        override(PoolInitializer_v4, IPoolInitializer_v4)
        onlyRole(POOL_CREATOR_ROLE)
        whenRegistryNotPaused
        isNotLocked
        returns (int24 tick)
    {
        bool verifiedPermissionedToken0 = _verifiedPermissionedTokenOf(key.currency0) != address(0);
        bool verifiedPermissionedToken1 = _verifiedPermissionedTokenOf(key.currency1) != address(0);
        if (!verifiedPermissionedToken0 && !verifiedPermissionedToken1) revert NoVerifiedAdapter();
        registry.registerPool(key);
        return poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Burns the position and returns principal and accrued fees directly to the LP.
    /// @dev Either currency failing delivery reverts the entire unwind.
    function unwindPositionByOkx(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        onlyRole(FORCE_EXIT_ADMIN_ROLE)
        whenRegistryNotPaused
        isNotLocked
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address lp = ownerOf(tokenId);
        bool isUnwindable0 = _getLpStatus(poolKey.currency0, lp);
        bool isUnwindable1 = _getLpStatus(poolKey.currency1, lp);
        if (!isUnwindable0 && !isUnwindable1) revert LpUnWindable();
        // Unsubscribe with the PoolManager locked so notifyUnsubscribe can't strand a delta and brick the unlock.
        if (positionInfo[tokenId].hasSubscriber()) {
            _unsubscribe(tokenId);
            // The locked callback can still re-attach via subscribe; clear it so a reverting notifyBurn can't brick the burn.
            // Its notifyUnsubscribe is deliberately not called (attacker-chosen), but emit Unsubscription so indexers stay balanced.
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                _setUnsubscribed(tokenId);
                emit Unsubscription(tokenId, reattached);
            }
        }

        // Approve so BURN_POSITION passes onlyIfApproved.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        getApproved[tokenId] = msg.sender;

        // Burn the position and take both currencies, including accrued fees, directly to the LP.
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, lp);
        _unlockUnwind(abi.encode(actions, params));
    }

    function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        public
        override
        whenRegistryNotPaused
        isNotLocked
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address lp = ownerOf(tokenId);
        bool isUnwindable0 = _getLpStatus(poolKey.currency0, lp);
        bool isUnwindable1 = _getLpStatus(poolKey.currency1, lp);
        if (!isUnwindable0 && !isUnwindable1) revert LpUnWindable();
        // Unsubscribe with the PoolManager locked so notifyUnsubscribe can't strand a delta and brick the unlock.
        if (positionInfo[tokenId].hasSubscriber()) {
            _unsubscribe(tokenId);
            // The locked callback can still re-attach via subscribe; clear it so a reverting notifyBurn can't brick the burn.
            // Its notifyUnsubscribe is deliberately not called (attacker-chosen), but emit Unsubscription so indexers stay balanced.
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                _setUnsubscribed(tokenId);
                emit Unsubscription(tokenId, reattached);
            }
        }

        // Approve so BURN_POSITION passes onlyIfApproved.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        getApproved[tokenId] = msg.sender;

        // Burn the position; settle both currencies as 6909 claims to this contract.
        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.MINT_6909), uint8(Actions.MINT_6909));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        _unlockUnwind(abi.encode(actions, params));

        // Reads the full 6909 balance, not a burn delta: the burn output plus any stray MINT_6909 claims
        // parked in this contract.
        uint256 amount0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // Deliver the real asset to the LP, then the admin; on any grief, hand over the 6909 claim instead.
        _deliverCurrency(poolKey.currency0, lp, tokenId, amount0);
        _deliverCurrency(poolKey.currency1, lp, tokenId, amount1);
    }

    // Inherited write entry points apply TSV pause policy here; parent calls retain their original checks.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        public
        payable
        override
        whenRegistryNotPaused
    {
        PositionManager.modifyLiquidities(unlockData, deadline);
    }

    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        public
        payable
        override
        whenRegistryNotPaused
    {
        PositionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    function withdrawClaim(Currency currency, uint256 amount, address to) public override whenRegistryNotPaused {
        PermissionedPositionManager.withdrawClaim(currency, amount, to);
    }

    function approve(address spender, uint256 tokenId) public override whenRegistryNotPaused {
        ERC721Permit_v4.approve(spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public override whenRegistryNotPaused {
        ERC721Permit_v4.setApprovalForAll(operator, approved);
    }

    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        public
        payable
        override(ERC721Permit_v4, IERC721Permit_v4)
        whenRegistryNotPaused
    {
        ERC721Permit_v4.permit(spender, tokenId, deadline, nonce, signature);
    }

    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) public payable override(ERC721Permit_v4, IERC721Permit_v4) whenRegistryNotPaused {
        ERC721Permit_v4.permitForAll(owner, operator, approved, deadline, nonce, signature);
    }

    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        public
        payable
        override(Permit2Forwarder, IPermit2Forwarder)
        whenRegistryNotPaused
        returns (bytes memory err)
    {
        return Permit2Forwarder.permit(owner, permitSingle, signature);
    }

    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata permits, bytes calldata signature)
        public
        payable
        override(Permit2Forwarder, IPermit2Forwarder)
        whenRegistryNotPaused
        returns (bytes memory err)
    {
        return Permit2Forwarder.permitBatch(owner, permits, signature);
    }

    function revokeNonce(uint256 nonce) public payable override(UnorderedNonce, IUnorderedNonce) whenRegistryNotPaused {
        UnorderedNonce.revokeNonce(nonce);
    }

    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        public
        payable
        override(Notifier, INotifier)
        whenRegistryNotPaused
    {
        Notifier.subscribe(tokenId, newSubscriber, data);
    }

    function unsubscribe(uint256 tokenId) public payable override(Notifier, INotifier) whenRegistryNotPaused {
        Notifier.unsubscribe(tokenId);
    }

    function multicall(bytes[] calldata data)
        public
        payable
        override(Multicall_v4, IMulticall_v4)
        whenRegistryNotPaused
        returns (bytes[] memory results)
    {
        return Multicall_v4.multicall(data);
    }

    function unlockCallback(bytes calldata data) public override whenRegistryNotPaused returns (bytes memory) {
        return SafeCallback.unlockCallback(data);
    }

    receive() external payable override whenRegistryNotPaused {
        _receiveNative();
    }

    function grantRole(bytes32 role, address account) public override whenRegistryNotPaused {
        TSVGoverned.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override whenRegistryNotPaused {
        TSVGoverned.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account) public override whenRegistryNotPaused {
        TSVGoverned.renounceRole(role, account);
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        whenRegistryNotPaused
    {
        UUPSUpgradeable.upgradeToAndCall(newImplementation, data);
    }

    /// @dev Normal callbacks retain the upstream action ABI. An unwind callback must match the exact data
    ///      committed by an authorized entry point, and its authorization is consumed before executing actions.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        bytes32 expected = _authorizedUnwindCallback();
        if (expected == bytes32(0)) return BaseActionsRouter._unlockCallback(data);
        if (keccak256(data) != expected) revert Unauthorized();

        _authorizeUnwindCallback(bytes32(0));
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        if (actions.length != params.length) revert InputLengthMismatch();
        for (uint256 i; i < actions.length; ++i) {
            uint256 action = uint8(actions[i]);
            if (action == Actions.BURN_POSITION) {
                uint256 tokenId = abi.decode(params[i], (uint256));
                (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
                PermissionedPositionManager._handleAction(action, params[i]);
                _updatePoolTickCount(poolKey, -1);
            } else if (
                action == Actions.TAKE_PAIR || action == Actions.MINT_6909 || action == Actions.UNWIND_WITH_FALLBACK
            ) {
                PermissionedPositionManager._handleAction(action, params[i]);
            } else {
                revert UnsupportedAction(action);
            }
        }
        return "";
    }

    /// @dev Only ordinary actions reach this dispatcher; forced exits execute through their authorized callback.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (
            action == Actions.MINT_POSITION || action == Actions.MINT_POSITION_FROM_DELTAS
                || action == Actions.INCREASE_LIQUIDITY || action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS
                || action == Actions.DECREASE_LIQUIDITY || action == Actions.BURN_POSITION
        ) {
            _handlePositionAction(action, params);
            return;
        }
        _handleSettlementAction(action, params);
    }

    /// @dev Position actions check both executor and owner, then lifecycle, before execution and NFT accounting.
    function _handlePositionAction(uint256 action, bytes calldata params) private {
        _requireLiquidityPermission(msgSender());
        address owner;
        PoolKey memory poolKey;
        if (action == Actions.MINT_POSITION) {
            (PoolKey calldata key,,,,,, address recipient,) = params.decodeMintParams();
            poolKey = key;
            owner = _mapRecipient(recipient);
        } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
            (PoolKey calldata key,,,,, address recipient,) = params.decodeMintFromDeltasParams();
            poolKey = key;
            owner = _mapRecipient(recipient);
        } else {
            uint256 tokenId = abi.decode(params, (uint256));
            owner = ownerOf(tokenId);
            (poolKey,) = getPoolAndPositionInfo(tokenId);
        }
        _requireLiquidityPermission(owner);
        _requirePoolNotDelisted(poolKey);
        PermissionedPositionManager._handleAction(action, params);
        if (action == Actions.MINT_POSITION || action == Actions.MINT_POSITION_FROM_DELTAS) {
            _updatePoolTickCount(poolKey, 1);
        } else if (action == Actions.BURN_POSITION) {
            _updatePoolTickCount(poolKey, -1);
        }
    }

    /// @dev Explicit recipients are checked after resolving sentinels. CLOSE_CURRENCY and CLEAR_OR_TAKE
    ///      always pay the already checked executor. The parent additionally checks BURN_6909 claim ownership.
    function _handleSettlementAction(uint256 action, bytes calldata params) private {
        // Contract-owned claims are created and spent only by authorized unwind callbacks.
        if (action == Actions.MINT_6909 || action == Actions.UNWIND_WITH_FALLBACK) revert Unauthorized();

        _requireLiquidityPermission(msgSender());
        if (action == Actions.TAKE_PAIR) {
            (,, address recipient) = params.decodeCurrencyPairAndAddress();
            _requireLiquidityPermission(_mapRecipient(recipient));
        } else if (action == Actions.TAKE) {
            (, address recipient,) = params.decodeCurrencyAddressAndUint256();
            _requireLiquidityPermission(_mapRecipient(recipient));
        } else if (action == Actions.SWEEP) {
            (, address recipient) = params.decodeCurrencyAndAddress();
            _requireLiquidityPermission(_mapRecipient(recipient));
        } else if (
            action != Actions.SETTLE && action != Actions.SETTLE_PAIR && action != Actions.CLOSE_CURRENCY
                && action != Actions.CLEAR_OR_TAKE && action != Actions.WRAP && action != Actions.UNWRAP
                && action != Actions.BURN_6909
        ) {
            revert UnsupportedAction(action);
        }
        PermissionedPositionManager._handleAction(action, params);
    }

    function _unlockUnwind(bytes memory data) private {
        _authorizeUnwindCallback(keccak256(data));
        poolManager.unlock(data);
        _authorizeUnwindCallback(bytes32(0));
    }

    /// @dev Each fallback delivery gets its own callback authorization. A failed unlock rolls back callback
    ///      consumption, so clear the authorization on both success and failure before trying the next recipient.
    function _tryDeliverAsset(Currency currency, address to, uint256 amount)
        internal
        override
        returns (bool delivered)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.UNWIND_WITH_FALLBACK));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency, to, amount);
        bytes memory data = abi.encode(actions, params);
        _authorizeUnwindCallback(keccak256(data));
        try poolManager.unlock{gas: DELIVERY_GAS_LIMIT}(data) {
            delivered = true;
        } catch {
            delivered = false;
        }
        _authorizeUnwindCallback(bytes32(0));
    }

    function _authorizeUnwindCallback(bytes32 callbackHash) private {
        bytes32 slot = UNWIND_CALLBACK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, callbackHash)
        }
    }

    function _authorizedUnwindCallback() private view returns (bytes32 callbackHash) {
        bytes32 slot = UNWIND_CALLBACK_SLOT;
        assembly ("memory-safe") {
            callbackHash := tload(slot)
        }
    }

    /// @dev Apply the NFT count delta after a successful mint or burn; failure reverts the whole action.
    function _updatePoolTickCount(PoolKey memory poolKey, int256 delta) private {
        if (!registry.updatePoolTickCount(poolKey, delta)) revert PoolTickCountUpdateFailed();
    }

    function _requireRegistryNotPaused() private view {
        if (registry.isPaused()) revert RegistryPaused();
    }

    /// @dev Rejects DELIST for ordinary LP actions. LIST and PAUSE proceed to the remaining checks.
    function _requirePoolNotDelisted(PoolKey memory key) private view {
        if (registry.getPoolLifeCycle(key) == PoolLifecycle.DELIST) revert PoolDelisted();
    }

    /// @dev Requires the account to hold LIQUIDITY_ALLOWED permission in the TSV Registry.
    function _requireLiquidityPermission(address account) private view {
        if (!registry.isAllowed(RegistryPermissionFlags.LIQUIDITY_ALLOWED, account)) revert Unauthorized();
    }

    function _getLpStatus(Currency currency, address lp) internal view returns (bool) {
        // address permissionsAdapter = Currency.unwrap(currency);
        // address permissionedToken = _verifiedPermissionedTokenOf(currency);
        // if (permissionedToken == address(0)) return false;
        // address statusQuoter = IPermissionsAdapter(permissionsAdapter).statusQuoter();
        // if (statusQuoter == address(0)) return false;
        // return IStatusQuoter(statusQuoter).isUnwindable(lp);
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return false;
        return IPermissionsAdapter(permissionsAdapter).isAllowed(lp, PermissionFlags.NONE);
    }

    /// @dev User-funded ERC20 payments use the same TokenApproveProxy chain as DexRouter.
    ///      Permissioned underlyings are paid to their adapter and wrapped; quotes are paid to PoolManager.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            if (payer == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                TOKEN_APPROVE_PROXY.claimTokens(Currency.unwrap(currency), payer, address(poolManager), amount);
            }
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        // Check liquidity permission for the actual user
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
        } else {
            TOKEN_APPROVE_PROXY.claimTokens(permissionedToken, payer, address(permissionsAdapter), amount);
        }
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControlUpgradeable)
        returns (bool)
    {
        return ERC721.supportsInterface(interfaceId) || AccessControlUpgradeable.supportsInterface(interfaceId);
    }
}
