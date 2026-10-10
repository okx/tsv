// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/PoolManager.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {IERC20 as PermissionedIERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {V1PermissionedComponent, V1ConfigReceiver, V1IssuerAllowlistChecker} from "./PermissionedMocks.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    PermissionedAdmission,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "./MockIssuerTokens.sol";
import {V1MockToken} from "./FoundationMocks.sol";
import {OperationsSbt} from "./OperationsMocks.sol";

/// @dev FoundationFixture scenarios; inherited fixtures contain no test functions.
abstract contract FoundationFixture is Test {
    bytes32 internal constant SECURITY = keccak256("SEC_A");
    uint32 internal constant DAY = 20261001;
    uint64 internal constant MONTH = 202609;

    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
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
    BackedAutoFeeLegalShareAdapter internal stockAdapter;
    PoolKey internal key;
    bytes32 internal poolId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public virtual {
        vm.warp(1_790_827_201);
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        anchor = new TSVGovernanceAnchor(address(this), guardian, council);
        registry = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
                )
            )
        );
        inbox = TSVDataInboxV1(
            address(
                new ERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
                )
            )
        );
        manager = new PoolManager(address(this));
        permissionsFactory = new PermissionsAdapterFactory(address(manager));
        identitySbt = new OperationsSbt();
        permissionedRouterFixture =
            new V1PermissionedComponent(address(manager), address(registry), address(permissionsFactory));
        registry.bindComponents(
            address(this), address(this), address(inbox), address(permissionsFactory), address(identitySbt)
        );
        exitReceiver = new V1ConfigReceiver();
        issuerChecker = new V1IssuerAllowlistChecker();
        ledger.bindWriters(address(this), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 25, 10);

        stockUnderlying = new V1MockIssuerShares();
        stockToken = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1MockToken("QUOTE6", 6);
        stockAdapter = new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        PermissionedAdmission memory admission = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        stock = PermissionsAdapter(admission.currency);
        registry.registerPermissionedCurrency(admission, 1);
        registry.registerQuoteToken(address(quote));

        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        poolId = registry.registerPool(key);
    }

    function _grantPauseRoles() internal {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
    }

    function _pauseTarget(PauseScope scope) internal view returns (bytes32) {
        if (scope == PauseScope.GLOBAL) return 0;
        if (scope == PauseScope.SECURITY) return SECURITY;
        if (scope == PauseScope.TOKEN) return bytes32(uint256(uint160(address(stock))));
        return poolId;
    }

    function _pause(PauseScope scope, bytes32 target, PauseMode mode) internal returns (uint256) {
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"));
    }

    function _assertOperationGates(bool tradeAllowed, bool lpAllowed) internal view {
        assertEq(registry.isTradable(poolId), tradeAllowed);
        assertEq(registry.isLPAllowed(poolId), lpAllowed);
    }

    function _assertMarketPause(PauseMode mode, bool tradeAllowed, bool lpAllowed) internal view {
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(mode));
        assertEq(
            uint8(registry.marketStatus(SECURITY)),
            uint8(mode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED)
        );
        _assertOperationGates(tradeAllowed, lpAllowed);
    }

    function _submitMarketMode(MarketAction action, PauseMode mode, uint64 sequence) internal {
        MarketReport memory report =
            _market(action, sequence, keccak256(abi.encode("market-mode", action, mode, sequence)));
        report.mode = mode;
        inbox.submitMarketStatus(report);
    }

    function _rejectMarketMode(MarketAction action, PauseMode mode, uint64 sequence, bytes4 expectedError) internal {
        MarketReport memory report =
            _market(action, sequence, keccak256(abi.encode("rejected-market-mode", action, mode, sequence)));
        report.mode = mode;
        uint64 previousSequence = registry.marketSequence(SECURITY);
        vm.expectRevert(expectedError);
        inbox.submitMarketStatus(report);
        assertEq(registry.marketSequence(SECURITY), previousSequence);
        assertEq(inbox.lastSequence(0, SECURITY), previousSequence);
        assertFalse(inbox.reportIdUsed(report.reportId));
    }

    function _delistPrimarySecurity() internal {
        if (registry.getPoolLifeCycle(poolId) != PoolLifecycle.DELIST) {
            registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST);
        }
        registry.delistSecurity(SECURITY);
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
        registry.registerPermissionedCurrency(_newStockConfig(securityId), 1);
    }

    function _newStockConfig(bytes32 securityId) internal returns (PermissionedAdmission memory) {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped token = new V1MockIssuerWrapped(underlying);
        BackedAutoFeeLegalShareAdapter adapter = new BackedAutoFeeLegalShareAdapter(address(underlying), address(token));
        return _prepareCurrency(address(token), securityId, address(adapter));
    }

    function _prepareCurrency(address u, bytes32 securityId, address adapter)
        internal
        returns (PermissionedAdmission memory)
    {
        address w = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(u), address(this), IAllowlistChecker(address(issuerChecker))
        );
        PermissionsAdapter(w).updateAllowedWrapper(address(permissionedRouterFixture), true);
        PermissionsAdapter(w).updateAllowedHook(IHooks(address(this)), true);
        V1MockIssuerWrapped(u).mintTestShares(w, 1);
        permissionsFactory.verifyPermissionsAdapter(w);
        if (registry.exitAdminOf(u) == address(0)) registry.setExitAdmin(u, address(exitReceiver));
        return _config(w, securityId, adapter);
    }

    function _config(address w, bytes32 securityId, address adapter)
        internal
        view
        returns (PermissionedAdmission memory)
    {
        return PermissionedAdmission(w, securityId, adapter);
    }

    /// @dev Builds a market-state report with the supplied action and sequence metadata.
    function _market(MarketAction action, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (MarketReport memory report)
    {
        report = MarketReport(
            SECURITY,
            action,
            PauseMode.ALL,
            keccak256("reason"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            reportId
        );
    }

    /// @dev Submits a market-state report to the data Inbox.
    function _submitMarket(MarketAction action, uint64 sequence, bytes32 reportId) internal {
        MarketReport memory report = _market(action, sequence, reportId);
        inbox.submitMarketStatus(report);
    }

    /// @dev Submits a monthly ADTV report for the configured security.
    function _submitAdtv(uint256 value) internal {
        AdtvReport memory report = _adtv(SECURITY, value, 1, keccak256("adtv"));
        inbox.submitAdtv(report);
    }

    /// @dev Builds an ADTV report with the supplied value and replay-protection metadata.
    function _adtv(bytes32 securityId, uint256 value, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (AdtvReport memory)
    {
        return AdtvReport(
            securityId,
            uint32(MONTH),
            value,
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            reportId
        );
    }

    /// @dev Submits a daily quota override report for the configured security.
    function _submitQuota(uint256 value) internal {
        QuotaReport memory report = _quota(value, 1, 1, keccak256("quota"));
        inbox.submitQuota(report);
    }

    /// @dev Builds a daily quota report with the supplied action and replay-protection metadata.
    function _quota(uint256 value, uint8 action, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (QuotaReport memory)
    {
        return QuotaReport(
            SECURITY, DAY, action, value, uint64(block.timestamp - 1), uint64(block.timestamp + 100), sequence, reportId
        );
    }
}
