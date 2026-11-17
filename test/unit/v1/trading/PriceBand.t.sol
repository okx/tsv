// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolRecord, UnderlyingRecord, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";

contract PriceBandMockManager {
    bytes32 private slot0;

    function setSlot0(int24 tick) external {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        slot0 = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
    }

    function extsload(bytes32) external view returns (bytes32) {
        return slot0;
    }
}

contract PriceBandMockRegistry {
    PoolRecord private pool;
    bytes32 private poolId;
    address private stockCurrency;
    address private underlying;
    address private adapter;
    bool public writerAuthorized = true;

    function configure(PoolKey memory key, address stock, address underlying_, address adapter_) external {
        poolId = PoolId.unwrap(key.toId());
        pool = PoolRecord(key, keccak256("SECURITY"), 1, PoolLifecycle.LIST, 0, 1);
        stockCurrency = stock;
        underlying = underlying_;
        adapter = adapter_;
    }

    function setWriterAuthorized(bool authorized) external {
        writerAuthorized = authorized;
    }

    function hasRole(bytes32, address) external view returns (bool) {
        return writerAuthorized;
    }

    function isKnownPool(bytes32 id) external view returns (bool) {
        return id == poolId;
    }

    function getPool(bytes32) external view returns (PoolRecord memory) {
        return pool;
    }

    function getCurrencyUnderlying(address currency) external view returns (address) {
        return currency == stockCurrency ? underlying : address(0);
    }

    function getUnderlying(address) external view returns (UnderlyingRecord memory) {
        return UnderlyingRecord(keccak256("SECURITY"), adapter, 18, true);
    }
}

contract PriceBandMockLedger {
    uint256 public recordCalls;
    bytes32 public constant ROLE = keccak256("VOLUME_ORACLE_ROLE");

    function VOLUME_ORACLE_ROLE() external pure returns (bytes32) {
        return ROLE;
    }

    function recordSwap(bytes32, int128, int128, uint256, uint256) external {
        ++recordCalls;
    }
}

contract PriceBandMockAdapter {
    function currentMultiplier(address) external pure returns (uint256) {
        return 1e18;
    }

    function toLegalShares(address, uint256 rawAmount) external pure returns (uint256) {
        return rawAmount;
    }
}

