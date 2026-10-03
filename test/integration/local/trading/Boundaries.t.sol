// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1TestExternalAdapter} from "../../../helpers/v1/LocalMocks.sol";

/// @dev Real V4 swaps: request bounds, actual delivery, and complete rollback.
contract TSVTradingBoundariesTest is ProtocolFixture {
    function testFuzzInvalidAmountIsRejectedBeforeSettlement(uint128 amount, bool exactInput) public {
        amount = amount == 0 ? 0 : uint128(bound(amount, uint256(uint128(type(int128).max)) + 1, type(uint128).max));
        SwapRequest memory request = _swapRequest(true, amount);
        bytes32 beforeState = _swapStateDigest(DAY);
        _reject(request, exactInput, TSVSwapRouterV1.InvalidRequest.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testZeroAmountAndZeroLimitRejectBothModes() public {
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(true, i == 0 ? 0 : 1e18);
            if (i == 1) request.limitAmount = 0;
            _reject(request, true, TSVSwapRouterV1.InvalidRequest.selector);
            _reject(request, false, TSVSwapRouterV1.InvalidRequest.selector);
        }
    }

    function testExpiredRequestRollsBackBothModes() public {
        SwapRequest memory request = _swapRequest(true, 1e18);
        request.deadline = uint64(block.timestamp - 1);
        bytes32 beforeState = _swapStateDigest(DAY);
        _reject(request, true, TSVSwapRouterV1.Expired.selector);
        _reject(request, false, TSVSwapRouterV1.Expired.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testDeadlineIsInclusiveAndSameRequestCanTradeAgain() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e16);
        request.deadline = uint64(block.timestamp);
        vm.startPrank(alice);
        (uint256 first,) = router.swapExactInput(request);
        (uint256 second,) = router.swapExactInput(request);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), first + second);
        _assertNoRouterBalances();
    }

    function testUnknownOrChangedPoolKeyRejectedAtomically() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 5; i++) {
            SwapRequest memory request = _swapRequest(true, 1e18);
            if (i == 0) request.key.fee++;
            if (i == 1) request.key.tickSpacing += 60;
            if (i == 2) request.key.hooks = IHooks(address(0));
            if (i == 3) (request.key.currency0, request.key.currency1) = (key.currency1, key.currency0);
            if (i == 4) request.key.currency0 = Currency.wrap(makeAddr("unknown-currency"));
            _reject(request, true, TSVSwapRouterV1.InvalidPool.selector);
            _reject(request, false, TSVSwapRouterV1.InvalidPool.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
    }

    function testExactOutputBothDirectionsDeliversExactlyAndCountsActualStockLeg() public {
        stockUnderlying.setMultiplier(9e17, 1);
        for (uint8 i; i < 2; i++) {
            bool stockInput = i == 0;
            bool direction = stockInput == (address(stock) == Currency.unwrap(key.currency0));
            SwapRequest memory request = _swapRequest(direction, 1e16);
            request.limitAmount = 1e19;
            IERC20 input = IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1));
            IERC20 output = IERC20(Currency.unwrap(direction ? key.currency1 : key.currency0));
            uint256 inputBefore = input.balanceOf(alice);
            uint256 outputBefore = output.balanceOf(alice);
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            vm.prank(alice);
            (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
            assertEq(actualOut, request.amountSpecified);
            assertEq(inputBefore - input.balanceOf(alice), actualIn);
            assertEq(output.balanceOf(alice) - outputBefore, actualOut);
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, (stockInput ? actualIn : actualOut) * 9 / 10);
        }
        _assertNoRouterBalances();
    }

    function testBothDirectionsSlippageRollsBackAndCanRetry() public {
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(i == 0, 1e16);
            bytes32 beforeState = _swapStateDigest(DAY);
            request.limitAmount = type(uint128).max;
            _reject(request, true, TSVSwapRouterV1.SlippageExceeded.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
            request.limitAmount = 1;
            _reject(request, false, TSVSwapRouterV1.SlippageExceeded.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
            request.limitAmount = 1;
            vm.prank(alice);
            router.swapExactInput(request);
        }
    }

    function testPartialExactInputChargesOnlyConsumedAmount() public {
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(direction, 1e22);
        uint256 beforeStock = stock.balanceOf(alice);
        bytes32 beforeState = _swapStateDigest(DAY);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertLt(actualIn, request.amountSpecified);
        assertGt(actualOut, 0);
        assertEq(beforeStock - stock.balanceOf(alice), actualIn);
        assertEq(ledger.used(SECURITY, DAY), actualIn);
        _assertNoRouterBalances();
        vm.revertToState(snapshot);
        request.limitAmount = uint128(actualOut + 1);
        _reject(request, true, TSVSwapRouterV1.SlippageExceeded.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
        request.limitAmount = uint128(actualOut);
        vm.prank(alice);
        (uint256 retriedIn, uint256 retriedOut) = router.swapExactInput(request);
        assertEq(retriedIn, actualIn);
        assertEq(retriedOut, actualOut);
    }

    function testCallbackRequiresManagerAndActiveSwap() public {
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        router.unlockCallback("");
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(address(manager));
        router.unlockCallback("");
    }

    function testSourceConversionFailureOrZeroRollsBackEntireV4Swap() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        bytes32 beforeState = _swapStateDigest(DAY);
        stockUnderlying.setMultiplier(0, 1);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        stockUnderlying.setMultiplier(1e18, 2);
        vm.mockCallRevert(
            address(stockUnderlying), abi.encodeWithSignature("getUnderlyingAmountByShares(uint256)"), "source offline"
        );
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testAllowanceFailureRollsBackPoolAndQuotaAndCanRetry() public {
        bool direction = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(direction, 1e18);
        vm.prank(alice);
        quote.approve(address(router), 0);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.prank(alice);
        quote.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testAdapterRevocationStopsNextSwapIncludingCodeRemovedAdapter() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        router.setAdapterAllowed(address(adapter), false);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        adapter.swapExactInput(router, _swapRequest(true, 1e18), alice);
        router.setAdapterAllowed(address(adapter), true);
        vm.etch(address(adapter), "");
        router.setAdapterAllowed(address(adapter), false);
        assertFalse(router.isAdapterAllowed(address(adapter)));
    }

    function testInvalidAdapterAndUnauthorizedAllowlistChanges() public {
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(address(0), false);
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(alice, true);
        vm.expectRevert();
        vm.prank(alice);
        router.setAdapterAllowed(address(quote), true);
        assertFalse(router.isAdapterAllowed(address(quote)));
    }

    function _reject(SwapRequest memory request, bool exactInput, bytes4 errorSelector) internal {
        vm.expectRevert(errorSelector);
        vm.prank(alice);
        if (exactInput) router.swapExactInput(request);
        else router.swapExactOutput(request);
    }

    function _assertNoRouterBalances() internal view {
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }
}
