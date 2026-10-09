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
import {ITokenApproveProxy} from "../interfaces/ITokenApproveProxy.sol";
import {CalldataDecoder} from "v4-periphery/libraries/CalldataDecoder.sol";
import {
    PermissionFlags as RegistryPermissionFlags
} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {ERC721} from "../vendor/permissionedPools/base/ERC721Permit_v4.sol";
import {PoolInitializer_v4} from "../vendor/permissionedPools/base/PoolInitializer_v4.sol";
import {IPoolInitializer_v4} from "v4-periphery/interfaces/IPoolInitializer_v4.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract TSVLPManagerV1 is PermissionedPositionManager, TSVGoverned {
    using CalldataDecoder for bytes;

    error LpUnWindable();
    error InvalidRegistry();
    error IncompatibleImplementation();
    error InvalidApproveProxy();

    /// @notice Shared approval proxy; users approve its TokenApprove, not this LP Manager.
    ITokenApproveProxy public immutable TOKEN_APPROVE_PROXY;

    ITSVPermissionedRegistry public registry;

    // Nonzero only during the burn, claim settlement and delivery of an authorized unwind.
    uint256 private forcedUnwindTokenId;

    uint256[48] private __gap;

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
        external
        payable
        override(PoolInitializer_v4, IPoolInitializer_v4)
        onlyRole(POOL_CREATOR_ROLE)
        isNotLocked
        returns (int24 tick)
    {
        registry.registerPool(key);
        return poolManager.initialize(key, sqrtPriceX96);
    }

    function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        override
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
        forcedUnwindTokenId = tokenId;
        poolManager.unlock(abi.encode(actions, params));

        // Reads the full 6909 balance, not a burn delta: the burn output plus any stray MINT_6909 claims
        // parked in this contract.
        uint256 amount0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // Deliver the real asset to the LP, then the admin; on any grief, hand over the 6909 claim instead.
        _deliverCurrency(poolKey.currency0, lp, tokenId, amount0);
        _deliverCurrency(poolKey.currency1, lp, tokenId, amount1);
        forcedUnwindTokenId = 0;
    }

    /// @dev Ordinary actions require an eligible executor; LP actions also check the owner,
    ///      and outward transfers check the resolved recipient. Only the fixed unwind flow is exempt.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (forcedUnwindTokenId != 0) {
            if (action == Actions.BURN_POSITION) {
                if (abi.decode(params, (uint256)) != forcedUnwindTokenId) revert Unauthorized();
            } else if (action != Actions.MINT_6909 && action != Actions.UNWIND_WITH_FALLBACK) {
                revert Unauthorized();
            }
            super._handleAction(action, params);
            return;
        }

        _requireLpAllowed(msgSender());
        // This primitive spends this contract's claims and is reserved for authorized forced delivery.
        if (action == Actions.UNWIND_WITH_FALLBACK) revert Unauthorized();

        address owner;
        if (action == Actions.MINT_POSITION) {
            (,,,,,, address recipient,) = params.decodeMintParams();
            owner = _mapRecipient(recipient);
        } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
            (,,,,, address recipient,) = params.decodeMintFromDeltasParams();
            owner = _mapRecipient(recipient);
        } else if (
            action == Actions.INCREASE_LIQUIDITY || action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS
                || action == Actions.DECREASE_LIQUIDITY || action == Actions.BURN_POSITION
        ) {
            uint256 tokenId = abi.decode(params, (uint256));
            owner = ownerOf(tokenId);
        } else {
            if (action == Actions.TAKE_PAIR) {
                (,, address recipient) = params.decodeCurrencyPairAndAddress();
                _requireLpAllowed(_mapRecipient(recipient));
            } else if (action == Actions.TAKE) {
                (, address recipient,) = params.decodeCurrencyAddressAndUint256();
                _requireLpAllowed(_mapRecipient(recipient));
            } else if (action == Actions.SWEEP) {
                (, address recipient) = params.decodeCurrencyAndAddress();
                _requireLpAllowed(_mapRecipient(recipient));
            }
            super._handleAction(action, params);
            return;
        }
        _requireLpAllowed(owner);
        super._handleAction(action, params);
    }

    function _requireLpAllowed(address account) private view {
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
