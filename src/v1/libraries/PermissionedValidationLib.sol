// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionedCurrencyConfig, UnderlyingConfig, QuoteTokenConfig, AssetStatus} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC165} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {TSVSwapValidationLib} from "tsv-v1/libraries/TSVSwapValidationLib.sol";

interface IPermissionedRegistryViews {
    function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory);
    function getUnderlying(address u) external view returns (UnderlyingConfig memory);
    function getQuoteToken(address q) external view returns (QuoteTokenConfig memory);
    function isPermissionedOwnerApproved(address owner) external view returns (bool);
    function exitAdminOf(address w) external view returns (address);
    function exitAdminVersion(address w) external view returns (uint64);
}

interface IPermissionedComponentV1 {
    function poolManager() external view returns (address);
    function registry() external view returns (address);
    function PERMISSIONS_ADAPTER_FACTORY() external view returns (address);
    function router() external view returns (address);
    function lpManager() external view returns (address);
    function ledger() external view returns (address);
}

interface IERC20DecimalsV1 {
    function decimals() external view returns (uint8);
}

/// @notice Linked, stateless read-only checks; Registry/Router retain roles, state and fund movements.
/// @dev External library calls execute by delegatecall. address(this) is the calling Registry or Router proxy.
library PermissionedValidationLib {
    error InvalidConfig();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    struct Environment {
        address permissionsAdapterFactory;
        address permissionedPoolManager;
        address permissionedRouter;
        address hook;
        address lpManager;
        address dataInbox;
        address governanceAnchor;
        address participantSbt;
    }

    /// @notice Router reuses the approved stateless library for runtime policy snapshots.
    /// @dev Delegatecall address(this) is the Router here; Registry views use the explicit R parameter.
    function swapPlans(address registry, address pm, PoolKey memory key, address participant)
        external
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policyHash)
    {
        return TSVSwapValidationLib.plans(ITSVPermissionedRegistry(registry), pm, key, participant);
    }

    /// @notice First-admission W inventory only; unrelated PM U balances do not affect admission.
    /// @dev Reapproval deliberately does not invoke this check.
    function validateInitialInventory(address pm, address w, address u) external view {
        if (
            _staticWord(w, IERC20.totalSupply.selector, 0, 4) != 0
                || _staticWord(w, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                || _staticWord(u, IERC20.balanceOf.selector, uint160(w), 36) == 0
                || IPoolManager(pm).protocolFeesAccrued(Currency.wrap(w)) != 0
        ) revert InvalidPermissionedConfig();
    }

    function validateLegalShareAdapter(address adapter, address currency, uint32 version) external view {
        _validateLegalShareAdapter(adapter, currency, version);
    }

    function candidateUnderlying(Environment memory e, address w) external view returns (address) {
        return _candidateUnderlying(e, w);
    }

    function validateAssetIdentities(Environment memory e, address w, address u) external view {
        _validateAssetIdentities(e, w, u);
    }

    function readDecimals(address token) external view returns (uint8) {
        return _readDecimals(token);
    }

    function stockDecimals(address w, address u) external view returns (uint8) {
        return _stockDecimals(w, u);
    }

    function validateOwner(address w, address u, address owner) external view {
        _validateOwner(w, u, owner);
    }

    function validateExitAdmin(Environment memory e, address w, address u, address admin, address expectedOwner)
        external
        view
    {
        _validateExitAdmin(e, w, u, admin, expectedOwner);
    }

    function validatePolicy(Environment memory e, address w, address u, address owner) external view {
        _validatePolicy(e, w, u, owner);
    }

    function validateQuoteIdentity(Environment memory e, address quote) external view {
        _validateQuoteIdentity(e, quote);
    }

    function validateEnvironment(Environment memory e, address factory, address router_)
        external
        view
        returns (address pm)
    {
        if (
            e.hook == address(0) || e.lpManager == address(0) || e.dataInbox == address(0) || factory.code.length == 0
                || router_.code.length == 0 || _isSystem(e, factory) || _isSystem(e, router_) || factory == router_
        ) revert InvalidPermissionedConfig();
        pm = _readAddress(factory, IPermissionsAdapterFactory.POOL_MANAGER.selector);
        if (
            pm.code.length == 0 || _isSystem(e, pm) || pm == factory || pm == router_
                || _readAddress(router_, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(e.hook, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(e.lpManager, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(router_, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(e.hook, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(e.lpManager, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(router_, IPermissionedComponentV1.PERMISSIONS_ADAPTER_FACTORY.selector) != address(this)
                || _readAddress(e.hook, IPermissionedComponentV1.router.selector) != router_
                || _readAddress(e.hook, IPermissionedComponentV1.lpManager.selector) != e.lpManager
        ) revert InvalidPermissionedConfig();
    }

    function _validateLegalShareAdapter(address adapter, address currency, uint32 version) private view {
        if (adapter.code.length == 0) revert InvalidConfig();
        (bool ok, bytes memory result) = adapter.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IDirectLegalShareAdapter).interfaceId)
        );
        uint256 supported;
        if (result.length >= 32) assembly ("memory-safe") { supported := mload(add(result, 32)) }
        if (
            !ok || supported != 1 || _readAddress(adapter, IDirectLegalShareAdapter.poolCurrency.selector) != currency
                || _staticWord(adapter, IDirectLegalShareAdapter.adapterVersion.selector, 0, 4) != version
        ) revert InvalidConfig();
    }

    /// @dev Shared strict getter decoding avoids duplicating external-call code at every policy check.
    function _staticWord(address target, bytes4 selector, uint256 argument, uint256 inputLength)
        private
        view
        returns (uint256 value)
    {
        bytes4 invalidSelector = InvalidPermissionedConfig.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), argument)
            let ok := staticcall(gas(), target, ptr, inputLength, 0, 32)
            if iszero(ok) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 32) {
                mstore(0, invalidSelector)
                revert(0, 4)
            }
            value := mload(0)
        }
    }

    function _readAddress(address target, bytes4 selector) private view returns (address) {
        uint256 value = _staticWord(target, selector, 0, 4);
        if (value > type(uint160).max) revert InvalidPermissionedConfig();
        return address(uint160(value));
    }

    function _readAddressArgument(address target, bytes4 selector, address argument) private view returns (address) {
        uint256 value = _staticWord(target, selector, uint160(argument), 36);
        if (value > type(uint160).max) revert InvalidPermissionedConfig();
        return address(uint160(value));
    }

    function _readBool(address target, bytes4 selector, address argument) private view returns (bool) {
        uint256 value = _staticWord(target, selector, uint160(argument), 36);
        if (value > 1) revert InvalidPermissionedConfig();
        return value == 1;
    }

    function _candidateUnderlying(Environment memory e, address w) private view returns (address u) {
        u = _readAddressArgument(
            e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, w
        );
        if (
            u == address(0)
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.verifiedPermissionsAdapterOf.selector, w
                    ) != u
        ) revert UnverifiedPermissionedAdapter(w);
        if (
            w.code.length == 0
                || _readAddress(w, IPermissionsAdapter.POOL_MANAGER.selector) != e.permissionedPoolManager
                || _readAddress(w, IPermissionsAdapter.PERMISSIONED_TOKEN.selector) != u
                || _readAddress(w, IPermissionsAdapter.allowListChecker.selector) != address(this)
        ) revert InvalidPermissionedConfig();
    }

    function _isSystem(Environment memory e, address a) private view returns (bool) {
        return a == address(this) || a == e.permissionedPoolManager || a == e.permissionsAdapterFactory
            || a == e.permissionedRouter || a == e.hook || a == e.lpManager || a == e.dataInbox
            || a == e.governanceAnchor || a == e.participantSbt
            || (e.hook != address(0) && a == _readAddress(e.hook, IPermissionedComponentV1.ledger.selector));
    }

    function _validateAssetIdentities(Environment memory e, address w, address u) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            u.code.length == 0 || w == u || _isSystem(e, w) || _isSystem(e, u)
                || r.getQuoteToken(w).status != AssetStatus.ABSENT || r.getQuoteToken(u).status != AssetStatus.ABSENT
                || r.getUnderlying(w).securityId != 0 || r.getCurrency(u).underlying != address(0)
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, u
                    ) != address(0)
        ) revert InvalidPermissionedConfig();
    }

    function _readDecimals(address token) private view returns (uint8 decimals) {
        try IERC20DecimalsV1(token).decimals() returns (uint8 value) {
            decimals = value;
        } catch {
            revert PermissionedMetadataMismatch();
        }
        if (decimals > 18) revert PermissionedMetadataMismatch();
    }

    function _stockDecimals(address w, address u) private view returns (uint8 decimals) {
        decimals = _readDecimals(u);
        if (_readDecimals(w) != decimals) revert PermissionedMetadataMismatch();
    }

    function _validateOwner(address w, address u, address owner) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            owner.code.length == 0 || !r.isPermissionedOwnerApproved(owner) || owner == w || owner == u
                || owner == r.exitAdminOf(w) || _readAddress(w, IPermissionsAdapter.owner.selector) != owner
        ) revert PermissionedPolicyMismatch();
    }

    function _validateExitAdmin(Environment memory e, address w, address u, address admin, address expectedOwner)
        private
        view
    {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            admin.code.length == 0 || admin == u || admin == w || _isSystem(e, admin)
                || r.getCurrency(admin).underlying != address(0) || r.getUnderlying(admin).securityId != 0
                || r.getQuoteToken(admin).status != AssetStatus.ABSENT
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, admin
                    ) != address(0) || admin == expectedOwner
                || admin == _readAddress(w, IPermissionsAdapter.owner.selector)
        ) revert PermissionedPolicyMismatch();
    }

    function _validatePolicy(Environment memory e, address w, address u, address owner) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        _validateOwner(w, u, owner);
        if (
            !_readBool(w, IPermissionsAdapter.allowedWrappers.selector, e.permissionedRouter)
                || !_readBool(w, IPermissionsAdapter.allowedHooks.selector, e.hook) || r.exitAdminVersion(w) == 0
        ) revert PermissionedPolicyMismatch();
        _validateExitAdmin(e, w, u, r.exitAdminOf(w), owner);
    }

    function _validateQuoteIdentity(Environment memory e, address quote) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            quote.code.length == 0 || _isSystem(e, quote) || r.getCurrency(quote).underlying != address(0)
                || r.getUnderlying(quote).securityId != 0
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, quote
                    ) != address(0)
        ) revert UnsupportedAsset(quote);
    }
}
