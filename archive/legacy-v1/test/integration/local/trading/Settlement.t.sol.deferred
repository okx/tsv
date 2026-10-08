// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Token faults must undo the hook accounting, V4 price/fees, and all transfers.
contract TSVTradingSettlementTest is ProtocolFixture {
    function testTaxFalseAndShortTransfersRollbackBothSwapDirections() public {
        for (uint8 mode = 1; mode <= 3; mode++) {
            quote.setTransferMode(mode);
            for (uint8 direction; direction < 2; direction++) {
                bytes32 beforeState = _swapStateDigest(DAY);
                SwapRequest memory request = _swapRequest(direction == 0, 1e18);
                vm.expectRevert();
                vm.prank(alice);
                router.swapExactInput(request);
                assertEq(_swapStateDigest(DAY), beforeState);
                request.limitAmount = 1e20;
                vm.expectRevert();
                vm.prank(alice);
                router.swapExactOutput(request);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        quote.setTransferMode(0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(true, 1e18));
    }

    function testExactSettlementSupportsTokensWithoutReturnData() public {
        quote.setTransferMode(4);
        for (uint8 i; i < 2; i++) {
            vm.prank(alice);
            (uint256 input, uint256 output) = router.swapExactInput(_swapRequest(i == 0, 1e17));
            assertGt(input, 0);
            assertGt(output, 0);
        }
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }

    function testTokenCallbackCannotReenterEitherSwapEntryAndStateCanRecover() public {
        SwapRequest memory request = _swapRequest(true, 1e18);
        for (uint8 i; i < 3; i++) {
            bytes memory data = i == 0
                ? abi.encodeCall(TSVSwapRouterV1.swapExactInput, (request))
                : i == 1
                    ? abi.encodeCall(TSVSwapRouterV1.swapExactOutput, (request))
                    : abi.encodeCall(TSVSwapRouterV1.swapExactInputFromAdapter, (request, alice));
            quote.setCallback(address(router), data);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert(TSVSwapRouterV1.Reentrancy.selector);
            vm.prank(alice);
            router.swapExactInput(request);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setCallback(address(0), "");
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testBlockedOutputRecipientRollsBackThenUnblockedSwapSucceeds() public {
        quote.setBlockedRecipient(alice);
        bytes32 beforeState = _swapStateDigest(DAY);
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        quote.setBlockedRecipient(address(0));
        vm.prank(alice);
        router.swapExactInput(request);
    }
}
