// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVBusinessAuthority, IRecoveryContext} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";

/// @dev Provides a basic ERC-20 token fixture for unit tests.
contract V1MockToken is ERC20 {
    uint8 private immutable tokenDecimals;

    /// @dev Creates a test token with the requested name and decimal precision.
    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        tokenDecimals = decimals_;
    }

    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    /// @dev Returns the test multiplier used to convert displayed balances.
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }
}

/// @dev Provides a deliberately incomplete adapter fixture for validation tests.
contract V1SnapshotOnlyAdapterMock {
    address public immutable poolCurrency;
    uint32 public immutable adapterVersion;

    /// @dev Configures the currency and version exposed by the incomplete adapter fixture.
    constructor(address currency_, uint32 version_) {
        poolCurrency = currency_;
        adapterVersion = version_;
    }
}

/// @dev Provides a configurable governance recovery context for unit tests.
contract V1MockTimelock is IRecoveryContext {
    bool public active;

    /// @dev Configures whether the mock timelock exposes an active recovery context.
    function setActive(bool value) external {
        active = value;
    }

    /// @dev Returns whether the mock recovery context is active.
    function recoveryContextActive() external view returns (bool) {
        return active;
    }

    /// @dev Executes the mock protected governor recovery flow.
    function recover(TSVBusinessAuthority authority, address oldGovernor, address newGovernor) external {
        authority.recoverGovernor(oldGovernor, newGovernor, keccak256("recovery"));
    }
}

