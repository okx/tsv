// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    TokenConfig,
    AssetClass,
    SettlementMode,
    TokenStatus,
    MarketAction,
    PauseScope,
    RateSnapshot,
    RoundingMode
} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVBusinessAuthority, IRecoveryContext} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {StaticLegalShareAdapter} from "tsv-v1/adapters/StaticLegalShareAdapter.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";

contract V1MockToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

contract V1MockMultiplier {
    uint256 public multiplier = 1e18;
    uint256 public nonce;

    function set(uint256 multiplier_, uint256 nonce_) external {
        multiplier = multiplier_;
        nonce = nonce_;
    }

    function getCurrentMultiplier() external view returns (uint256, uint256, uint256) {
        return (multiplier, 0, nonce);
    }
}

contract V1MockTimelock is IRecoveryContext {
    bool public active;

    function setActive(bool value) external {
        active = value;
    }

    function recoveryContextActive() external view returns (bool) {
        return active;
    }

    function recover(TSVBusinessAuthority authority, address oldGovernor, address newGovernor) external {
        authority.recoverGovernor(oldGovernor, newGovernor, keccak256("recovery"));
    }
}

contract TSVFoundationTest is Test {
    bytes32 private constant SECURITY = keccak256("SEC_A");
    uint32 private constant DAY = 20261001;
    uint64 private constant MONTH = 202609;

    V1MockTimelock internal timelock;
    TSVBusinessAuthority internal authority;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    V1MockToken internal stock;
    V1MockToken internal quote;
    StaticLegalShareAdapter internal stockAdapter;
    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() public {
        vm.warp(1_790_827_201);
        timelock = new V1MockTimelock();
        authority = new TSVBusinessAuthority(address(this), address(timelock));
        registry = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()),
                    abi.encodeCall(TSVRegistryV1.initialize, (address(authority), address(timelock), address(0xCAFE)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize,
                        (address(authority), address(timelock), address(0xCAFE), address(registry), 14_400)
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
                        (address(authority), address(timelock), address(0xCAFE), address(registry), address(ledger))
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

        stock = new V1MockToken("STDx", 18);
        quote = new V1MockToken("QUOTE6", 6);
        stockAdapter = new StaticLegalShareAdapter(address(stock), 18, 1e18, 1);
        registry.registerToken(
            _config(stock, AssetClass.FIXED_BALANCE_STOCK, SECURITY, address(stockAdapter)), keccak256("stock")
        );
        registry.registerToken(_config(quote, AssetClass.QUOTE_ERC20, 0, address(0)), keccak256("quote"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve-stock"));
        registry.setTokenStatus(address(quote), TokenStatus.APPROVED, keccak256("approve-quote"));

        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        poolId = registry.registerPendingPool(key);
        registry.markPoolActive(poolId, uint160(1 << 96), address(this), keccak256("price"));
    }

    function testStaticLegalShareRoundsUpAndRejectsStaleRate() public {
        RateSnapshot memory rate = stockAdapter.snapshot(address(stock));
        assertEq(stockAdapter.toLegalShares(address(stock), 2e18, rate), 2e18);
        assertEq(stockAdapter.toLegalShares(address(stock), 1, rate), 1);
        rate.numerator = 2e18;
        vm.expectRevert(StaticLegalShareAdapter.InvalidRate.selector);
        stockAdapter.toLegalShares(address(stock), 1, rate);
    }

    function testDynamicLegalShareUsesCurrentMultiplierAndVersionedRateId() public {
        V1MockMultiplier underlying = new V1MockMultiplier();
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(underlying), address(quote), 1);
        underlying.set(0.9e18, 7);
        RateSnapshot memory rate = adapter.snapshot(address(quote));
        assertEq(adapter.toLegalShares(address(quote), 3e18, rate), 2.7e18);
        assertEq(rate.rateId, keccak256(abi.encode(address(underlying), uint256(0.9e18), uint256(7), uint32(1))));
        underlying.set(0.8e18, 8);
        assertFalse(adapter.isCurrent(address(quote), rate));
        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidRate.selector);
        adapter.toLegalShares(address(quote), 3e18, rate);
    }

    function testRegistryRejectsSameSecurityBothSides() public {
        V1MockToken secondStock = new V1MockToken("Second", 18);
        StaticLegalShareAdapter secondAdapter = new StaticLegalShareAdapter(address(secondStock), 18, 1e18, 1);
        registry.registerToken(
            _config(secondStock, AssetClass.FIXED_BALANCE_STOCK, SECURITY, address(secondAdapter)), keccak256("second")
        );
        registry.setTokenStatus(address(secondStock), TokenStatus.APPROVED, keccak256("approve-second"));
        address a = address(stock) < address(secondStock) ? address(stock) : address(secondStock);
        address b = address(stock) < address(secondStock) ? address(secondStock) : address(stock);
        PoolKey memory bad = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(bad);
    }

    function testRegistryDoesNotKeepASecondStaticRatioSource() public {
        V1MockToken other = new V1MockToken("Other", 18);
        StaticLegalShareAdapter adapter = new StaticLegalShareAdapter(address(other), 18, 2e18, 1);
        TokenConfig memory config = _config(other, AssetClass.FIXED_BALANCE_STOCK, SECURITY, address(adapter));
        registry.registerToken(config, keccak256("wrong-ratio"));
        TokenConfig memory stored = registry.getToken(address(other));
        assertEq(stored.sharesPerWholeTokenWad, 0);
        assertEq(stored.ratioEvidenceHash, bytes32(0));
        assertEq(stored.legalSharePolicyHash, config.legalSharePolicyHash);
        RateSnapshot memory rate = adapter.snapshot(address(other));
        assertEq(rate.numerator, 2e18);
    }

    function testRegistryRejectsStaticDenominatorMismatch() public {
        V1MockToken other = new V1MockToken("Other", 18);
        StaticLegalShareAdapter adapter = new StaticLegalShareAdapter(address(other), 6, 1e18, 1);
        TokenConfig memory config = _config(other, AssetClass.FIXED_BALANCE_STOCK, SECURITY, address(adapter));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("wrong-denominator"));
        assertEq(registry.currencyOf(address(other)), address(0));
    }

    function testLegalAdapterReplacementRequiresPauseAndNextVersion() public {
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        StaticLegalShareAdapter replacement = new StaticLegalShareAdapter(address(stock), 18, 1e18, 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        uint256 pauseId = registry.addEmergencyPause(
            PauseScope.TOKEN, bytes32(uint256(uint160(address(stock)))), keccak256("replace"), keccak256("source")
        );
        StaticLegalShareAdapter wrongVersion = new StaticLegalShareAdapter(address(stock), 18, 1e18, 3);
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

    function testReportsAndLedgerUseRealDeltaAndSharedQuota() public {
        _submitMarket(MarketAction.INITIAL_OPEN, 1, keccak256("market-1"));
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        assertTrue(registry.isTradable(poolId));
        RateSnapshot memory zero;
        RateSnapshot memory stockRate = stockAdapter.snapshot(address(stock));
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? stockRate : zero,
            stock0 ? zero : stockRate
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
            stock0 ? stockRate : zero,
            stock0 ? zero : stockRate
        );
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

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

    function testRegistryRejectsDifferentSecurityStocksInSamePool() public {
        bytes32 secondSecurity = keccak256("SEC_B");
        registry.listSecurity(secondSecurity, keccak256("STDy"), 1, keccak256("listing-b"));
        V1MockToken second = new V1MockToken("STDy", 18);
        StaticLegalShareAdapter secondAdapter = new StaticLegalShareAdapter(address(second), 18, 1e18, 1);
        registry.registerToken(
            _config(second, AssetClass.FIXED_BALANCE_STOCK, secondSecurity, address(secondAdapter)),
            keccak256("register-b")
        );
        registry.setTokenStatus(address(second), TokenStatus.APPROVED, keccak256("approve-b"));
        address a = address(stock) < address(second) ? address(stock) : address(second);
        address b = address(stock) < address(second) ? address(second) : address(stock);
        PoolKey memory twoStocks = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(twoStocks);
    }

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

    function testReportsRequireDirectRoleCaller() public {
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("unauthorized"));
        vm.prank(makeAddr("unregistered-reporter"));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitMarketStatus(report);
    }

    function testAutomaticTradeDayUsesGregorianDatesAndPreviousMonth() public {
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, DAY);
        assertEq(ledger.dayStartUTC(DAY), 1_790_827_200);
        assertEq(ledger.dayStartUTC(20280229), ledger.dayStartUTC(20280228) + 86_400);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.dayStartUTC(20260229);
    }

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

    function testDayStartCanBeCancelledBeforeTransitionWithoutRetainingCheckpoint() public {
        ledger.scheduleDayStart(3_600, 20261004, keccak256("offset-change"));
        ledger.cancelPendingDayStart(keccak256("cancel-change"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(20261004), ledger.dayStartUTC(20261001) + 3 * 86_400);
    }

    function testCanScheduleAnotherDayStartAfterPriorCheckpointTakesEffect() public {
        ledger.scheduleDayStart(20_000, 20261004, keccak256("first-change"));
        vm.warp(ledger.dayStartUTC(20261004));
        ledger.scheduleDayStart(14_400, 20261010, keccak256("second-change"));
        assertEq(ledger.dayStartCheckpointCount(), 2);
        assertEq(ledger.dayStartUTC(20261009), ledger.dayStartUTC(20261001) + 8 * 86_400 + 5_600);
        assertEq(ledger.dayStartUTC(20261010), ledger.dayStartUTC(20261001) + 9 * 86_400);
        assertEq(ledger.dayStartUTC(20261010) - ledger.dayStartUTC(20261009), 80_800);
    }

    function testDayStartRejectsPastBoundaryInvalidDateAndShiftAboveFourHours() public {
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20261002, keccak256("past-transition"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(28_801, 20261004, keccak256("too-large-shift"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20260229, keccak256("invalid-date"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
    }

    function testBusinessGovernorRecoveryChangesDynamicAdmin() public {
        address next = makeAddr("new-governor");
        assertTrue(registry.hasRole(0, address(this)));
        timelock.setActive(true);
        timelock.recover(authority, address(this), next);
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, next));
        vm.expectRevert();
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
    }

    function _config(V1MockToken token, AssetClass assetClass, bytes32 securityId, address legalAdapter)
        private
        view
        returns (TokenConfig memory c)
    {
        c.userToken = address(token);
        c.poolCurrency = address(token);
        c.userDecimals = token.decimals();
        c.poolDecimals = token.decimals();
        c.assetClass = assetClass;
        c.securityId = securityId;
        c.settlementMode = SettlementMode.DIRECT_ERC20;
        c.settlementVersion = 1;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        c.sharesPerWholeTokenWad = 0;
        c.ratioEvidenceHash = 0;
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("share-policy");
        c.status = TokenStatus.UNREVIEWED;
        c.userRuntimeCodeHash = address(token).codehash;
        c.poolRuntimeCodeHash = address(token).codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    function _market(MarketAction action, uint64 sequence, bytes32 reportId)
        private
        view
        returns (MarketReport memory report)
    {
        report = MarketReport(
            SECURITY,
            action,
            keccak256("reason"),
            keccak256("exchange"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            reportId,
            keccak256("source")
        );
    }

    function _submitMarket(MarketAction action, uint64 sequence, bytes32 reportId) private {
        MarketReport memory report = _market(action, sequence, reportId);
        inbox.submitMarketStatus(report);
    }

    function _submitAdtv(uint256 value) private {
        AdtvReport memory report = _adtv(SECURITY, value, 1, 1, keccak256("adtv"));
        inbox.submitAdtv(report);
    }

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

    function _submitQuota(uint256 value) private {
        QuotaReport memory report = _quota(value, 1, 1, 1, keccak256("quota"));
        inbox.submitQuota(report);
    }

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
