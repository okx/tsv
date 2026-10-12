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
import {TSVLPManagerLib} from "../libraries/TSVLPManagerLib.sol";
import {IStatusQuoter} from "../interfaces/IStatusQuoter.sol";
import {ITSVPermissionedRegistry} from "../interfaces/ITSVPermissionedRegistry.sol";
import {PoolLifecycle} from "../types/TSVTypes.sol";
import {ITokenApproveProxy} from "../interfaces/ITokenApproveProxy.sol";
import {CalldataDecoder} from "v4-periphery/libraries/CalldataDecoder.sol";
import {ERC721Permit_v4} from "../vendor/permissionedPools/base/ERC721Permit_v4.sol";
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
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract TSVLPManagerV1 is Initializable, UUPSUpgradeable, PermissionedPositionManager {
    using CalldataDecoder for bytes;

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error UnauthorizedUpgrade();
    error LpUnWindable();
    error InvalidRegistry();
    error PoolDelisted();
    error RegistryPaused();
    error PoolTickCountUpdateFailed();
    error IncompatibleImplementation();
    error InvalidApproveProxy();
    error WithdrawClaimForbidden();

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant FORCE_EXIT_ADMIN_ROLE = keccak256("FORCE_EXIT_ADMIN_ROLE");
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    /// @dev Action bitset for authorized exit callbacks; BURN_POSITION has separate NFT accounting below.
    uint256 private constant EXIT_SETTLEMENT_ACTIONS = (uint256(1) << Actions.TAKE_PAIR)
        | (uint256(1) << Actions.MINT_6909) | (uint256(1) << Actions.UNWIND_WITH_FALLBACK);

    /// @notice Shared approval proxy; users approve its TokenApprove, not this LP Manager.
    ITokenApproveProxy public immutable TOKEN_APPROVE_PROXY;

    ITSVPermissionedRegistry public registry;

    uint256[48] private __gap;

    modifier onlyRole(bytes32 role) {
        TSVLPManagerLib.requireRole(registry, role);
        _;
    }

    modifier whenRegistryNotPaused() {
        _requireRegistryNotPaused();
        _;
    }

    /// @dev Fixed integration parameters belong to the implementation. Upgrades must preserve them.
    ///      Initialization is disabled on the implementation itself.
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
    {
        if (address(_registry).code.length == 0) revert InvalidRegistry();
        if (address(_tokenApproveProxy).code.length == 0) revert InvalidApproveProxy();
        if (_tokenApproveProxy.tokenApprove().code.length == 0) revert InvalidApproveProxy();
        TOKEN_APPROVE_PROXY = _tokenApproveProxy;
        registry = _registry;
        _disableInitializers();
    }

    /// @notice Initializes proxy Registry and ERC-721 state exactly once.
    /// @dev Supply this call as the ERC-1967 proxy's constructor initialization data.
    function initialize(ITSVPermissionedRegistry _registry) external initializer {
        if (address(_registry).code.length == 0) revert InvalidRegistry();
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
        return TSVLPManagerLib.initializePool(poolManager, PERMISSIONS_ADAPTER_FACTORY, registry, key, sqrtPriceX96);
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
        TSVLPManagerLib.unwindPositionByOkx(
            TSVLPManagerLib.UnwindParams(
                poolManager,
                PERMISSIONS_ADAPTER_FACTORY,
                DELIVERY_GAS_LIMIT,
                unsubscribeGasLimit,
                poolKey,
                tokenId,
                lp,
                amount0Min,
                amount1Min,
                hookData
            ),
            positionInfo,
            subscriber,
            getApproved
        );
    }

    function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        public
        override
        whenRegistryNotPaused
        isNotLocked
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        TSVLPManagerLib.requireUnwindAdmin(PERMISSIONS_ADAPTER_FACTORY, poolKey.currency0, poolKey.currency1);

        address lp = ownerOf(tokenId);
        TSVLPManagerLib.unwindPosition(
            TSVLPManagerLib.UnwindParams(
                poolManager,
                PERMISSIONS_ADAPTER_FACTORY,
                DELIVERY_GAS_LIMIT,
                unsubscribeGasLimit,
                poolKey,
                tokenId,
                lp,
                amount0Min,
                amount1Min,
                hookData
            ),
            positionInfo,
            subscriber,
            getApproved
        );
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

    /// @notice Disables the inherited claim-withdrawal entry point.
    function withdrawClaim(Currency, uint256, address) public override whenRegistryNotPaused isNotLocked {
        revert WithdrawClaimForbidden();
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

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        whenRegistryNotPaused
    {
        UUPSUpgradeable.upgradeToAndCall(newImplementation, data);
    }

    /// @dev Registry's upgrade admins may upgrade this proxy.
    function _authorizeUpgrade(address) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
    }

    /// @dev Normal callbacks retain the upstream action ABI. An unwind callback must match the exact data
    ///      committed by an authorized entry point, and its authorization is consumed before executing actions.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory result) {
        bytes32 expected = TSVLPManagerLib.authorizedCallbackHash();
        if (expected == bytes32(0)) return BaseActionsRouter._unlockCallback(data);
        if (keccak256(data) != expected) revert Unauthorized();

        TSVLPManagerLib.authorizeCallback(bytes32(0));
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        if (actions.length != params.length) revert InputLengthMismatch();
        for (uint256 i; i < actions.length; ++i) {
            uint256 action = uint8(actions[i]);
            bytes calldata actionParams = params[i];
            if (action == Actions.BURN_POSITION) {
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    actionParams.decodeBurnParams();
                (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
                // The committed hash is already consumed; mark only this burn as an active unwind.
                TSVLPManagerLib.authorizeCallback(bytes32(uint256(1)));
                _burn(tokenId, amount0Min, amount1Min, hookData);
                TSVLPManagerLib.authorizeCallback(bytes32(0));
                _updatePoolTickCount(poolKey, -1);
            } else if ((EXIT_SETTLEMENT_ACTIONS & (uint256(1) << action)) != 0) {
                PermissionedPositionManager._handleAction(action, actionParams);
            } else {
                revert UnsupportedAction(action);
            }
        }
    }

    /// @notice True only while an authorized unwind burns its position, for the Hook's LP admission bypass.
    function isUnwindActive() external view returns (bool) {
        return TSVLPManagerLib.authorizedCallbackHash() == bytes32(uint256(1));
    }

    /// @dev Only ordinary actions reach this dispatcher; forced exits execute through their authorized callback.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (
            action == Actions.MINT_POSITION || action == Actions.INCREASE_LIQUIDITY
                || action == Actions.DECREASE_LIQUIDITY || action == Actions.BURN_POSITION
        ) {
            _handlePositionAction(action, params);
            return;
        }
        _handleSettlementAction(action, params);
    }

    /// @dev Position actions check both executor and owner, then lifecycle, before execution and NFT accounting.
    function _handlePositionAction(uint256 action, bytes calldata params) private {
        PoolKey memory poolKey = TSVLPManagerLib.checkPositionAction(
            registry, action, params, msgSender(), _ownerOf, positionInfo, poolKeys
        );
        PermissionedPositionManager._handleAction(action, params);
        if (action == Actions.MINT_POSITION) {
            _updatePoolTickCount(poolKey, 1);
        } else if (action == Actions.BURN_POSITION) {
            _updatePoolTickCount(poolKey, -1);
        }
    }

    /// @dev Explicit recipients are checked after resolving sentinels. CLOSE_CURRENCY and CLEAR_OR_TAKE
    ///      always pay the already checked executor.
    function _handleSettlementAction(uint256 action, bytes calldata params) private {
        TSVLPManagerLib.checkSettlementAction(registry, action, params, msgSender());
        PermissionedPositionManager._handleAction(action, params);
    }

    function _tryDeliverAsset(Currency currency, address to, uint256 amount) internal override returns (bool) {
        return TSVLPManagerLib.tryDeliverAsset(poolManager, DELIVERY_GAS_LIMIT, currency, to, amount);
    }

    /// @dev Apply the NFT count delta after a successful mint or burn; failure reverts the whole action.
    function _updatePoolTickCount(PoolKey memory poolKey, int256 delta) private {
        TSVLPManagerLib.updatePoolTickCount(registry, poolKey, delta);
    }

    function _requireRegistryNotPaused() private view {
        TSVLPManagerLib.requireRegistryNotPaused(registry);
    }

    /// @dev Delegatecall preserves the manager as payer/caller and the original action executor.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        TSVLPManagerLib.pay(
            poolManager, PERMISSIONS_ADAPTER_FACTORY, TOKEN_APPROVE_PROXY, currency, payer, amount, msgSender()
        );
    }

    function _validateLiquidityCurrency(Currency currency, IHooks hooks, address owner)
        internal
        view
        override
        returns (bool)
    {
        return TSVLPManagerLib.validateLiquidityCurrency(PERMISSIONS_ADAPTER_FACTORY, currency, hooks, owner);
    }

    function _sweep(Currency currency, address to) internal override {
        TSVLPManagerLib.sweep(PERMISSIONS_ADAPTER_FACTORY, currency, to);
    }
}
