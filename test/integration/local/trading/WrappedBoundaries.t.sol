// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";
import {SwapRequest, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ImmutableState} from "tsv-v1/vendor/v4-router/base/ImmutableState.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVWrappedBoundariesTest is WrappedSwapFixture {
    using PoolIdLibrary for PoolKey;
    address private nextRouterImplementation;

    function testPoolInitializationFailureRollsBackRegistrationAndCanBeRetried() public {
        PoolKey memory newKey = key;
        newKey.fee = 500;
        bytes32 id = PoolId.unwrap(newKey.toId());
        vm.expectRevert();
        seed.initializePool(newKey, 0);
        assertFalse(registry.isKnownPool(id));
        assertFalse(registry.isTradable(id));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, newKey.toId());
        assertEq(price, 0);
        seed.initializePool(newKey, uint160(1 << 96));
        assertTrue(registry.isKnownPool(id));
        assertTrue(registry.isTradable(id));
        (price,,,) = StateLibrary.getSlot0(manager, newKey.toId());
        assertEq(price, uint160(1 << 96));
        vm.expectRevert();
        seed.initializePool(newKey, uint160(1 << 96));
        (price,,,) = StateLibrary.getSlot0(manager, newKey.toId());
        assertEq(price, uint160(1 << 96));
    }

    function testUnregisteredPoolCannotBeInitializedThroughPoolManager() public {
        PoolKey memory newKey = key;
        newKey.fee = 500;
        vm.expectRevert();
        vm.prank(address(seed));
        manager.initialize(newKey, uint160(1 << 96));
        assertFalse(registry.isKnownPool(PoolId.unwrap(newKey.toId())));
    }

    function testDelistingStopsSwapsAndRelistingUsesHistoricalPool() public {
        _swap(true, true, 1e16);
        bytes32 id = PoolId.unwrap(key.toId());
        registry.updatePoolLifeCycle(id, PoolLifecycle.DELIST);
        registry.delistSecurity(SECURITY);
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(false, true, 1e16);
        assertEq(_digest(), before_);
        assertTrue(registry.isKnownPool(id));
        registry.relistSecurity(SECURITY);
        registry.updatePoolLifeCycle(id, PoolLifecycle.LIST);
        _swap(false, true, 1e16);
    }

    function testExactInputCanFillPartiallyAndOnlyChargesRealizedInput() public {
        uint256 before_ = underlying.balanceOf(alice);
        (uint256 paid, uint256 received) = _swap(true, true, 1e22);
        assertGt(paid, 0);
        assertLt(paid, 1e22);
        assertGt(received, 0);
        assertEq(before_ - underlying.balanceOf(alice), paid);
        assertEq(ledger.used(SECURITY, DAY), paid);
        assertEq(_inventory(), 17);
    }

    function testExactOutputMustFillAndMaximumInputAndMinimumOutputApply() public {
        bytes32 before_ = _digest();
        SwapRequest memory request = _request(false, false, 1e22);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactOutput(request);
        assertEq(_digest(), before_);
        request = _request(false, false, 1e16);
        request.limitAmount = 1;
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactOutput(request);
        assertEq(_digest(), before_);
        request = _request(true, true, 1e16);
        request.limitAmount = 1e22;
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_digest(), before_);
        _swap(false, false, 1e16);
    }

    function testFuzzMalformedRequestDoesNotTouchPoolOrFunds(uint8 fault) public {
        fault = uint8(bound(fault, 0, 8));
        SwapRequest memory request = _request(true, true, 1e16);
        if (fault == 0) request.amountSpecified = 0;
        else if (fault == 1) request.amountSpecified = uint128(type(int128).max) + 1;
        else if (fault == 2) request.limitAmount = 0;
        else if (fault == 3) request.deadline = uint64(block.timestamp - 1);
        else if (fault == 4) request.key.fee = 500;
        else if (fault == 5) request.key.tickSpacing = 1;
        else if (fault == 6) request.key.currency0 = Currency.wrap(address(underlying));
        else if (fault == 7) request.key.currency1 = Currency.wrap(address(0));
        else request.key.hooks = IHooks(address(this));
        bytes32 before_ = _digest();
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_digest(), before_);
    }

    function testCallbackRequiresPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        router.unlockCallback(bytes(""));
        _swap(true, true, 1e16);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        router.unlockCallback(bytes(""));
    }

    function testUserReentryDuringPaymentRejects() public {
        underlying.setCallback(address(this), abi.encodeCall(this.assertCallbackIsolation, ()));
        quote.setCallback(address(this), abi.encodeCall(this.assertCallbackIsolation, ()));
        for (uint256 i; i < 4; ++i) {
            _swap(i < 2, i % 2 == 0, 1e16);
            assertEq(router.msgSender(), address(0));
        }
    }

    function testRevertedEntryReleasesLockForNextSwap() public {
        SwapRequest memory request = _request(true, true, 0);
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(router.msgSender(), address(0));
        _swap(true, true, 1e16);
        assertEq(router.msgSender(), address(0));
    }

    function testUpgradeDuringPaymentRejectsAndSucceedsAfterSwap() public {
        nextRouterImplementation = address(new TSVSwapRouterV1(address(manager), address(factory)));
        TSVERC1967Proxy proxy = TSVERC1967Proxy(payable(address(router)));
        address oldImplementation = proxy.tsvImplementation();
        underlying.setCallback(address(this), abi.encodeCall(this.assertUpgradeIsolation, ()));
        _swap(true, true, 1e16);
        assertEq(proxy.tsvImplementation(), oldImplementation);
        assertEq(router.msgSender(), address(0));
        underlying.setCallback(address(0), bytes(""));
        router.upgradeToAndCall(nextRouterImplementation, bytes(""));
        assertEq(proxy.tsvImplementation(), nextRouterImplementation);
        _swap(true, true, 1e16);
    }

    function assertUpgradeIsolation() external {
        require(msg.sender == address(underlying));
        assertEq(router.msgSender(), alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.upgradeToAndCall(nextRouterImplementation, bytes(""));
    }

    function assertCallbackIsolation() external {
        require(msg.sender == address(underlying) || msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInput(_request(true, true, 1e16));
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactOutput(_request(false, false, 1e16));
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        router.unlockCallback(bytes(""));
    }

    function testSyncAndSettleOccurOnceForStockPayment() public {
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(stock)))), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.settle, ()), 1);
        _swap(true, true, 1e16);
    }
}

