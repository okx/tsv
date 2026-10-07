// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

/// @dev Used only to alter the first callback payload; never used for successful swap funding.
contract V1CorruptCallbackPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(bytes.concat(data, hex"ff"));
    }
}

contract TSVWrappedBoundariesTest is WrappedSwapFixture {
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

    function testCallbackRequiresPoolManagerAndActiveOperation() public {
        vm.expectRevert();
        router.unlockCallback(bytes(""));
        vm.expectRevert(TSVSwapRouterV1.InvalidCallbackContext.selector);
        vm.prank(address(manager));
        router.unlockCallback(bytes(""));
        _swap(true, true, 1e16);
        vm.expectRevert(TSVSwapRouterV1.InvalidCallbackContext.selector);
        vm.prank(address(manager));
        router.unlockCallback(bytes(""));
    }

    function testCorruptedPayloadAndMissingCallbackRejectBeforeFunding() public {
        bytes32 before_ = _digest();
        bytes memory original = address(manager).code;
        vm.etch(address(manager), address(new V1CorruptCallbackPoolManager()).code);
        vm.expectRevert(TSVSwapRouterV1.InvalidCallbackContext.selector);
        _swap(true, true, 1e16);
        vm.etch(address(manager), original);
        assertEq(_digest(), before_);
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), abi.encode(bytes("")));
        vm.expectRevert(TSVSwapRouterV1.InvalidCallbackContext.selector);
        _swap(true, true, 1e16);
        vm.clearMockedCalls();
        assertEq(_digest(), before_);
        _swap(true, true, 1e16);
    }

    function testDuplicateCallbackAndUserReentryDuringPaymentReject() public {
        underlying.setCallback(address(this), abi.encodeCall(this.assertCallbackIsolation, ()));
        _swap(true, true, 1e16);
        assertEq(router.msgSender(), address(0));
        _swap(true, true, 1e16);
    }

    /// @dev Sender impersonation isolates the consumed-callback guard; successful swaps still use real PM.
    function assertCallbackIsolation() external {
        require(msg.sender == address(underlying));
        assertEq(router.msgSender(), alice);
        vm.expectRevert(TSVSwapRouterV1.Reentrancy.selector);
        router.swapExactInput(_request(true, true, 1e16));
        vm.expectRevert(TSVSwapRouterV1.InvalidCallbackContext.selector);
        vm.prank(address(manager));
        router.unlockCallback(bytes(""));
    }

    function testMismatchedSettlePaidRevertsAndSyncAndSettleOccurOnce() public {
        bytes32 before_ = _digest();
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector), abi.encode(uint256(0)));
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(true, true, 1e16);
        vm.clearMockedCalls();
        assertEq(_digest(), before_);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(stock)))), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.settle, ()), 1);
        _swap(true, true, 1e16);
    }

    function testExactOutputOverDeliveryCannotRelaxStrictEquality() public {
        SwapRequest memory request = _request(false, false, 1e16);
        uint256 input = 2e16;
        uint256 output = 1e16 + 1;
        Currency inputCurrency = request.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = request.zeroForOne ? key.currency1 : key.currency0;
        BalanceDelta delta = toBalanceDelta(
            request.zeroForOne ? -int128(int256(input)) : int128(int256(output)),
            request.zeroForOne ? int128(int256(output)) : -int128(int256(input))
        );
        bytes32 before_ = _digest();
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
        vm.mockCall(
            address(manager),
            abi.encodeWithSignature(
                "exttload(bytes32)", keccak256(abi.encode(address(router), Currency.unwrap(inputCurrency)))
            ),
            abi.encode(bytes32(uint256(-int256(input))))
        );
        vm.mockCall(
            address(manager),
            abi.encodeWithSignature(
                "exttload(bytes32)", keccak256(abi.encode(address(router), Currency.unwrap(outputCurrency)))
            ),
            abi.encode(bytes32(output))
        );
        vm.expectRevert(TSVSwapRouterV1.SlippageExceeded.selector);
        vm.prank(alice);
        router.swapExactOutput(request);
        vm.clearMockedCalls();
        assertEq(_digest(), before_);
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
