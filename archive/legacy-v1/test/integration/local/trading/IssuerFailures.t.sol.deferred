// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Wrapped-stock issuer refusal is independent of the legal-share conversion source.
contract TSVIssuerSwapFailuresTest is ProtocolFixture {
    function testWrappedStockRefusalRollsBackBothSettlementDirectionsAndCanRetry() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.mockCallRevert(
            address(stock),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encodeWithSignature("Error(string)", "issuer refused transferFrom")
        );
        vm.mockCallRevert(
            address(stock),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encodeWithSignature("Error(string)", "issuer refused recipient")
        );
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(i == 0, 1e18);
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
        vm.clearMockedCalls();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18));
    }
}
