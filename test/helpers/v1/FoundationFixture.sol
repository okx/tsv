// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/PoolManager.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {
    IERC20 as PermissionedIERC20,
    IHooks as AdapterHooks
} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {V1PermissionedComponent, V1ConfigReceiver, V1IssuerAllowlistChecker} from "./PermissionedMocks.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PermissionedRegisterParam, SecurityPauseMode, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "./MockIssuerTokens.sol";
import {V1MockToken} from "./FoundationMocks.sol";
import {OperationsSbt} from "./OperationsMocks.sol";

/// @dev FoundationFixture scenarios; inherited fixtures contain no test functions.
abstract contract FoundationFixture is Test {
    bytes32 internal constant SECURITY = keccak256("SEC_A");
    uint256 internal constant DAY = (uint256(1_790_827_201) - 5 hours) / 1 days;

    address internal guardian;
    address internal council;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    V1MockIssuerShares internal stockUnderlying;
    V1MockIssuerWrapped internal stockToken;
    PermissionsAdapter internal stock;
    PoolManager internal manager;
    PermissionsAdapterFactory internal permissionsFactory;
    V1PermissionedComponent internal permissionedRouterFixture;
    V1ConfigReceiver internal exitReceiver;
    V1IssuerAllowlistChecker internal issuerChecker;
    OperationsSbt internal identitySbt;
    V1MockToken internal quote;
    ERC8056DirectLegalShareAdapter internal stockAdapter;
    PoolKey internal key;
    bytes32 internal poolId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public virtual {
        vm.warp(1_790_827_201);
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        registry = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()), abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry)))
                )
            )
        );
        manager = new PoolManager(address(this));
        permissionsFactory = new PermissionsAdapterFactory(address(manager));
        identitySbt = new OperationsSbt();
        permissionedRouterFixture =
            new V1PermissionedComponent(address(manager), address(registry), address(permissionsFactory));
        registry.bindComponents(address(this), address(this), address(permissionsFactory), address(identitySbt));
        exitReceiver = new V1ConfigReceiver();
        issuerChecker = new V1IssuerAllowlistChecker();
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        registry.grantRole(registry.HALT_REPORTER_ROLE(), address(this));
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 10, bytes32("TEST"));

        stockUnderlying = new V1MockIssuerShares();
        stockToken = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1MockToken("QUOTE6", 6);
        stockAdapter = new ERC8056DirectLegalShareAdapter(address(stockToken));
        PermissionedRegisterParam memory admission =
            _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        stock = PermissionsAdapter(admission.currency);
        registry.registerPermissionedCurrency(admission, 1, bytes32("TEST"));
        registry.registerQuoteToken(address(quote), bytes32("TEST"));

        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        poolId = registry.registerPool(key);
    }

    function _grantPauseRoles() internal {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
    }

    function _enableEmergencyPause() internal {
        registry.setEmergencyPauseEnable(true, keccak256("pause"));
    }

    function _disableEmergencyPause() internal {
        registry.setEmergencyPauseEnable(false, keccak256("resume"));
    }

    function _assertOperationGates(bool tradeAllowed, bool lpAllowed) internal view {
        assertEq(registry.isTradable(poolId), tradeAllowed);
        assertEq(registry.isLPAllowed(poolId), lpAllowed);
    }

    function _delistPrimarySecurity() internal {
        if (registry.getPoolLifeCycle(poolId) != PoolLifecycle.DELIST) {
            registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST"));
        }
        registry.delistSecurity(SECURITY, bytes32("TEST"));
    }

    // Bound Hook and LP identity views for this unit fixture, whose writer is the test contract.
    fallback() external {
        bytes4 selector = msg.sig;
        address result;
        if (selector == bytes4(keccak256("poolManager()"))) result = address(manager);
        else if (selector == bytes4(keccak256("registry()"))) result = address(registry);
        else if (selector == bytes4(keccak256("router()"))) result = address(permissionedRouterFixture);
        else if (selector == bytes4(keccak256("lpManager()"))) result = address(this);
        else if (selector == bytes4(keccak256("ledger()"))) result = address(ledger);
        else revert("unknown component view");
        assembly ("memory-safe") {
            mstore(0, result)
            return(0, 32)
        }
    }

    function _admitAdditionalSecurity(bytes32 securityId) internal {
        registry.registerPermissionedCurrency(_newStockConfig(securityId), 1, bytes32("TEST"));
    }

    function _newStockConfig(bytes32 securityId) internal returns (PermissionedRegisterParam memory) {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped token = new V1MockIssuerWrapped(underlying);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));
        return _prepareCurrency(address(token), securityId, address(adapter));
    }

    function _prepareCurrency(address u, bytes32 securityId, address adapter)
        internal
        returns (PermissionedRegisterParam memory)
    {
        address w = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(u), address(this), IAllowlistChecker(address(issuerChecker))
        );
        PermissionsAdapter(w).updateAllowedWrapper(address(permissionedRouterFixture), true);
        PermissionsAdapter(w).updateAllowedHook(AdapterHooks(address(this)), true);
        V1MockIssuerWrapped(u).mintTestShares(w, 1);
        permissionsFactory.verifyPermissionsAdapter(w);
        return _config(w, securityId, adapter);
    }

    function _config(address w, bytes32 securityId, address adapter)
        internal
        pure
        returns (PermissionedRegisterParam memory)
    {
        return PermissionedRegisterParam(w, securityId, adapter);
    }

    function _setSecurityMode(SecurityPauseMode mode, bool enable) internal {
        registry.applySecurityStatus(SECURITY, mode, enable, bytes32("TEST"));
    }

    function _charge(uint256 shares) internal {
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? int128(-1) : int128(1),
            stock0 ? int128(1) : int128(-1),
            stock0 ? shares : 0,
            stock0 ? 0 : shares
        );
    }

    function _submitQuota(uint256 value) internal {
        ledger.setQuota(SECURITY, value, bytes32("TEST"));
    }
}
