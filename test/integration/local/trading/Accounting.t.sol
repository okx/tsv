// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Real-V4 accounting across fees, pools, and owners.
contract TSVTradingAccountingTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testProtocolAndLPFeesAreIncludedInActualStockInputVolume() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice);
        (uint256 actualIn,) = router.swapExactInput(_swapRequest(direction, 1e18));
        assertEq(beforeStock - stock.balanceOf(alice), actualIn);
        assertEq(ledger.used(SECURITY, DAY), actualIn);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(stock))), 0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        manager.collectProtocolFees(address(this), Currency.wrap(address(stock)), 0);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function testSameSecurityAcrossTwoRealPoolsConsumesOneQuota() public {
        PoolKey memory second = key;
        second.fee = 500;
        second.tickSpacing = 10;
        lpManager.initializePool(second, uint160(1 << 96));
        vm.prank(alice);
        lpManager.openPosition(second, -600, 600, 1e20, _pauseTestBounds());
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                DAY,
                1,
                15e17,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 100),
                1,
                1,
                keccak256("two-pool-quota")
            )
        );
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        (uint256 first,) = router.swapExactInput(_swapRequest(direction, 1e18));
        SwapRequest memory request = _swapRequest(direction, 1e18);
        request.key = second;
        uint256 ownerStock = stock.balanceOf(alice);
        uint256 poolStock = stock.balanceOf(address(manager));
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), first);
        assertEq(stock.balanceOf(alice), ownerStock);
        assertEq(stock.balanceOf(address(manager)), poolStock);
        request.amountSpecified = 4e17;
        vm.prank(alice);
        (uint256 secondInput,) = router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), first + secondInput);
    }

    function testEqualRangesAccrueSeparateOwnerFeesAndClosingOnePreservesOther() public {
        address bob = makeAddr("fee-bob");
        sbt.setHolder(bob, true);
        stock.mintTestShares(bob, 1e22);
        quote.mint(bob, 1e22);
        vm.startPrank(bob);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        uint256 bobId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
        vm.stopPrank();
        _seedPauseTestFees();
        uint256 beforeAlice = stock.balanceOf(alice);
        uint256 beforeBob = stock.balanceOf(bob);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        vm.prank(bob);
        lpManager.collectFees(bobId, _pauseTestBounds());
        uint256 aliceFees = stock.balanceOf(alice) - beforeAlice;
        assertGt(aliceFees, 0);
        assertEq(stock.balanceOf(bob) - beforeBob, aliceFees);
        TSVLPManagerV1.Position memory beforePosition = lpManager.getPosition(bobId);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        assertEq(keccak256(abi.encode(lpManager.getPosition(bobId))), keccak256(abi.encode(beforePosition)));
        assertEq(lpManager.ownerOf(bobId), bob);
        vm.prank(bob);
        lpManager.closePosition(bobId, _pauseTestBounds());
        assertEq(lpManager.balanceOf(bob), 0);
    }
}
