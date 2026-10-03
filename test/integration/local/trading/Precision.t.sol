// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1LocalERC20Decimals} from "../../../helpers/v1/LocalMocks.sol";

contract TSVTradingPrecisionTest is ProtocolFixture {
    function testSixDecimalQuoteSwapAndLPSettleInRawUnitsAndCountOnlyStockShares() public {
        V1LocalERC20Decimals quote6 = new V1LocalERC20Decimals("QUOTE6", 6);
        registry.registerToken(_config(address(quote6), 0, address(0)), keccak256("quote6"));
        bool stock0 = address(stock) < address(quote6);
        PoolKey memory precisionKey = PoolKey(
            Currency.wrap(stock0 ? address(stock) : address(quote6)),
            Currency.wrap(stock0 ? address(quote6) : address(stock)),
            3000,
            60,
            IHooks(address(hook))
        );
        uint160 price = stock0 ? uint160(uint256(1 << 96) / 1e6) : uint160((1 << 96) * 1e6);
        lpManager.initializePool(precisionKey, price, keccak256("precision-price"));
        quote6.mint(alice, 1e16);
        vm.startPrank(alice);
        quote6.approve(address(lpManager), type(uint256).max);
        quote6.approve(address(router), type(uint256).max);
        LPBounds memory bounds = _pauseTestBounds();
        bounds.maxPoolIn0 = 1e25;
        bounds.maxPoolIn1 = 1e25;
        uint256 id = lpManager.openPosition(precisionKey, -887220, 887220, 1e16, bounds);
        vm.stopPrank();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        for (uint8 i; i < 2; i++) {
            bool stockInput = i == 0;
            SwapRequest memory request = _swapRequest(stockInput == stock0, stockInput ? uint128(1e18) : uint128(1e6));
            request.key = precisionKey;
            uint256 beforeStock = stock.balanceOf(alice);
            uint256 beforeQuote = quote6.balanceOf(alice);
            vm.prank(alice);
            (uint256 input, uint256 output) = router.swapExactInput(request);
            if (stockInput) {
                assertEq(beforeStock - stock.balanceOf(alice), input);
                assertEq(quote6.balanceOf(alice) - beforeQuote, output);
            } else {
                assertEq(beforeQuote - quote6.balanceOf(alice), input);
                assertEq(stock.balanceOf(alice) - beforeStock, output);
            }
            uint256 shares = stockInput ? input : output;
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, shares);
            usedBefore += shares;
        }
        vm.prank(alice);
        lpManager.closePosition(id, bounds);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(quote6.balanceOf(address(router)), 0);
        assertEq(quote6.balanceOf(address(lpManager)), 0);
    }
}
