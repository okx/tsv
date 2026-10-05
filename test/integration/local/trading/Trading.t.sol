// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1TestParticipantWallet, V1TestExternalAdapter} from "../../../helpers/v1/LocalMocks.sol";

/// @dev TSVTradingLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVTradingLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testMissingAdtvAllowsLiquidityButSwapRevertsAtomically() public {
        uint32 day = 20261101;
        vm.warp(ledger.dayStartUTC(day) + 1);
        (bool valid,) = ledger.remaining(SECURITY, day);
        assertFalse(valid);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, _pauseTestBounds());
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        bytes32 beforeState = _swapStateDigest(day);
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(TSVVolumeLedgerV1.MissingReport.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
        uint64 now_ = uint64(block.timestamp);
        inbox.submitAdtv(AdtvReport(SECURITY, 202610, 1e24, now_ - 1, now_ + 100, 1, 2, keccak256("nov-adtv")));
        vm.prank(alice);
        router.swapExactInput(request);
        assertGt(ledger.used(SECURITY, day), 0);
    }

    /// @dev Verifies a real V4 pool swap accounts for the actual deltas.
    function testRealV4OnePoolSwapAccountsActualDelta() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint160(address(hook)) & uint160(0x3FFF), uint160(0x3FFF));
        assertEq(lpManager.ownerOf(positionId), alice);
        assertTrue(registry.isTradable(poolId));
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        uint256 used = ledger.used(SECURITY, DAY) - beforeUsed;
        assertEq(used, actualIn);
    }

    /// @dev Verifies an allowlisted Adapter uses the shared request for both directions and settles to itself.
    function testAllowlistedAdapterUsesSharedSwapRequestBothDirections() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        _runAdapterSwap(adapter, stockIsCurrency0);
        _runAdapterSwap(adapter, !stockIsCurrency0);
    }

    /// @dev Verifies the Adapter entry rejects callers outside the Router allowlist.
    function testAdapterEntryRejectsUnallowlistedCaller() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        router.swapExactInputFromAdapter(request, alice);
    }

    /// @dev Verifies an allowlisted Adapter cannot use an ineligible participant identity.
    function testAllowlistedAdapterRequiresEligibleParticipant() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        bool zeroForOne = address(stock) == Currency.unwrap(key.currency0);
        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        vm.prank(alice);
        IERC20(inputToken).transfer(address(adapter), 1e18);
        adapter.approveToken(inputToken, address(router));

        SwapRequest memory request = _swapRequest(zeroForOne, 1e18);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        adapter.swapExactInput(router, request, makeAddr("ineligible"));
    }

    /// @dev Verifies real V4 stock output records the net amount received.
    function testRealV4StockOutputCountsNetReceived() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(!stockIsCurrency0, 1e18);
        vm.prank(alice);
        (, uint256 actualOut) = router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), actualOut);
    }

    /// @dev Verifies swaps revert when the payer loses more than the raw input delta.
    function testSwapRevertsIfPayerLosesMoreThanRawDelta() public {
        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        quote.setSenderFee(alice, 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(quoteIsCurrency0, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    /// @dev Verifies swaps revert when the pool loses more than the output delta.
    function testSwapRevertsIfPoolLosesMoreThanOutputDelta() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        quote.setSenderFee(address(manager), 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    /// @dev Verifies swaps require an eligible direct caller.
    function testSwapRequiresEligibleDirectCaller() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        router.swapExactInput(request);

        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies an eligible contract wallet can submit a swap directly.
    function testContractWalletCanDirectlySubmitSwap() public {
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.approveToken(address(stock), address(router));
        wallet.approveToken(address(quote), address(router));

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        (uint256 actualIn, uint256 actualOut) = wallet.swapExactInput(router, request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies backed stock swaps in both directions use live issuer conversion.
    function testBackedStockSwapBothWaysUsesLiveIssuerConversion() public {
        uint256 aliceRawBeforeUpdate = stock.balanceOf(alice);
        uint256 managerRawBeforeUpdate = stock.balanceOf(address(manager));
        stockUnderlying.setMultiplier(2e18, 1);
        assertEq(stock.balanceOf(alice), aliceRawBeforeUpdate);
        assertEq(stock.balanceOf(address(manager)), managerRawBeforeUpdate);
        assertEq(_displayBalance(alice), aliceRawBeforeUpdate * 2);
        assertEq(_displayBalance(address(manager)), managerRawBeforeUpdate * 2);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        (uint256 stockIn, uint256 quoteOut) = router.swapExactInput(_swapRequest(stockIsCurrency0, 1e18));
        assertGt(stockIn, 0);
        assertGt(quoteOut, 0);
        assertEq(aliceRawBefore - stock.balanceOf(alice), stockIn);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockIn * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactInput(_swapRequest(!stockIsCurrency0, 1e18));
        assertGt(quoteIn, 0);
        assertGt(stockOut, 0);
        assertEq(stock.balanceOf(alice) - aliceRawBefore, stockOut);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    /// @dev Verifies exact-output swaps deliver the full requested amount.
    function testExactOutputRequiresFullDelivery() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockIsCurrency0, 1e18);
        request.limitAmount = 2e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
        assertEq(actualOut, 1e18);
        assertLe(actualIn, 2e18);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, actualIn);
    }

    /// @dev Verifies exact-output stock purchases record net shares received.
    function testExactOutputStockPurchaseRecordsNetShares() public {
        stockUnderlying.setMultiplier(2e18, 1);

        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(quoteIsCurrency0, 1e18);
        request.limitAmount = 2e18;
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 displayedBefore = _displayBalance(alice);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactOutput(request);

        assertLe(quoteIn, request.limitAmount);
        assertEq(stockOut, request.amountSpecified);
        assertEq(quoteBefore - quote.balanceOf(alice), quoteIn);
        assertEq(stock.balanceOf(alice) - stockBefore, stockOut);
        assertEq(_displayBalance(alice) - displayedBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    /// @dev Verifies direct PoolManager swaps cannot bypass the Hook.
    function testDirectPoolManagerSwapCannotBypassHook() public {
        vm.expectRevert();
        manager.unlock(abi.encode(key));
        assertEq(ledger.used(SECURITY, DAY), 0);
    }
}