/// @dev Exercises core Registry, report, ledger and adapter behavior.
contract TSVFoundationTest is Test {
    bytes32 private constant SECURITY = keccak256("SEC_A");
    uint32 private constant DAY = 20261001;
    uint64 private constant MONTH = 202609;

    TSVUpgradeTimelock internal timelock;
    TSVBusinessAuthority internal authority;
    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    V1MockIssuerShares internal stockUnderlying;
    V1MockIssuerWrapped internal stock;
    V1MockToken internal quote;
    BackedAutoFeeLegalShareAdapter internal stockAdapter;
    PoolKey internal key;
    bytes32 internal poolId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public {
        vm.warp(1_790_827_201);
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelock = new TSVUpgradeTimelock(address(this), guardian, council, executors);
        authority = new TSVBusinessAuthority(address(this), address(timelock));
        TSVEmergencyUpgradeController controller =
            new TSVEmergencyUpgradeController(address(this), guardian, address(timelock));
        _executeGovernance(
            abi.encodeCall(TSVUpgradeTimelock.bindBusinessAuthority, (address(authority))), keccak256("bind-authority")
        );
        _executeGovernance(
            abi.encodeCall(TSVUpgradeTimelock.bindEmergencyController, (address(controller))),
            keccak256("bind-controller")
        );
        anchor = new TSVGovernanceAnchor(address(timelock), address(authority), address(controller));
        _executeGovernance(
            abi.encodeCall(TSVUpgradeTimelock.bindGovernanceAnchor, (address(anchor))), keccak256("bind-anchor")
        );
        registry = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()),
                    abi.encodeCall(TSVRegistryV1.initialize, (address(anchor), address(timelock), address(controller)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize,
                        (address(anchor), address(timelock), address(controller), address(registry), 14_400)
                    )
                )
            )
        );
        inbox = TSVDataInboxV1(
            address(
                new ERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(
                        TSVDataInboxV1.initialize,
                        (address(anchor), address(timelock), address(controller), address(registry), address(ledger))
                    )
                )
            )
        );
        registry.bindComponents(address(this), address(this), address(inbox));
        ledger.bindWriters(address(this), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 25, 10, keccak256("tier"));
        registry.listSecurity(SECURITY, keccak256("STDx"), 1, keccak256("listing"));

        stockUnderlying = new V1MockIssuerShares();
        stock = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1MockToken("QUOTE6", 6);
        stockAdapter = new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        registry.registerToken(_config(address(stock), SECURITY, address(stockAdapter)), keccak256("stock"));
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve-stock"));
        registry.setTokenStatus(address(quote), TokenStatus.APPROVED, keccak256("approve-quote"));

        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        poolId = registry.registerPendingPool(key);
        registry.markPoolActive(poolId, uint160(1 << 96), address(this), keccak256("price"));
    }

    /// @dev Verifies the backed adapter reads the issuer conversion when the swap occurs.
    function testBackedAdapterCallsIssuerConversionAtTheTimeOfSwap() public {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped wrapped = new V1MockIssuerWrapped(underlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(underlying), address(wrapped), 1);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 3e18);
        underlying.setMultiplier(0.9e18, 7);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.7e18);
        underlying.setMultiplier(0.8e18, 8);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.4e18);
    }

    /// @dev Verifies the backed adapter validates Currency and accepts a zero amount.
    function testBackedAdapterValidatesCurrencyAndAllowsZeroAmount() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        assertEq(adapter.toLegalShares(address(stock), 0), 0);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidCurrency.selector);
        adapter.toLegalShares(address(quote), 1e18);
    }

    /// @dev Verifies the backed adapter rejects a wrapped-token asset mismatch.
    function testBackedAdapterRejectsWrappedAssetMismatch() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped otherWrapped = new V1MockIssuerWrapped(otherUnderlying);
        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidAdapterConfig.selector);
        new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(otherWrapped), 1);
    }

    /// @dev Verifies the backed adapter rejects zero conversion and reports its direct interface.
    function testBackedAdapterRejectsZeroConversionAndDeclaresDirectInterface() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        stockUnderlying.setMultiplier(0, 1);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidConversion.selector);
        adapter.toLegalShares(address(stock), 1);
        assertTrue(adapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId));
    }

    /// @dev Verifies the Registry rejects the same security on both pool legs.
    function testRegistryRejectsSameSecurityBothSides() public {
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped secondStock = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(secondStock), 1);
        registry.registerToken(_config(address(secondStock), SECURITY, address(secondAdapter)), keccak256("second"));
        registry.setTokenStatus(address(secondStock), TokenStatus.APPROVED, keccak256("approve-second"));
        address a = address(stock) < address(secondStock) ? address(stock) : address(secondStock);
        address b = address(stock) < address(secondStock) ? address(secondStock) : address(stock);
        PoolKey memory bad = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(bad);
    }

    /// @dev Verifies the Registry accepts a direct adapter and stores its policy metadata.
    function testRegistryAcceptsDirectAdapterAndStoresPolicyMetadata() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(otherUnderlying), address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        registry.registerToken(config, keccak256("wrong-ratio"));
        TokenConfig memory stored = registry.getToken(address(other));
        assertEq(stored.securityId, SECURITY);
        assertEq(stored.legalShareAdapter, address(adapter));
        assertEq(stored.legalSharePolicyHash, config.legalSharePolicyHash);
        TokenConfig memory quoteConfig = registry.getToken(address(quote));
        assertEq(quoteConfig.securityId, bytes32(0));
        assertEq(quoteConfig.legalShareAdapter, address(0));
    }

    /// @dev Verifies the Registry rejects an adapter without the direct-conversion interface.
    function testRegistryRejectsAdapterWithoutDirectInterface() public {
        V1MockToken other = new V1MockToken("Other", 18);
        V1SnapshotOnlyAdapterMock adapter = new V1SnapshotOnlyAdapterMock(address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("adapter-rate"));
    }

    /// @dev Verifies the Registry rejects a direct adapter bound to another Currency.
    function testRegistryRejectsDirectAdapterBoundToDifferentCurrency() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));

        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("wrong-currency"));
    }

    /// @dev Verifies legal-share adapter replacement requires a pause and the next version.
    function testLegalAdapterReplacementRequiresPauseAndNextVersion() public {
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        uint256 pauseId = registry.addEmergencyPause(
            PauseScope.TOKEN,
            bytes32(uint256(uint160(address(stock)))),
            PauseMode.ALL,
            keccak256("replace"),
            keccak256("source")
        );
        BackedAutoFeeLegalShareAdapter wrongVersion =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 3);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(wrongVersion), keccak256("review"));
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        TokenConfig memory config = registry.getToken(address(stock));
        assertEq(config.legalShareAdapter, address(replacement));
        assertEq(config.legalAdapterVersion, 2);
        assertEq(config.legalAdapterCodeHash, address(replacement).codehash);
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.clearEmergencyPause(pauseId, keccak256("done"));
    }

    /// @dev Verifies a disabled pool is re-enabled only after market and asset checks pass.
    function testDisabledPoolOnlyReenablesAfterMarketAndAssetChecks() public {
        registry.disablePool(poolId, keccak256("disable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarket(MarketAction.INITIAL_OPEN, 1, keccak256("open"));
        registry.enablePool(poolId, keccak256("enable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        assertTrue(registry.isTradable(poolId));
    }

    /// @dev Verifies reports and the Ledger use actual deltas and a shared quota.
    function testReportsAndLedgerUseRealDeltaAndSharedQuota() public {
        _submitMarket(MarketAction.INITIAL_OPEN, 1, keccak256("market-1"));
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        assertTrue(registry.isTradable(poolId));
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? 1e18 : 0,
            stock0 ? 0 : 1e18
        );
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1e18);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(11e17) : int128(1e6),
            stock0 ? int128(1e6) : -int128(11e17),
            stock0 ? 11e17 : 0,
            stock0 ? 0 : 11e17
        );
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    /// @dev Verifies one ADTV batch can include multiple securities.
    function testAdtvBatchAcceptsMultipleSecuritiesInOneSubmission() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        registry.listSecurity(secondSecurity, keccak256("STD_y"), 1, keccak256("listing-y"));

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-batch-a"));
        reports[1] = _adtv(lastSecurity, 2000e18, 1, 1, keccak256("adtv-batch-b"));

        inbox.submitAdtvBatch(reports);

        TSVVolumeLedgerV1.AdtvValue memory first = ledger.adtvOf(firstSecurity, uint32(MONTH));
        TSVVolumeLedgerV1.AdtvValue memory last = ledger.adtvOf(lastSecurity, uint32(MONTH));
        assertEq(first.value, 1000e18);
        assertEq(last.value, 2000e18);
        assertEq(first.version, 1);
        assertEq(last.version, 1);
    }

    /// @dev Verifies an ADTV batch reverts atomically when one report is invalid.
    function testAdtvBatchIsAtomicWhenOneReportIsInvalid() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        registry.listSecurity(secondSecurity, keccak256("STD_z"), 1, keccak256("listing-z"));

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-atomic-a"));
        // Version 2 is invalid because this security has no accepted version 1.
        reports[1] = _adtv(lastSecurity, 2000e18, 2, 1, keccak256("adtv-atomic-b"));

        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);

        assertFalse(inbox.reportIdUsed(reports[0].reportId));
        assertFalse(inbox.reportIdUsed(reports[1].reportId));
        assertEq(ledger.adtvOf(firstSecurity, uint32(MONTH)).version, 0);
        assertEq(ledger.adtvOf(lastSecurity, uint32(MONTH)).version, 0);
    }

    /// @dev Verifies daily quota overrides are optional and clearing one restores the hard cap.
    function testDailyQuotaIsOptionalAndClearRestoresTheHardCap() public {
        _submitAdtv(1000e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);

        QuotaReport memory setReport = _quota(2e18, 1, 1, 1, keccak256("quota-set"));
        inbox.submitQuota(setReport);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2e18);

        QuotaReport memory clearReport = _quota(0, 2, 2, 2, keccak256("quota-clear"));
        inbox.submitQuota(clearReport);
        TSVVolumeLedgerV1.QuotaOverride memory quota = ledger.quotaOf(SECURITY, DAY);
        assertFalse(quota.active);
        assertEq(quota.version, 2);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);
    }

    /// @dev Verifies invalid clears and above-cap quota values revert atomically.
    function testQuotaRejectsInvalidClearAndValuesAboveHardCapAtomically() public {
        _submitAdtv(1000e18);
        QuotaReport memory report = _quota(0, 2, 1, 1, keccak256("clear-without-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(0, 1, 1, 1, keccak256("zero-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(3e18, 1, 1, 1, keccak256("over-hard-cap"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));
        assertEq(inbox.lastSequence(2, SECURITY), 0);
    }

    /// @dev Verifies the Registry rejects different stock securities in the same pool.
    function testRegistryRejectsDifferentSecurityStocksInSamePool() public {
        bytes32 secondSecurity = keccak256("SEC_B");
        registry.listSecurity(secondSecurity, keccak256("STDy"), 1, keccak256("listing-b"));
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped second = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(second), 1);
        registry.registerToken(
            _config(address(second), secondSecurity, address(secondAdapter)), keccak256("register-b")
        );
        registry.setTokenStatus(address(second), TokenStatus.APPROVED, keccak256("approve-b"));
        address a = address(stock) < address(second) ? address(stock) : address(second);
        address b = address(stock) < address(second) ? address(second) : address(stock);
        PoolKey memory twoStocks = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(twoStocks);
    }

    /// @dev Verifies market reports do not require a heartbeat and cannot be replayed.
    function testMarketReportDoesNotNeedHeartbeatAndReplayFails() public {
        _submitMarket(MarketAction.INITIAL_HALTED, 1, keccak256("market-1"));
        vm.warp(block.timestamp + 30 days);
        assertEq(uint8(registry.marketStatus(SECURITY)), 2);
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("market-2"));
        report.submitDeadline = uint64(block.timestamp + 1);
        inbox.submitMarketStatus(report);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitMarketStatus(report);
        assertEq(uint8(registry.marketStatus(SECURITY)), 1);
    }

    /// @dev Verifies report submission requires a caller with the direct reporter role.
    function testReportsRequireDirectRoleCaller() public {
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("unauthorized"));
        vm.prank(makeAddr("unregistered-reporter"));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitMarketStatus(report);
    }

    /// @dev Verifies automatic trade-day calculations use Gregorian dates and the previous month.
    function testAutomaticTradeDayUsesGregorianDatesAndPreviousMonth() public {
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, DAY);
        assertEq(ledger.dayStartUTC(DAY), 1_790_827_200);
        assertEq(ledger.dayStartUTC(20280229), ledger.dayStartUTC(20280228) + 86_400);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.dayStartUTC(20260229);
    }

    /// @dev Verifies a day-start change schedules the transition and locks at its start.
    function testDayStartScheduleCreatesLongTransitionAndLocksAtTransitionStart() public {
        uint32 effectiveDay = 20261004;
        uint64 oldTransitionStart = ledger.dayStartUTC(20261003);
        ledger.scheduleDayStart(28_800, effectiveDay, keccak256("offset-change"));
        assertEq(ledger.dayStartCheckpointCount(), 1);
        TSVVolumeLedgerV1.DayStartCheckpoint memory checkpoint = ledger.dayStartCheckpoint(0);
        assertEq(checkpoint.effectiveDayId, effectiveDay);
        assertEq(checkpoint.offsetSeconds, 28_800);
        assertEq(ledger.dayStartUTC(effectiveDay) - oldTransitionStart, 100_800);
        vm.warp(oldTransitionStart);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(keccak256("too-late"));
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, 20261003);
        uint64 effectiveStart = ledger.dayStartUTC(effectiveDay);
        vm.warp(effectiveStart - 1);
        (, day) = ledger.currentTradeDay();
        assertEq(day, 20261003);
        vm.warp(effectiveStart);
        (, day) = ledger.currentTradeDay();
        assertEq(day, effectiveDay);
    }

    /// @dev Verifies a day-start change can be cancelled before transition without retaining a checkpoint.
    function testDayStartCanBeCancelledBeforeTransitionWithoutRetainingCheckpoint() public {
        ledger.scheduleDayStart(3_600, 20261004, keccak256("offset-change"));
        ledger.cancelPendingDayStart(keccak256("cancel-change"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(20261004), ledger.dayStartUTC(20261001) + 3 * 86_400);
    }

    /// @dev Verifies another day-start change can be scheduled after the prior checkpoint takes effect.
    function testCanScheduleAnotherDayStartAfterPriorCheckpointTakesEffect() public {
        ledger.scheduleDayStart(20_000, 20261004, keccak256("first-change"));
        vm.warp(ledger.dayStartUTC(20261004));
        ledger.scheduleDayStart(14_400, 20261010, keccak256("second-change"));
        assertEq(ledger.dayStartCheckpointCount(), 2);
        assertEq(ledger.dayStartUTC(20261009), ledger.dayStartUTC(20261001) + 8 * 86_400 + 5_600);
        assertEq(ledger.dayStartUTC(20261010), ledger.dayStartUTC(20261001) + 9 * 86_400);
        assertEq(ledger.dayStartUTC(20261010) - ledger.dayStartUTC(20261009), 80_800);
    }

    /// @dev Verifies day-start scheduling rejects past boundaries, invalid dates, and shifts above four hours.
    function testDayStartRejectsPastBoundaryInvalidDateAndShiftAboveFourHours() public {
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20261002, keccak256("past-transition"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(28_801, 20261004, keccak256("too-large-shift"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20260229, keccak256("invalid-date"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
    }

    /// @dev Verifies business Governor recovery updates the dynamically resolved admin.
    function testBusinessGovernorRecoveryChangesDynamicAdmin() public {
        address next = makeAddr("new-governor");
        assertTrue(registry.hasRole(0, address(this)));
        bytes memory payload =
            abi.encodeCall(TSVUpgradeTimelock.recoverAuthorities, (next, guardian, keccak256("recovery")));
        bytes32 salt = keccak256("foundation-recovery");
        vm.prank(council);
        timelock.schedule(address(timelock), 0, payload, 0, salt, 0);
        bytes32 id = timelock.hashOperation(address(timelock), 0, payload, 0, salt);
        vm.prank(guardian);
        timelock.approveRecovery(id);
        timelock.execute(address(timelock), 0, payload, 0, salt);
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, next));
        vm.expectRevert();
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
    }

    function testEmergencyPauseModesAcrossAllScopes() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        for (uint8 scope = 0; scope < 4; scope++) {
            bytes32 target = _pauseTarget(PauseScope(scope));
            for (uint8 mode = 1; mode <= 3; mode++) {
                uint256 id = registry.addEmergencyPause(
                    PauseScope(scope), target, PauseMode(mode), keccak256("pause"), keccak256("source")
                );
                assertEq(registry.activePauseCount(scope, target, mode), 1);
                (PauseScope savedScope, bytes32 savedTarget, PauseMode savedMode,,,,, bool active) =
                    registry.emergencyPauses(id);
                assertEq(uint8(savedScope), scope);
                assertEq(savedTarget, target);
                assertEq(uint8(savedMode), mode);
                assertTrue(active);
                _assertOperationGates(mode == uint8(PauseMode.LP), mode == uint8(PauseMode.TRADE));
                registry.clearEmergencyPause(id, keccak256("resume"));
                assertEq(registry.activePauseCount(scope, target, mode), 0);
                _assertOperationGates(true, true);
            }
        }
    }

    function testPauseEventsExposeEmergencyModeAndMarketMaskChanges() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseOpened(
            1, uint8(PauseScope.POOL), poolId, uint8(PauseMode.LP), keccak256("pause")
        );
        _pause(PauseScope.POOL, poolId, PauseMode.LP);
        bytes32 reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.TRADE, uint64(2)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.OPEN),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.NONE),
            uint8(PauseMode.TRADE),
            2,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 2);
        reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.LP, uint64(3)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.HALTED),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.TRADE),
            uint8(PauseMode.ALL),
            3,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 3);
    }

    function testEmergencyPauseRecordsStackAndClearIndependently() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        uint256 trade1 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 trade2 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 lp = _pause(PauseScope.GLOBAL, 0, PauseMode.LP);
        uint256 all = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 2);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(all, keccak256("resume"));
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(lp, keccak256("resume"));
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(trade1, keccak256("resume"));
        _assertOperationGates(false, true);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.clearEmergencyPause(trade1, keccak256("again"));
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 1);
        registry.clearEmergencyPause(trade2, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testEmergencyPauseRejectsNoneInvalidEnumsAndUnauthorizedCallers() public {
        _grantPauseRoles();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.NONE, keccak256("pause"), keccak256("source"));
        (bool success,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(PauseScope.GLOBAL),
                    bytes32(0),
                    uint8(4),
                    keccak256("pause"),
                    keccak256("source")
                )
            );
        assertFalse(success);
        assertEq(registry.nextPauseId(), 1);
        address stranger = makeAddr("pause-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("pause"), keccak256("source"));
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        vm.expectRevert();
        vm.prank(stranger);
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.activePauseCount(uint8(PauseScope.GLOBAL), 0, uint8(PauseMode.ALL)), 1);
    }

    function testEmergencyPauseDoesNotAffectUnrelatedTargetsAndChecksBothCurrencies() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        _pause(PauseScope.POOL, keccak256("other-pool"), PauseMode.ALL);
        _pause(PauseScope.SECURITY, keccak256("other-security"), PauseMode.ALL);
        _pause(PauseScope.TOKEN, bytes32(uint256(uint160(makeAddr("other-token")))), PauseMode.ALL);
        _assertOperationGates(true, true);
        uint256 id = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.LP);
        _assertOperationGates(true, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        assertFalse(registry.isTradable(keccak256("absent-pool")));
        assertFalse(registry.isLPAllowed(keccak256("absent-pool")));
    }

    function testMarketPauseModesAccumulateAndResumeIndependently() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 2);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 3);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 4);
        _assertMarketPause(PauseMode.LP, true, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 5);
        _assertMarketPause(PauseMode.NONE, true, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 6);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 7);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 8);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 9);
        _assertMarketPause(PauseMode.NONE, true, true);
    }

    function testMarketInitialLPPauseAllowsTrading() public {
        _submitMarketMode(MarketAction.INITIAL_HALTED, PauseMode.LP, 1);
        _assertMarketPause(PauseMode.LP, true, false);
    }

    function testMarketInitialAllPauseBlocksBoth() public {
        _submitMarketMode(MarketAction.INITIAL_HALTED, PauseMode.ALL, 1);
        _assertMarketPause(PauseMode.ALL, false, false);
    }

    function testMarketReportsRejectInvalidInitializationNoneAndNoopsAtomically() public {
        _assertOperationGates(false, false);
        _rejectMarketMode(MarketAction.HALT, PauseMode.TRADE, 1, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.ALL, 1, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.INITIAL_OPEN, PauseMode.LP, 1, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.INITIAL_HALTED, PauseMode.NONE, 1, TSVDataInboxV1.InvalidReport.selector);
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _rejectMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 2, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.HALT, PauseMode.NONE, 2, TSVDataInboxV1.InvalidReport.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.NONE, 2, TSVDataInboxV1.InvalidReport.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.ALL, 2, TSVRegistryV1.InvalidStatus.selector);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 2);
        _rejectMarketMode(MarketAction.HALT, PauseMode.TRADE, 3, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.LP, 3, TSVRegistryV1.InvalidStatus.selector);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 3);
        _assertMarketPause(PauseMode.NONE, true, true);
    }

    function testEmergencyAndMarketPauseRecoveriesAreIndependent() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, false);
        id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testPoolEnableRequiresBothOperationTypesToBeUnpaused() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        for (uint8 mode = 1; mode <= 3; mode++) {
            uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode(mode));
            registry.disablePool(poolId, keccak256("disable"));
            uint32 version = registry.getPool(poolId).version;
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId, keccak256("enable"));
            assertEq(registry.getPool(poolId).version, version);
            assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
            registry.clearEmergencyPause(id, keccak256("resume"));
            registry.enablePool(poolId, keccak256("enable"));
            _assertOperationGates(true, true);
        }
        registry.disablePool(poolId, keccak256("disable"));
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        registry.enablePool(poolId, keccak256("enable"));
    }

    function testAdapterReplacementRejectsSingleModePauseAndAllowsCombinedCoverage() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _grantPauseRoles();
        uint256 trade = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.clearEmergencyPause(trade, keccak256("resume"));
        _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.LP);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        assertEq(registry.getToken(address(stock)).legalAdapterVersion, 2);
    }

    function testLedgerUsesOnlyTradingPauseForSwapAccounting() public {
        _submitMarketMode(MarketAction.INITIAL_OPEN, PauseMode.ALL, 1);
        _submitAdtv(1000e18);
        _grantPauseRoles();
        _pause(PauseScope.GLOBAL, 0, PauseMode.LP);
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        int128 delta0 = stock0 ? -int128(1e18) : int128(1e6);
        int128 delta1 = stock0 ? int128(1e6) : -int128(1e18);
        ledger.recordSwap(poolId, delta0, delta1, stock0 ? 1e18 : 0, stock0 ? 0 : 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.recordSwap(poolId, delta0, delta1, stock0 ? 1e18 : 0, stock0 ? 0 : 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function _grantPauseRoles() private {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
    }

    function _pauseTarget(PauseScope scope) private view returns (bytes32) {
        if (scope == PauseScope.GLOBAL) return 0;
        if (scope == PauseScope.SECURITY) return SECURITY;
        if (scope == PauseScope.TOKEN) return bytes32(uint256(uint160(address(stock))));
        return poolId;
    }

    function _pause(PauseScope scope, bytes32 target, PauseMode mode) private returns (uint256) {
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"), keccak256("source"));
    }

    function _assertOperationGates(bool tradeAllowed, bool lpAllowed) private view {
        assertEq(registry.isTradable(poolId), tradeAllowed);
        assertEq(registry.isLPAllowed(poolId), lpAllowed);
    }

    function _assertMarketPause(PauseMode mode, bool tradeAllowed, bool lpAllowed) private view {
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(mode));
        assertEq(
            uint8(registry.marketStatus(SECURITY)),
            uint8(mode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED)
        );
        _assertOperationGates(tradeAllowed, lpAllowed);
    }

    function _submitMarketMode(MarketAction action, PauseMode mode, uint64 sequence) private {
        MarketReport memory report =
            _market(action, sequence, keccak256(abi.encode("market-mode", action, mode, sequence)));
        report.mode = mode;
        inbox.submitMarketStatus(report);
    }

    function _rejectMarketMode(MarketAction action, PauseMode mode, uint64 sequence, bytes4 expectedError) private {
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

    /// @dev Schedules and executes a governance operation through the test timelock.
    function _executeGovernance(bytes memory payload, bytes32 salt) private {
        timelock.schedule(address(timelock), 0, payload, 0, salt, 0);
        timelock.execute(address(timelock), 0, payload, 0, salt);
    }

    /// @dev Builds a token registration configuration for the supplied currency and security.
    function _config(address token, bytes32 securityId, address legalAdapter)
        private
        view
        returns (TokenConfig memory c)
    {
        c.poolCurrency = token;
        c.poolDecimals = IERC20Metadata(token).decimals();
        c.securityId = securityId;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("share-policy");
        c.status = TokenStatus.UNREVIEWED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    /// @dev Builds a market-state report with the supplied action and sequence metadata.
    function _market(MarketAction action, uint64 sequence, bytes32 reportId)
        private
        view
        returns (MarketReport memory report)
    {
        report = MarketReport(
            SECURITY,
            action,
            PauseMode.ALL,
            keccak256("reason"),
            keccak256("exchange"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            reportId,
            keccak256("source")
        );
    }

    /// @dev Submits a market-state report to the data Inbox.
    function _submitMarket(MarketAction action, uint64 sequence, bytes32 reportId) private {
        MarketReport memory report = _market(action, sequence, reportId);
        inbox.submitMarketStatus(report);
    }

    /// @dev Submits a monthly ADTV report for the configured security.
    function _submitAdtv(uint256 value) private {
        AdtvReport memory report = _adtv(SECURITY, value, 1, 1, keccak256("adtv"));
        inbox.submitAdtv(report);
    }

    /// @dev Builds an ADTV report with the supplied value and replay-protection metadata.
    function _adtv(bytes32 securityId, uint256 value, uint64 version, uint64 sequence, bytes32 reportId)
        private
        view
        returns (AdtvReport memory)
    {
        return AdtvReport(
            securityId,
            uint32(MONTH),
            value,
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            version,
            sequence,
            reportId,
            keccak256("source")
        );
    }

    /// @dev Submits a daily quota override report for the configured security.
    function _submitQuota(uint256 value) private {
        QuotaReport memory report = _quota(value, 1, 1, 1, keccak256("quota"));
        inbox.submitQuota(report);
    }

    /// @dev Builds a daily quota report with the supplied action and replay-protection metadata.
    function _quota(uint256 value, uint8 action, uint64 version, uint64 sequence, bytes32 reportId)
        private
        view
        returns (QuotaReport memory)
    {
        return QuotaReport(
            SECURITY,
            DAY,
            action,
            value,
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            version,
            sequence,
            reportId,
            keccak256("source")
        );
    }
}