contract PriceBandTest is Test {
    using PoolIdLibrary for PoolKey;

    uint48 private constant START = 1_000;
    uint48 private constant END = 2_000;
    int24 private constant LOWER = -60;
    int24 private constant UPPER = 60;

    TSVHookV1 private hook;
    PriceBandMockManager private manager;
    PriceBandMockRegistry private registry;
    PriceBandMockLedger private ledger;
    PriceBandMockAdapter private adapter;
    PoolKey private key;
    bytes32 private poolId;
    address private constant HOOK_PROXY = address(uint160(0x3FFF));
    address private constant STOCK = address(0x100);
    address private constant QUOTE = address(0x200);
    address private constant UNDERLYING = address(0x300);

    function setUp() public {
        manager = new PriceBandMockManager();
        registry = new PriceBandMockRegistry();
        ledger = new PriceBandMockLedger();
        adapter = new PriceBandMockAdapter();

        vm.etch(HOOK_PROXY, type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            HOOK_PROXY,
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook = TSVHookV1(HOOK_PROXY);
        hook.initialize(
            address(manager), address(registry), address(ledger), address(this), address(this)
        );

        key = PoolKey(
            Currency.wrap(STOCK), Currency.wrap(QUOTE), 3_000, 60, IHooks(HOOK_PROXY)
        );
        poolId = PoolId.unwrap(key.toId());
        registry.configure(key, STOCK, UNDERLYING, address(adapter));
    }

    function testActiveWindowIncludesBothTickBounds() public {
        _setBand(LOWER, UPPER, START, END);

        vm.warp(START);
        _afterSwapAt(LOWER);
        _afterSwapAt(UPPER);

        assertEq(ledger.recordCalls(), 2);
    }

    function testActiveWindowRejectsTicksBelowAndAboveBandBeforeLedgerAccounting() public {
        _setBand(LOWER, UPPER, START, END);
        vm.warp(START + 1);

        manager.setSlot0(LOWER - 1);
        (, int24 observedTick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), key.toId());
        assertEq(observedTick, LOWER - 1);
        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.PriceOutsideBand.selector, poolId, LOWER - 1, LOWER, UPPER));
        _invokeAfterSwap();
        manager.setSlot0(UPPER + 1);
        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.PriceOutsideBand.selector, poolId, UPPER + 1, LOWER, UPPER));
        _invokeAfterSwap();

        assertEq(ledger.recordCalls(), 0);
    }

    function testWindowStartIsInclusiveAndEndIsExclusive() public {
        _setBand(LOWER, UPPER, START, END);

        vm.warp(START - 1);
        _afterSwapAt(LOWER - 1);

        vm.warp(START);
        _afterSwapAt(LOWER);

        vm.warp(END - 1);
        _afterSwapAt(UPPER);

        vm.warp(END);
        _afterSwapAt(UPPER + 1);

        assertEq(ledger.recordCalls(), 4);
    }

    function testUnconfiguredAndExpiredBandsDoNotBlockSwaps() public {
        vm.warp(START);
        _afterSwapAt(LOWER - 1);

        _setBand(LOWER, UPPER, START, END);
        vm.warp(END + 1);
        _afterSwapAt(UPPER + 1);

        assertEq(ledger.recordCalls(), 2);
    }

    function testSetPriceBandsRejectsUnauthorizedWriterAndMismatchedArrays() public {
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = poolId;
        TSVHookV1.PriceBandUpdate[] memory updates = new TSVHookV1.PriceBandUpdate[](1);
        updates[0] = TSVHookV1.PriceBandUpdate(LOWER, UPPER, START, END);

        registry.setWriterAuthorized(false);
        vm.expectRevert(TSVHookV1.UnauthorizedPriceBandWriter.selector);
        hook.setPriceBands(poolIds, updates);

        registry.setWriterAuthorized(true);
        bytes32[] memory emptyPoolIds = new bytes32[](0);
        vm.expectRevert(TSVHookV1.InvalidPriceBandBatchLength.selector);
        hook.setPriceBands(emptyPoolIds, updates);
    }

    function testSetPriceBandsRejectsInvalidWindow() public {
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = poolId;
        TSVHookV1.PriceBandUpdate[] memory updates = new TSVHookV1.PriceBandUpdate[](1);

        updates[0] = TSVHookV1.PriceBandUpdate(LOWER, UPPER, END, START);
        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.InvalidPriceBand.selector, poolId));
        hook.setPriceBands(poolIds, updates);

    }

    function testNonSpacingAlignedTicksCanBeConfiguredAndEnforced() public {
        int24 lower = LOWER + 1;
        int24 upper = UPPER + 1;
        _setBand(lower, upper, START, END);
        (int24 savedLower, int24 savedUpper,,) = hook.priceBands(poolId);
        assertEq(savedLower, lower);
        assertEq(savedUpper, upper);

        vm.warp(START);
        _afterSwapAt(lower);
        _afterSwapAt(upper);
        manager.setSlot0(lower - 1);
        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.PriceOutsideBand.selector, poolId, lower - 1, lower, upper));
        _invokeAfterSwap();
        manager.setSlot0(upper + 1);
        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.PriceOutsideBand.selector, poolId, upper + 1, lower, upper));
        _invokeAfterSwap();

        assertEq(ledger.recordCalls(), 2);
    }

    function testInvalidEntryRevertsEntireBatchWithoutSavingEarlierEntries() public {
        bytes32[] memory poolIds = new bytes32[](2);
        poolIds[0] = poolId;
        poolIds[1] = poolId;
        TSVHookV1.PriceBandUpdate[] memory updates = new TSVHookV1.PriceBandUpdate[](2);
        updates[0] = TSVHookV1.PriceBandUpdate(LOWER, UPPER, START, END);
        updates[1] = TSVHookV1.PriceBandUpdate(LOWER, UPPER, END, START);

        vm.expectRevert(abi.encodeWithSelector(TSVHookV1.InvalidPriceBand.selector, poolId));
        hook.setPriceBands(poolIds, updates);

        (,,, uint48 endsAt) = hook.priceBands(poolId);
        assertEq(endsAt, 0);
    }

    function _setBand(int24 lower, int24 upper, uint48 startsAt, uint48 endsAt) private {
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = poolId;
        TSVHookV1.PriceBandUpdate[] memory updates = new TSVHookV1.PriceBandUpdate[](1);
        updates[0] = TSVHookV1.PriceBandUpdate(lower, upper, startsAt, endsAt);
        hook.setPriceBands(poolIds, updates);
    }

    function _afterSwapAt(int24 tick) private {
        manager.setSlot0(tick);
        _invokeAfterSwap();
    }

    function _invokeAfterSwap() private {
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            IPoolManager.SwapParams(true, -1, 0),
            toBalanceDelta(-1, 1),
            abi.encode(uint256(1e18))
        );
    }
}
