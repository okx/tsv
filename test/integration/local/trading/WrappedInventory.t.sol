// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";
import {V1SwapToken} from "../../../helpers/v1/WrappedSwapMocks.sol";

contract TSVWrappedInventoryTest is WrappedSwapFixture {
    function testFuzzPreexistingUnderlyingBalancesSurviveBothExactInputDirections(
        uint128 pmAmount,
        uint128 routerAmount
    ) public {
        pmAmount = uint128(bound(pmAmount, 1, 1e22));
        routerAmount = uint128(bound(routerAmount, 1, 1e22));
        address donor = makeAddr("uncredentialed-donor");
        underlying.mint(donor, uint256(pmAmount) + routerAmount + 2);
        vm.startPrank(donor);
        underlying.transfer(address(manager), pmAmount);
        underlying.transfer(address(router), routerAmount);
        vm.stopPrank();
        uint256 surplus = _inventory();
        for (uint256 i; i < 2; ++i) {
            bool stockInput = i == 0;
            uint256 uBefore = underlying.balanceOf(alice);
            uint256 qBefore = quote.balanceOf(alice);
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            (uint256 paid, uint256 received) = _swap(stockInput, 1e16);
            assertEq(underlying.balanceOf(alice), stockInput ? uBefore - paid : uBefore + received);
            assertEq(quote.balanceOf(alice), stockInput ? qBefore + received : qBefore - paid);
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockInput ? paid : received);
            _assertUnderlyingBalances(pmAmount, routerAmount, surplus);
        }
        // Each operation captures a fresh baseline, including later ordinary donations.
        vm.startPrank(donor);
        underlying.transfer(address(manager), 1);
        underlying.transfer(address(router), 1);
        vm.stopPrank();
        _swap(true, 1e16);
        _assertUnderlyingBalances(uint256(pmAmount) + 1, uint256(routerAmount) + 1, surplus);
    }

    function testFuzzUnderlyingBalanceChangeDuringSwapRollsBack(bool pmRecipient, bool stockInput, bool underlyingHook)
        public
    {
        underlying.mint(address(manager), 31);
        underlying.mint(address(router), 43);
        V1SwapToken callbackToken = underlyingHook ? underlying : quote;
        callbackToken.setCallback(
            address(underlying),
            abi.encodeCall(V1SwapToken.mint, (pmRecipient ? address(manager) : address(router), uint256(1)))
        );
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(stockInput, 1e16);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
        callbackToken.setCallback(address(0), bytes(""));
        _swap(stockInput, 1e16);
        _assertUnderlyingBalances(31, 43, 17);
    }

    function testFuzzPreexistingUnderlyingCannotCoverShortPayment(bool stockInput, uint128 balance) public {
        balance = uint128(bound(balance, 1, 1e22));
        underlying.mint(address(manager), balance);
        underlying.mint(address(router), balance);
        (stockInput ? underlying : quote).setTransferMode(3);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(stockInput, 1e16);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }

    function _assertUnderlyingBalances(uint256 pmAmount, uint256 routerAmount, uint256 surplus) private view {
        assertEq(underlying.balanceOf(address(manager)), pmAmount);
        assertEq(underlying.balanceOf(address(router)), routerAmount);
        assertEq(stock.balanceOf(address(manager)), stock.totalSupply());
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(stock.balanceOf(alice), 0);
        assertEq(_inventory(), surplus);
        assertEq(router.msgSender(), address(0));
    }
}