contract TSVWrappedPrecisionTest is WrappedSwapFixture {
    function _quoteDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _center(PoolKey memory pool) private view returns (int24) {
        return Currency.unwrap(pool.currency0) == address(quote) ? int24(276300) : int24(-276300);
    }

    function _initialPrice(PoolKey memory pool) internal view override returns (uint160) {
        return TickMath.getSqrtPriceAtTick(_center(pool));
    }

    function _seedRange(PoolKey memory pool) internal view override returns (int24, int24) {
        return (_center(pool) - 600, _center(pool) + 600);
    }

    function testMixedDecimalsBothDirectionsExactModesKeepRawAndLegalSharesSeparate() public {
        issuer.setMultiplier(2e18, 1);
        for (uint256 i; i < 4; ++i) {
            bool stockInput = i < 2;
            bool exactInput = i % 2 == 0;
            uint128 amount = stockInput == exactInput ? uint128(1e18) : uint128(1e6);
            uint256 uBefore = underlying.balanceOf(alice);
            uint256 qBefore = quote.balanceOf(alice);
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            (uint256 paid, uint256 received) = _swap(stockInput, exactInput, amount);
            if (!exactInput) assertEq(received, amount);
            assertEq(underlying.balanceOf(alice), stockInput ? uBefore - paid : uBefore + received);
            assertEq(quote.balanceOf(alice), stockInput ? qBefore + received : qBefore - paid);
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, 2 * (stockInput ? paid : received));
            assertEq(_inventory(), 17);
        }
    }
}
