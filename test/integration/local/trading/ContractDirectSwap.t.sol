// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVContractDirectSwapTest is WrappedSwapFixture {
    function testStockInputUsesWPrefundingWithoutAnotherTransfer() public {
        uint128 amount = 1e16;
        vm.prank(alice);
        underlying.transfer(address(stock), amount);
        uint256 aliceBefore = underlying.balanceOf(alice);
        uint256 backingBefore = underlying.balanceOf(address(stock));
        uint256 supplyBefore = stock.totalSupply();
        address recipient = address(swapAdapter);
        // Even a failing transfer implementation cannot affect this entry's already funded U input.
        underlying.setTransferMode(2);
        (uint256 paid, uint256 received) =
            swapAdapter.swapExactInputDirect(router, _request(true, amount), address(0), alice, recipient);
        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(quote.balanceOf(recipient), received);
        assertEq(underlying.balanceOf(alice), aliceBefore);
        assertEq(underlying.balanceOf(address(swapAdapter)), 0);
        assertEq(underlying.balanceOf(address(stock)), backingBefore);
        assertEq(stock.totalSupply(), supplyBefore + amount);
        assertEq(_inventory(), 17);
    }

    function testStockOutputMustGoToParticipant() public {
        uint128 amount = 1e16;
        quote.mint(address(swapAdapter), amount);
        swapAdapter.approveToken(address(quote), address(router));
        SwapRequest memory request = _request(false, amount);
        bytes32 beforeState = _digest();

        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        swapAdapter.swapExactInputDirect(router, request, address(swapAdapter), alice, address(swapAdapter));

        assertEq(_digest(), beforeState);
        assertEq(router.msgSender(), address(0));
    }

    function testQuoteOutputMayGoToParticipant() public {
        uint128 amount = 1e16;
        vm.prank(alice);
        underlying.transfer(address(stock), amount);
        uint256 quoteBefore = quote.balanceOf(alice);

        (uint256 paid, uint256 received) =
            swapAdapter.swapExactInputDirect(router, _request(true, amount), address(0), alice, alice);

        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(quote.balanceOf(alice), quoteBefore + received);
    }

    function testQuoteOutputRejectsUnrelatedRecipient() public {
        uint128 amount = 1e16;
        vm.prank(alice);
        underlying.transfer(address(stock), amount);
        SwapRequest memory request = _request(true, amount);
        bytes32 beforeState = _digest();

        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        swapAdapter.swapExactInputDirect(
            router, request, address(0), alice, makeAddr("unrelated-quote-recipient")
        );

        assertEq(_digest(), beforeState);
        assertEq(router.msgSender(), address(0));
    }

    function testQuoteInputPaysStockOutputToParticipant() public {
        uint128 amount = 1e16;
        quote.mint(address(swapAdapter), amount + 123);
        quote.mint(address(router), 77);
        swapAdapter.approveToken(address(quote), address(router));
        uint256 underlyingBefore = underlying.balanceOf(alice);
        uint256 aliceBefore = quote.balanceOf(alice);
        (uint256 paid, uint256 received) =
            swapAdapter.swapExactInputDirect(
                router, _request(false, amount), address(swapAdapter), alice, alice
            );
        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(quote.balanceOf(address(swapAdapter)), 123);
        assertEq(quote.balanceOf(alice), aliceBefore);
        assertEq(quote.balanceOf(address(router)), 77);
        assertEq(underlying.balanceOf(alice), underlyingBefore + received);
        assertEq(underlying.balanceOf(address(swapAdapter)), 0);
        assertEq(_inventory(), 17);
        assertFalse(registry.hasCredential(address(swapAdapter)));
    }

    function testQuoteInputCannotUseParticipantBalanceOrApproval() public {
        vm.prank(alice);
        quote.approve(address(router), type(uint256).max);
        swapAdapter.approveToken(address(quote), address(router));
        SwapRequest memory request = _request(false, 1e16);
        bytes32 beforeState = _digest();
        vm.expectRevert();
        swapAdapter.swapExactInputDirect(router, request, address(swapAdapter), alice, alice);
        assertEq(_digest(), beforeState);
        assertEq(quote.balanceOf(address(swapAdapter)), 0);
        assertEq(router.msgSender(), address(0));
    }

    function testStockInputRejectsInsufficientWPrefunding() public {
        SwapRequest memory request = _request(true, 1e16);
        bytes32 beforeState = _digest();
        vm.expectRevert();
        swapAdapter.swapExactInputDirect(router, request, address(0), alice, alice);
        assertEq(_digest(), beforeState);
        assertEq(_inventory(), 17);
        assertEq(router.msgSender(), address(0));
    }

    function testRevertedStockSwapPreservesAlreadyDepositedU() public {
        vm.prank(alice);
        underlying.transfer(address(stock), 1e16);
        _setQuota(0);
        SwapRequest memory request = _request(true, 1e16);
        bytes32 beforeState = _digest();
        vm.expectRevert();
        swapAdapter.swapExactInputDirect(router, request, address(0), alice, alice);
        assertEq(_digest(), beforeState);
        assertEq(_inventory(), 1e16 + 17);
        assertEq(router.msgSender(), address(0));
    }

    function testDirectQuotePaymentLocksBothEntryPoints() public {
        quote.mint(address(swapAdapter), 1e16);
        swapAdapter.approveToken(address(quote), address(router));
        quote.setCallback(address(this), abi.encodeCall(this.assertDirectLock, ()));
        swapAdapter.swapExactInputDirect(
            router, _request(false, 1e16), address(swapAdapter), alice, alice
        );
        assertEq(router.msgSender(), address(0));
    }

    function assertDirectLock() external {
        require(msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        SwapRequest memory request = _request(false, 1e16);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInputFromContractDirect(request, address(this), alice, alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInputFromContract(request, alice);
    }
}
