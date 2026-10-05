// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig, PauseScope, PauseMode, MarketAction} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsAdapterChangesTest is OperationsFixture {
    function testInactiveCurrencyReplacementDoesNotRequirePauseAndIncrementsEveryVersion() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        registry.disablePool(poolId);
        for (uint32 version = 2; version <= 3; ++version) {
            BackedAutoFeeLegalShareAdapter replacement =
                new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), version);

            address old = registry.getToken(address(stock)).legalShareAdapter;
            vm.expectEmit(true, false, false, true, address(registry));
            emit TSVRegistryV1.LegalShareAdapterChanged(address(stock), old, address(replacement), version);
            registry.replaceLegalShareAdapter(address(stock), address(replacement));
            TokenConfig memory stored = registry.getToken(address(stock));
            assertEq(stored.legalShareAdapter, address(replacement));
            assertEq(stored.legalAdapterVersion, version);

            assertEq(ledger.used(SECURITY, DAY), 1e18);
        }
        registry.enablePool(poolId);
        _assertOperationGates(true, true);
    }

    function testMarketSecurityAndPoolPausesDoNotAuthorizeActiveAdapterReplacement() public {
        _grantPauseRoles();
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        _pause(PauseScope.POOL, poolId, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        bytes32 beforeState = keccak256(abi.encode(registry.getToken(address(stock))));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement));
        assertEq(keccak256(abi.encode(registry.getToken(address(stock)))), beforeState);
        _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        registry.replaceLegalShareAdapter(address(stock), address(replacement));
    }

    function testReplacementRejectsInvalidIdentityInterfaceCurrencyAndVersion() public {
        _grantPauseRoles();
        _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter good =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        BackedAutoFeeLegalShareAdapter wrongVersion =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 3);
        BackedAutoFeeLegalShareAdapter wrongCurrency =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        for (uint8 fault; fault < 7; ++fault) {
            address currency = address(stock);
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
                adapter = address(wrongVersion);
            } else if (fault == 5) {
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
            bytes32 beforeState = keccak256(abi.encode(registry.getToken(address(stock))));
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.replaceLegalShareAdapter(currency, adapter);
            assertEq(keccak256(abi.encode(registry.getToken(address(stock)))), beforeState);
            vm.clearMockedCalls();
        }
        registry.replaceLegalShareAdapter(address(stock), address(good));
    }
}
