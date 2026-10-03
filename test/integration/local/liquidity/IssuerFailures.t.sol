// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVIssuerLPFailuresTest is ProtocolFixture {
    function testRefusalOnEitherExitLegPreservesPositionFeesReceiptAndCanRetry() public {
        _seedPauseTestFees();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(quote) == Currency.unwrap(key.currency0), 1e18));
        // Each currency separately faults: this covers a failure on the first and second settlement leg.
        for (uint8 currency; currency < 2; currency++) {
            address token = Currency.unwrap(currency == 0 ? key.currency0 : key.currency1);
            vm.mockCallRevert(
                token,
                abi.encodeWithSelector(IERC20.transfer.selector, alice),
                abi.encodeWithSignature("Error(string)", "issuer refused owner")
            );
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.collectFees(positionId, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.decreaseLiquidity(positionId, 1e18, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.closePosition(positionId, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            sbt.setHolder(alice, false);
            vm.expectRevert();
            lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
            assertEq(_swapStateDigest(DAY), beforeState);
            sbt.setHolder(alice, true);
            vm.clearMockedCalls();
        }
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
    }
}
