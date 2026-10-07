// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVLiquidityLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVLiquidityLocalTest is ProtocolFixture {
    /// @dev Verifies the LP Manager issues a non-transferable position receipt.
    function testLpManagerHostsNonTransferableReceipt() public {
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(lpManager.balanceOf(alice), 1);
        assertTrue(lpManager.supportsInterface(0x80ac58cd));

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.transferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.safeTransferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.approve(address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.setApprovalForAll(address(this), true);
    }

    /// @dev Verifies backed stock LP increases and decreases settle raw token amounts.
    function testBackedStockLPIncreaseAndDecreaseSettleRawAmounts() public {
        stockUnderlying.setMultiplier(2e18, 1);

        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawIn = aliceRawBefore - stock.balanceOf(alice);
        assertGt(stockRawIn, 0);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockRawIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockRawIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawOut = stock.balanceOf(alice) - aliceRawBefore;
        assertGt(stockRawOut, 0);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockRawOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockRawOut * 2);

        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
    }

    /// @dev Verifies LP increases revert when the owner loses more than the pool delta.
    function testLPIncreaseRevertsIfOwnerLosesMoreThanPoolDelta() public {
        quote.setSenderFee(alice, 100);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
    }

    /// @dev Verifies LP exits revert when the pool loses more than the output delta.
    function testLpExitRevertsIfPoolLosesMoreThanOutputDelta() public {
        quote.setSenderFee(address(manager), 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        LPBounds memory bounds;
        bounds.deadline = uint64(block.timestamp + 100);

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    /// @dev Verifies position close enforces the minimum output for a zero-delta Currency.
    function testClosePositionEnforcesMinimumForZeroDeltaCurrency() public {
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        vm.prank(alice);
        uint256 boundaryPositionId = lpManager.openPosition(key, 0, 60, 1e18, bounds);

        bounds.minPoolOut1 = 1;
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.closePosition(boundaryPositionId, bounds);

        TSVLPManagerV1.Position memory position = lpManager.getPosition(boundaryPositionId);
        assertTrue(position.active);
        assertEq(position.liquidity, 1e18);
        assertEq(lpManager.ownerOf(boundaryPositionId), alice);
    }

    /// @dev Verifies the direct LP lifecycle does not record liquidity as trade volume.
    function testDirectLpLifecycleDoesNotRecordLiquidityAsTradeVolume() public {
        _assertDirectLpLifecycle();
    }
}
