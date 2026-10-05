// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev LP input/ownership bounds and fee lifecycle with a real PoolManager.
contract TSVLiquidityBoundariesTest is ProtocolFixture {
    function testInvalidLiquidityAtOpenIncreaseAndDecreaseIsAtomic() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        LPBounds memory b = _pauseTestBounds();
        uint128[3] memory amounts = [uint128(0), uint128(type(int128).max) + 1, type(uint128).max];
        for (uint8 i; i < 3; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.openPosition(key, -600, 600, amounts[i], b);
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.increaseLiquidity(positionId, amounts[i], b);
        }
        uint128[3] memory decreases = [uint128(0), uint128(1e20), uint128(1e20 + 1)];
        for (uint8 i; i < 3; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.decreaseLiquidity(positionId, decreases[i], b);
        }
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, uint128(type(int128).max), b);
        assertEq(_swapStateDigest(DAY), beforeState);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testFuzzInvalidTicksDoNotAllocateReceipt(int24 tick, bool badUpper) public {
        tick = int24(bound(int256(tick), -887000, 887000));
        if (tick % 60 == 0) tick++;
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.openPosition(
            key, badUpper ? int24(-887220) : tick, badUpper ? tick : int24(887220), 1e18, _pauseTestBounds()
        );
        assertEq(_swapStateDigest(DAY), beforeState);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testTickOrderAndExtremeTicksReject() public {
        int24[4] memory lower = [int24(60), int24(60), int24(-887273), int24(-600)];
        int24[4] memory upper = [int24(60), int24(0), int24(600), int24(887273)];
        for (uint8 i; i < 4; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.openPosition(key, lower[i], upper[i], 1e18, _pauseTestBounds());
        }
    }

    function testEveryOrdinaryOperationRequiresOwnerAndActiveReceipt() public {
        address bob = makeAddr("bob");
        sbt.setHolder(bob, true);
        _rejectAllOwnerOperations(bob, positionId, TSVLPManagerV1.InvalidPosition.selector);
        _rejectAllOwnerOperations(alice, 999, TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        _rejectAllOwnerOperations(alice, positionId, TSVLPManagerV1.InvalidPosition.selector);
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
    }

    function testEveryOrdinaryOperationRejectsExpiredDeadline() public {
        LPBounds memory b = _pauseTestBounds();
        b.deadline = uint64(block.timestamp - 1);
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 5; i++) {
            vm.expectRevert(TSVLPManagerV1.Expired.selector);
            vm.prank(alice);
            _operate(i, positionId, b);
        }
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testDeadlineIsInclusiveForLiquidityChange() public {
        LPBounds memory b = _pauseTestBounds();
        b.deadline = uint64(block.timestamp);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, b);
        assertEq(lpManager.getPosition(positionId).liquidity, 101e18);
    }

    function testOpenRequiresEligibleUserAndKnownPool() public {
        LPBounds memory b = _pauseTestBounds();
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.openPosition(key, -600, 600, 1e18, b);
        PoolKey memory wrong = key;
        wrong.fee++;
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.openPosition(wrong, -600, 600, 1e18, b);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testEachInputAndOutputSlippageBoundRollsBackAndCanRetry() public {
        for (uint8 currency; currency < 2; currency++) {
            LPBounds memory b = _pauseTestBounds();
            if (currency == 0) b.maxPoolIn0 = 0;
            else b.maxPoolIn1 = 0;
            bytes32 beforeState = _swapStateDigest(DAY);
            for (uint8 action; action < 2; action++) {
                vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
                vm.prank(alice);
                _operate(action, positionId, b);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
            b = _pauseTestBounds();
            if (currency == 0) b.minPoolOut0 = type(uint256).max;
            else b.minPoolOut1 = type(uint256).max;
            for (uint8 action = 2; action < 5; action += 2) {
                vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
                vm.prank(alice);
                _operate(action, positionId, b);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e18, _pauseTestBounds());
        assertEq(lpManager.getPosition(positionId).liquidity, 99e18);
    }

    function testFeeCollectionWithoutFeesRollsBackAndSecondCollectionRejects() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.NoFees.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        _seedPauseTestFees();
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.NoFees.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testClosePaysPrincipalAndUncollectedFeesInOneOperation() public {
        _seedPauseTestFees();
        uint256 snapshot = vm.snapshotState();
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        vm.startPrank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        lpManager.closePosition(positionId, _pauseTestBounds());
        vm.stopPrank();
        uint256 collectedStock = stock.balanceOf(alice) - stockBefore;
        uint256 collectedQuote = quote.balanceOf(alice) - quoteBefore;
        vm.revertToState(snapshot);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        assertEq(stock.balanceOf(alice) - stockBefore, collectedStock);
        assertEq(quote.balanceOf(alice) - quoteBefore, collectedQuote);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.balanceOf(alice), 0);
    }

    function testInactiveLPContextAndUnauthorizedCallbacksReject() public {
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.activeLPContext();
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.unlockCallback("");
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(address(manager));
        lpManager.unlockCallback("");
    }

    function testForceExitRequiresAuthorityAndReasonAndCannotRepeat() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.forceExit(positionId, 0, 0, 0);
        assertEq(_swapStateDigest(DAY), beforeState);
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        lpManager.revokeRole(lpManager.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
    }

    function _rejectAllOwnerOperations(address actor, uint256 id, bytes4 reason) internal {
        for (uint8 i = 1; i < 5; i++) {
            vm.expectRevert(reason);
            vm.prank(actor);
            _operate(i, id, _pauseTestBounds());
        }
    }

    function _operate(uint8 action, uint256 id, LPBounds memory b) internal {
        if (action == 0) lpManager.openPosition(key, -600, 600, 1e18, b);
        else if (action == 1) lpManager.increaseLiquidity(id, 1e18, b);
        else if (action == 2) lpManager.decreaseLiquidity(id, 1e18, b);
        else if (action == 3) lpManager.collectFees(id, b);
        else lpManager.closePosition(id, b);
    }
}
