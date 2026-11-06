// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolLifecycle, SecurityPauseMode, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVDisabledQuoteDirectSwapTest is WrappedSwapFixture {
    using PoolIdLibrary for PoolKey;

    function testDisabledQuoteDirectSellPaysParticipant() public {
        _assertDisabledQuoteSell(alice);
    }

    function testDisabledQuoteDirectSellPaysAllowedAdapter() public {
        _assertDisabledQuoteSell(address(swapAdapter));
    }

    function testDisabledQuoteDirectBuyStillPaysUnderlyingToParticipant() public {
        _disableQuote();
        uint128 amount = 1e16;
        quote.mint(address(swapAdapter), amount);
        swapAdapter.approveToken(address(quote), address(router));
        uint256 beforeBalance = underlying.balanceOf(alice);

        (uint256 paid, uint256 received) =
            swapAdapter.swapExactInputDirect(router, _request(false, amount), address(swapAdapter), alice, alice);

        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(underlying.balanceOf(alice), beforeBalance + received);
        assertEq(quote.balanceOf(address(swapAdapter)), 0);
        assertEq(router.msgSender(), address(0));
    }

    function testDisabledQuoteRejectsUnrelatedQuoteRecipient() public {
        _disableQuote();
        _expectSellRevert(TSVSwapRouterV1.InvalidRequest.selector, makeAddr("unrelated-recipient"));
    }

    function testDisabledQuoteStockOutputStillCannotGoToAdapter() public {
        _disableQuote();
        SwapRequest memory request = _request(false, 1e16);
        bytes32 beforeState = _digest();

        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        swapAdapter.swapExactInputDirect(router, request, address(swapAdapter), alice, address(swapAdapter));

        assertEq(_digest(), beforeState);
    }

    function testDisabledQuoteUnknownPoolStillRejected() public {
        _disableQuote();
        SwapRequest memory request = _request(true, 1e16);
        request.key.fee = 500;
        assertFalse(registry.isKnownPool(PoolId.unwrap(request.key.toId())));
        bytes32 beforeState = _digest();

        vm.expectRevert(TSVSwapRouterV1.PoolNotTradable.selector);
        swapAdapter.swapExactInputDirect(router, request, address(0), alice, alice);

        assertEq(_digest(), beforeState);
    }

    function testDisabledQuotePausedPoolStillRejected() public {
        _disableQuote();
        registry.updatePoolLifeCycle(PoolId.unwrap(key.toId()), PoolLifecycle.PAUSE, bytes32("TEST"));
        _expectSellRevert(TSVSwapRouterV1.PoolNotTradable.selector, alice);
    }

    function testDisabledQuoteDelistedPoolStillRejected() public {
        _disableQuote();
        registry.updatePoolLifeCycle(PoolId.unwrap(key.toId()), PoolLifecycle.DELIST, bytes32("TEST"));
        _expectSellRevert(TSVSwapRouterV1.PoolNotTradable.selector, alice);
    }

    function testDisabledQuoteSecurityTradePauseStillRejected() public {
        _disableQuote();
        _setSecurityMode(SecurityPauseMode.TRADE, true);
        _expectSellRevert(TSVSwapRouterV1.PoolNotTradable.selector, alice);
    }

    function testDisabledQuoteRevokedAdapterStillRejected() public {
        _disableQuote();
        router.setAdapterAllowed(address(swapAdapter), false);
        _expectSellRevert(TSVSwapRouterV1.AdapterNotAllowed.selector, alice);
    }

    function testDisabledQuoteStillCannotRegisterNewPool() public {
        _disableQuote();
        PoolKey memory newKey = key;
        newKey.fee = 500;

        vm.prank(address(seed));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPool(newKey);

        assertFalse(registry.isKnownPool(PoolId.unwrap(newKey.toId())));
        assertTrue(registry.isTradable(PoolId.unwrap(key.toId())));
    }

    function _disableQuote() private {
        registry.disableQuoteTokenPoolRegister(address(quote), bytes32("TEST"));
        assertFalse(registry.getQuoteToken(address(quote)).registered);
        assertTrue(registry.isTradable(PoolId.unwrap(key.toId())));
    }

    function _assertDisabledQuoteSell(address recipient) private {
        _disableQuote();
        uint128 amount = 1e16;
        vm.prank(alice);
        underlying.transfer(address(stock), amount);
        uint256 beforeBalance = quote.balanceOf(recipient);
        uint256 usedBefore = ledger.usedWad(SECURITY, DAY);

        (uint256 paid, uint256 received) =
            swapAdapter.swapExactInputDirect(router, _request(true, amount), address(0), alice, recipient);

        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(quote.balanceOf(recipient), beforeBalance + received);
        assertGt(ledger.usedWad(SECURITY, DAY), usedBefore);
        assertEq(_inventory(), 17);
        assertEq(router.msgSender(), address(0));
    }

    function _expectSellRevert(bytes4 errorSelector, address recipient) private {
        SwapRequest memory request = _request(true, 1e16);
        bytes32 beforeState = _digest();

        vm.expectRevert(errorSelector);
        swapAdapter.swapExactInputDirect(router, request, address(0), alice, recipient);

        assertEq(_digest(), beforeState);
        assertEq(router.msgSender(), address(0));
    }
}
