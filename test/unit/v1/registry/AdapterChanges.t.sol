// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UnderlyingRecord, PauseScope, PauseMode, MarketAction} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsAdapterChangesTest is OperationsFixture {
    function testSecurityPauseReplacementChangesAdapterAndPreservesUsed() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        for (uint256 i; i < 2; ++i) {
            BackedAutoFeeLegalShareAdapter replacement =
                new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
            address old = registry.getUnderlying(address(stockToken)).legalShareAdapter;
            vm.expectEmit(true, false, false, true, address(registry));
            emit TSVRegistryV1.UnderlyingLegalShareAdapterChanged(address(stockToken), old, address(replacement));
            registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
            assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(replacement));
            assertEq(ledger.used(SECURITY, DAY), 1e18);
        }
    }

    function testPoolAndSingleWTokenPauseAreInsufficient() public {
        _grantPauseRoles();
        _pause(PauseScope.POOL, poolId, PauseMode.ALL);
        _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
    }

    function testReplacementRejectsInvalidIdentityInterfaceAndCurrency() public {
        _grantPauseRoles();
        _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter good =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        BackedAutoFeeLegalShareAdapter wrongCurrency =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        for (uint8 fault; fault < 6; ++fault) {
            address currency = address(stockToken);
            address adapter = address(good);

            if (fault == 0) {
                currency = address(quote);
            } else if (fault == 1) {
                currency = makeAddr("unknown");
            } else if (fault == 2) {
                adapter = address(stockAdapter);
            } else if (fault == 3) {
                adapter = makeAddr("no-code-adapter");
            } else if (fault == 4) {
                adapter = address(wrongCurrency);
                vm.mockCall(
                    adapter,
                    abi.encodeWithSelector(IDirectLegalShareAdapter.poolCurrency.selector),
                    abi.encode(address(quote))
                );
            } else {
                vm.mockCall(
                    address(good), abi.encodeWithSelector(IERC165.supportsInterface.selector), abi.encode(false)
                );
            }
            bytes32 beforeState = keccak256(abi.encode(registry.getUnderlying(address(stockToken))));
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.replaceUnderlyingLegalShareAdapter(currency, adapter);
            assertEq(keccak256(abi.encode(registry.getUnderlying(address(stockToken)))), beforeState);
            vm.clearMockedCalls();
        }
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(good));
    }
}
