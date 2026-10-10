// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {UnderlyingRecord, QuoteTokenRecord} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IAllowlistChecker, IERC165} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";

interface IPermissionedRegistryViews {
    function permissionsAdapterFactory() external view returns (address);
    function permissionedPoolManager() external view returns (address);
    function hook() external view returns (address);
    function lpManager() external view returns (address);
    function dataInbox() external view returns (address);
    function participantSbt() external view returns (address);
    function getCurrencyUnderlying(address w) external view returns (address);
    function getUnderlying(address u) external view returns (UnderlyingRecord memory);
    function getQuoteToken(address q) external view returns (QuoteTokenRecord memory);
}

interface IPermissionedComponentV1 {
    function router() external view returns (address);
    function ledger() external view returns (address);
}

interface IERC20DecimalsV1 {
    function decimals() external view returns (uint8);
}

/// @notice Linked, stateless admission checks; Registry retains roles, state and fund movements.
/// @dev External library calls execute by delegatecall. address(this) is the calling Registry proxy.
library PermissionedValidationLib {
    error InvalidConfig();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    /// @notice First-admission W inventory only; unrelated PM U balances do not affect admission.
    /// @dev Recovery from a pause deliberately does not invoke this check.
    function validateInitialInventory(address pm, address w, address u) external view {
        if (
            _staticWord(w, IERC20.totalSupply.selector, 0, 4) != 0
                || _staticWord(w, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                || _staticWord(u, IERC20.balanceOf.selector, uint160(w), 36) == 0
                || IPoolManager(pm).protocolFeesAccrued(Currency.wrap(w)) != 0
        ) revert InvalidPermissionedConfig();
    }

    function validateLegalShareAdapter(address adapter, address currency) external view {
        _validateLegalShareAdapter(adapter, currency);
    }

    function candidateUnderlying(address w) external view returns (address) {
        return _candidateUnderlying(w);
    }

    function readDecimals(address token) external view returns (uint8) {
        return _readDecimals(token);
    }

    function stockDecimals(address w, address u) external view returns (uint8) {
        return _stockDecimals(w, u);
    }

    function validatePolicy(address w, address) external view {
        _validatePolicy(w);
    }

    function validateQuoteIdentity(address quote) external view {
        _validateQuoteIdentity(quote);
    }

    function _validateLegalShareAdapter(address adapter, address currency) private view {
        if (adapter.code.length == 0) revert InvalidConfig();
        (bool ok, bytes memory result) = adapter.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IDirectLegalShareAdapter).interfaceId)
        );
        uint256 supported;
        if (result.length >= 32) assembly ("memory-safe") { supported := mload(add(result, 32)) }
        if (!ok || supported != 1 || _readAddress(adapter, IDirectLegalShareAdapter.poolCurrency.selector) != currency) revert InvalidConfig();
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

    function _candidateUnderlying(address w) private view returns (address u) {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        u = _readAddressArgument(
            r.permissionsAdapterFactory(), IPermissionsAdapterFactory.permissionsAdapterOf.selector, w
        );
        if (
            u == address(0)
                || _readAddressArgument(
                        r.permissionsAdapterFactory(),
                        IPermissionsAdapterFactory.verifiedPermissionsAdapterOf.selector,
                        w
                    ) != u
        ) revert UnverifiedPermissionedAdapter(w);
        if (
            w.code.length == 0
                || _readAddress(w, IPermissionsAdapter.POOL_MANAGER.selector) != r.permissionedPoolManager()
                || _readAddress(w, IPermissionsAdapter.PERMISSIONED_TOKEN.selector) != u
        ) revert InvalidPermissionedConfig();
        address checker = _readAddress(w, IPermissionsAdapter.allowListChecker.selector);
        if (checker.code.length == 0 || !IERC165(checker).supportsInterface(type(IAllowlistChecker).interfaceId)) {
            revert InvalidPermissionedConfig();
        }
        _validateAssetIdentities(w, u);
    }

    function _isSystem(address a) private view returns (bool) {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        return a == address(this) || a == r.permissionedPoolManager() || a == r.permissionsAdapterFactory()
            || a == _readAddress(r.hook(), IPermissionedComponentV1.router.selector) || a == r.hook()
            || a == r.lpManager() || a == r.dataInbox() || a == r.participantSbt()
            || a == _readAddress(r.hook(), IPermissionedComponentV1.ledger.selector);
    }

    function _validateAssetIdentities(address w, address u) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            u.code.length == 0 || w == u || _isSystem(w) || _isSystem(u) || r.getQuoteToken(w).registered
                || r.getQuoteToken(u).registered || r.getUnderlying(w).securityId != 0
                || r.getCurrencyUnderlying(u) != address(0)
                || _readAddressArgument(
                        r.permissionsAdapterFactory(), IPermissionsAdapterFactory.permissionsAdapterOf.selector, u
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

    function _validatePolicy(address w) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            !_readBool(
                    w,
                    IPermissionsAdapter.allowedWrappers.selector,
                    _readAddress(r.hook(), IPermissionedComponentV1.router.selector)
                ) || !_readBool(w, IPermissionsAdapter.allowedHooks.selector, r.hook())
        ) revert PermissionedPolicyMismatch();
    }

    function _validateQuoteIdentity(address quote) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            quote.code.length == 0 || _isSystem(quote) || r.getCurrencyUnderlying(quote) != address(0)
                || r.getUnderlying(quote).securityId != 0
                || _readAddressArgument(
                        r.permissionsAdapterFactory(), IPermissionsAdapterFactory.permissionsAdapterOf.selector, quote
                    ) != address(0)
        ) revert UnsupportedAsset(quote);
    }
}
