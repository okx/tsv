// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVWrappedInventoryTest is WrappedSwapFixture {
    function testFuzzStandardSwapPreservesExistingUnderlyingAndQuoteBalances(
        bool stockInput,
        uint96 donatedUnderlying,
        uint96 donatedQuote
    ) public {
        underlying.mint(address(manager), donatedUnderlying);
        underlying.mint(address(router), donatedUnderlying);
        quote.mint(address(router), donatedQuote);
        uint256 surplus = _inventory();
        _swap(stockInput, 1e16);
        assertEq(underlying.balanceOf(address(manager)), donatedUnderlying);
        assertEq(underlying.balanceOf(address(router)), donatedUnderlying);
        assertEq(quote.balanceOf(address(router)), donatedQuote);
        assertEq(_inventory(), surplus);
        assertEq(stock.balanceOf(address(manager)), stock.totalSupply());
        assertEq(stock.balanceOf(address(router)), 0);
    }
}
