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
import {
    PermissionFlags as RegistryPermissionFlags
} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {ERC721} from "../vendor/permissionedPools/base/ERC721Permit_v4.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract TSVLPManagerV1 is PermissionedPositionManager, TSVGoverned {
    error LpUnWindable();
    error InvalidRegistry();
    error IncompatibleImplementation();

    ITSVPermissionedRegistry public registry;

    uint256[49] private __gap;

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
        ITSVPermissionedRegistry _registry
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
        if (address(registry_).code.length == 0) revert InvalidRegistry();
        registry = _registry;
        _disableInitializers();
    }

    /// @notice Initializes proxy governance, Registry and ERC-721 state exactly once.
    /// @dev Supply this call as the ERC-1967 proxy's constructor initialization data.
    function initialize(address anchor, ITSVPermissionedRegistry registry_) external initializer {
        if (address(registry_).code.length == 0) revert InvalidRegistry();
        __TSVGoverned_init(anchor);
        registry = registry_;
        nextTokenId = 1;
        // The EIP712 signing name remains "Uniswap v4 Positions NFT" for upstream compatibility.
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
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
        poolManager.unlock(abi.encode(actions, params));

        // Reads the full 6909 balance, not a burn delta: the burn output plus any stray MINT_6909 claims
        // parked in this contract.
        uint256 amount0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // Deliver the real asset to the LP, then the admin; on any grief, hand over the 6909 claim instead.
        _deliverCurrency(poolKey.currency0, lp, tokenId, amount0);
        _deliverCurrency(poolKey.currency1, lp, tokenId, amount1);
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

    /// @notice Validate `currency` for a liquidity-adding action and report whether it is a verified adapter.
    /// @dev Ordinary tokens pass. A factory-created adapter must be verified — otherwise it would be treated as
    ///      ordinary here, skip its hook/`LIQUIDITY_ALLOWED` checks, and be activated later via verification. A
    ///      verified adapter must allow `hooks` and clear the owner's `LIQUIDITY_ALLOWED`.
    function _validateLiquidityCurrency(Currency currency, IHooks hooks, address owner)
        internal
        view
        override
        returns (bool isVerifiedAdapter)
    {
        address currencyAddress = Currency.unwrap(currency);
        if (_verifiedPermissionedTokenOf(currency) == address(0)) {
            if (PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currencyAddress) != address(0)) {
                revert NoVerifiedAdapter();
            }
            // a non-adapter currency must be a real contract (native ETH excepted)
            if (currencyAddress != address(0) && currencyAddress.code.length == 0) revert NonContractCurrency();
            return false;
        }
        IPermissionsAdapter adapter = IPermissionsAdapter(currencyAddress);
        if (!registry.isAllowed(RegistryPermissionFlags.LIQUIDITY_ALLOWED, owner)) revert Unauthorized();
        if (!adapter.allowedHooks(hooks)) revert InvalidHook();
        if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();
        return true;
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
