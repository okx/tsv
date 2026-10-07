// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {
    AssetStatus,
    PoolStatus,
    PoolConfig,
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig
} from "tsv-v1/types/TSVTypes.sol";
import {SettlementAssetKind, SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Internal-only runtime policy derivation. No storage, role changes or asset transfers.
library TSVSwapValidationLib {
    using PoolIdLibrary for PoolKey;

    error InvalidPool();
    error Unauthorized();
    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    function plans(ITSVPermissionedRegistry r, address pm, PoolKey memory key, address participant)
        internal
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policyHash)
    {
        address f = r.permissionsAdapterFactory();
        if (f == address(0)) revert PermissionedEnvironmentNotBound();
        if (
            r.permissionedPoolManager() != pm || r.POOL_MANAGER() != pm || r.permissionedRouter() != address(this)
                || r.permissionedAllowlistChecker() != address(r)
        ) revert InvalidPermissionedConfig();
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory pool = r.getPool(id);
        if (
            pool.status != PoolStatus.ACTIVE || !r.isTradable(id) || address(key.hooks) != r.hook()
                || keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))
        ) revert InvalidPool();
        p0 = _leg(r, pm, f, Currency.unwrap(key.currency0), pool.securityId0, participant);
        p1 = _leg(r, pm, f, Currency.unwrap(key.currency1), pool.securityId1, participant);
        if (p0.kind == p1.kind) revert InvalidPool();
        policyHash = keccak256(
            abi.encode(
                address(r),
                f,
                pm,
                address(this),
                r.hook(),
                r.lpManager(),
                r.dataInbox(),
                address(r.governanceAnchor()),
                address(r.participantSbt()),
                r.sbtTokenId(),
                pool.version,
                r.getSecurity(pool.securityId0).version,
                r.getSecurity(pool.securityId1).version,
                r.marketSequence(pool.securityId0),
                r.marketSequence(pool.securityId1),
                p0,
                p1
            )
        );
    }

    function _leg(ITSVPermissionedRegistry r, address pm, address f, address c, bytes32 securityId, address participant)
        private
        view
        returns (SettlementLegPlan memory p)
    {
        PermissionedCurrencyConfig memory w = r.getCurrency(c);
        p.currency = c;
        if (w.underlying == address(0)) {
            QuoteTokenConfig memory q = r.getQuoteToken(c);
            if (
                c.code.length == 0 || q.status != AssetStatus.APPROVED || securityId != 0
                    || r.getUnderlying(c).securityId != 0 || _system(r, pm, f, c)
                    || IPermissionsAdapterFactory(f).permissionsAdapterOf(c) != address(0)
            ) revert UnsupportedAsset(c);
            if (_decimals(c) != q.rawDecimals) revert PermissionedMetadataMismatch();
            p.kind = SettlementAssetKind.QUOTE_ERC20;
            p.rawDecimals = q.rawDecimals;
            p.configVersion = q.configVersion;
            return p;
        }
        UnderlyingConfig memory u = r.getUnderlying(w.underlying);
        if (w.status != AssetStatus.APPROVED || securityId == 0 || u.securityId != securityId) revert InvalidPool();
        IPermissionsAdapter adapter = IPermissionsAdapter(c);
        if (
            IPermissionsAdapterFactory(f).permissionsAdapterOf(c) != w.underlying
                || IPermissionsAdapterFactory(f).verifiedPermissionsAdapterOf(c) != w.underlying
        ) revert UnverifiedPermissionedAdapter(c);
        if (
            c.code.length == 0 || w.underlying.code.length == 0 || c == w.underlying || adapter.POOL_MANAGER() != pm
                || address(adapter.PERMISSIONED_TOKEN()) != w.underlying
                || address(adapter.allowListChecker()) != address(r) || _system(r, pm, f, c)
                || _system(r, pm, f, w.underlying) || r.getQuoteToken(c).status != AssetStatus.ABSENT
                || r.getQuoteToken(w.underlying).status != AssetStatus.ABSENT
                || r.getCurrency(w.underlying).underlying != address(0)
                || IPermissionsAdapterFactory(f).permissionsAdapterOf(w.underlying) != address(0)
        ) revert InvalidPermissionedConfig();
        if (_decimals(c) != u.rawDecimals || _decimals(w.underlying) != u.rawDecimals) {
            revert PermissionedMetadataMismatch();
        }
        if (
            u.legalShareAdapter.code.length == 0 || u.legalAdapterVersion == 0
                || !IERC165(u.legalShareAdapter).supportsInterface(type(IDirectLegalShareAdapter).interfaceId)
                || IDirectLegalShareAdapter(u.legalShareAdapter).poolCurrency() != w.underlying
                || IDirectLegalShareAdapter(u.legalShareAdapter).adapterVersion() != u.legalAdapterVersion
        ) revert InvalidPermissionedConfig();
        address exitAdmin = r.exitAdminOf(c);
        uint64 exitVersion = r.exitAdminVersion(c);
        if (
            w.expectedOwner.code.length == 0 || adapter.owner() != w.expectedOwner
                || !r.isPermissionedOwnerApproved(w.expectedOwner) || !adapter.allowedWrappers(address(this))
                || !adapter.allowedHooks(IHooks(r.hook())) || !adapter.swappingEnabled() || exitVersion == 0
                || exitAdmin.code.length == 0 || exitAdmin == w.expectedOwner || exitAdmin == c
                || exitAdmin == w.underlying || _system(r, pm, f, exitAdmin)
                || r.getCurrency(exitAdmin).underlying != address(0) || r.getUnderlying(exitAdmin).securityId != 0
                || r.getQuoteToken(exitAdmin).status != AssetStatus.ABSENT
                || IPermissionsAdapterFactory(f).permissionsAdapterOf(exitAdmin) != address(0)
        ) revert PermissionedPolicyMismatch();
        if (!adapter.isAllowed(participant, PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
        p.kind = SettlementAssetKind.PERMISSIONED_STOCK;
        p.underlying = w.underlying;
        p.rawDecimals = u.rawDecimals;
        p.expectedOwner = w.expectedOwner;
        p.configVersion = w.configVersion;
        p.securityId = u.securityId;
        p.legalShareAdapter = u.legalShareAdapter;
        p.legalAdapterVersion = u.legalAdapterVersion;
        p.exitAdmin = exitAdmin;
        p.exitAdminVersion = exitVersion;
    }

    function _system(ITSVPermissionedRegistry r, address pm, address f, address a) private view returns (bool) {
        return a == address(r) || a == pm || a == f || a == address(this) || a == r.hook() || a == r.lpManager()
            || a == r.dataInbox() || a == address(r.governanceAnchor()) || a == address(r.participantSbt())
            || a == ISwapHookViews(r.hook()).ledger();
    }

    function _decimals(address token) private view returns (uint8 value) {
        try IERC20Metadata(token).decimals() returns (uint8 actual) {
            value = actual;
        } catch {
            revert PermissionedMetadataMismatch();
        }
        if (value > 18) revert PermissionedMetadataMismatch();
    }
}

interface ISwapHookViews {
    function ledger() external view returns (address);
}
