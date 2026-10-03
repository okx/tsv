// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVBackedAdapterTest scenarios; inherited fixtures contain no test functions.
contract TSVBackedAdapterTest is FoundationFixture {
    /// @dev Verifies the backed adapter reads the issuer conversion when the swap occurs.
    function testBackedAdapterCallsIssuerConversionAtTheTimeOfSwap() public {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped wrapped = new V1MockIssuerWrapped(underlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(underlying), address(wrapped), 1);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 3e18);
        underlying.setMultiplier(0.9e18, 7);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.7e18);
        underlying.setMultiplier(0.8e18, 8);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.4e18);
    }

    /// @dev Verifies the backed adapter validates Currency and accepts a zero amount.
    function testBackedAdapterValidatesCurrencyAndAllowsZeroAmount() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        assertEq(adapter.toLegalShares(address(stock), 0), 0);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidCurrency.selector);
        adapter.toLegalShares(address(quote), 1e18);
    }

    /// @dev Verifies the backed adapter rejects a wrapped-token asset mismatch.
    function testBackedAdapterRejectsWrappedAssetMismatch() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped otherWrapped = new V1MockIssuerWrapped(otherUnderlying);
        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidAdapterConfig.selector);
        new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(otherWrapped), 1);
    }

    /// @dev Verifies the backed adapter rejects zero conversion and reports its direct interface.
    function testBackedAdapterRejectsZeroConversionAndDeclaresDirectInterface() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        stockUnderlying.setMultiplier(0, 1);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidConversion.selector);
        adapter.toLegalShares(address(stock), 1);
        assertTrue(adapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId));
    }
}
