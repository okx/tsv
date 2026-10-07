// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Fault injection on LP funding, fee collection, closure, and forced exit.
contract TSVLiquiditySettlementTest is ProtocolFixture {
    function testFaultyTransferRollsBackAllOrdinaryLPActions() public {
        _seedPauseTestFees();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(quote) == Currency.unwrap(key.currency0), 1e18));
        for (uint8 fault = 1; fault <= 3; fault++) {
            quote.setTransferMode(fault);
            for (uint8 action; action < 5; action++) {
                bytes32 beforeState = _swapStateDigest(DAY);
                vm.expectRevert();
                vm.prank(alice);
                _operate(action);
                assertEq(_swapStateDigest(DAY), beforeState);
                assertEq(lpManager.nextPositionId(), 2);
            }
        }
        quote.setTransferMode(0);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
    }

    function testForcedExitTokenFaultRollsBackAndCanRetry() public {
        sbt.setHolder(alice, false);
        for (uint8 fault = 1; fault <= 3; fault++) {
            quote.setTransferMode(fault);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert();
            lpManager.forceExit(positionId, 0, 0, keccak256("revoke"));
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setTransferMode(0);
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
        _assertNoPeripheryBalances();
    }

    function testNoReturnTokenSupportsCompleteLPLifecycle() public {
        quote.setTransferMode(4);
        vm.startPrank(alice);
        uint256 id = lpManager.openPosition(key, -600, 600, 1e19, _pauseTestBounds());
        lpManager.increaseLiquidity(id, 1e18, _pauseTestBounds());
        lpManager.decreaseLiquidity(id, 1e18, _pauseTestBounds());
        vm.stopPrank();
        _seedPauseTestFees();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        lpManager.collectFees(id, _pauseTestBounds());
        lpManager.closePosition(id, _pauseTestBounds());
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.balanceOf(alice), 1);
        _assertNoPeripheryBalances();
    }

    function testTokenReentryRejectsEveryLPEntryAndRollsBack() public {
        LPBounds memory b = _pauseTestBounds();
        for (uint8 i; i < 6; i++) {
            bytes memory data;
            if (i == 0) data = abi.encodeCall(TSVLPManagerV1.openPosition, (key, -600, 600, 1e18, b));
            if (i == 1) data = abi.encodeCall(TSVLPManagerV1.increaseLiquidity, (positionId, 1e18, b));
            if (i == 2) data = abi.encodeCall(TSVLPManagerV1.decreaseLiquidity, (positionId, 1e18, b));
            if (i == 3) data = abi.encodeCall(TSVLPManagerV1.collectFees, (positionId, b));
            if (i == 4) data = abi.encodeCall(TSVLPManagerV1.closePosition, (positionId, b));
            if (i == 5) {
                data = abi.encodeCall(TSVLPManagerV1.forceExit, (positionId, 0, 0, keccak256("reason")));
            }
            quote.setCallback(address(lpManager), data);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert(TSVLPManagerV1.Reentrancy.selector);
            vm.prank(alice);
            lpManager.increaseLiquidity(positionId, 1e18, b);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setCallback(address(0), "");
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, b);
    }

    function testInsufficientAllowanceRollsBackOpenAndIncreaseThenRetry() public {
        vm.prank(alice);
        quote.approve(address(lpManager), 0);
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 2; i++) {
            vm.expectRevert();
            vm.prank(alice);
            _operate(i);
            assertEq(_swapStateDigest(DAY), beforeState);
            assertEq(lpManager.nextPositionId(), 2);
        }
        vm.prank(alice);
        quote.approve(address(lpManager), type(uint256).max);
        vm.prank(alice);
        _operate(1);
    }

    function _operate(uint8 action) internal {
        LPBounds memory b = _pauseTestBounds();
        if (action == 0) lpManager.openPosition(key, -600, 600, 1e18, b);
        else if (action == 1) lpManager.increaseLiquidity(positionId, 1e18, b);
        else if (action == 2) lpManager.decreaseLiquidity(positionId, 1e18, b);
        else if (action == 3) lpManager.collectFees(positionId, b);
        else lpManager.closePosition(positionId, b);
    }

    function _assertNoPeripheryBalances() internal view {
        assertEq(stock.balanceOf(address(lpManager)), 0);
        assertEq(quote.balanceOf(address(lpManager)), 0);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }
}
