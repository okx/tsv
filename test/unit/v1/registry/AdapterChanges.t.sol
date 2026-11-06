// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsAdapterChangesTest is FoundationFixture {
    function testReplacementWithoutPauseChangesAdapterAndPreservesUsed() public {
        _submitQuota(1000e18);
        _charge(1e18);
        for (uint256 i; i < 2; ++i) {
            ERC8056DirectLegalShareAdapter replacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
            address old = registry.getUnderlying(address(stockToken)).legalShareAdapter;
            vm.expectEmit(true, false, false, true, address(registry));
            emit TSVRegistryV1.UnderlyingLegalShareAdapterChanged(
                address(stockToken), old, address(replacement), bytes32("TEST")
            );
            registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
            assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(replacement));
            assertEq(ledger.usedWad(SECURITY, DAY), 1e18);
        }
    }

    function testReplacementIsAllowedWithAnySecurityPauseMode() public {
        ERC8056DirectLegalShareAdapter replacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(replacement));

        _setSecurityMode(SecurityPauseMode.TRADE, true);
        ERC8056DirectLegalShareAdapter tradePausedReplacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(
            address(stockToken), address(tradePausedReplacement), bytes32("TEST")
        );

        _setSecurityMode(SecurityPauseMode.LP, true);
        ERC8056DirectLegalShareAdapter allPausedReplacement = new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(allPausedReplacement), bytes32("TEST"));
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(allPausedReplacement));
    }

    function testReplacementRejectsInvalidIdentityInterfaceAndCurrency() public {
        _grantPauseRoles();
        _enableEmergencyPause();
        ERC8056DirectLegalShareAdapter good = new ERC8056DirectLegalShareAdapter(address(stockToken));
        ERC8056DirectLegalShareAdapter wrongCurrency = new ERC8056DirectLegalShareAdapter(address(stockToken));
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
            registry.replaceUnderlyingLegalShareAdapter(currency, adapter, bytes32("TEST"));
            assertEq(keccak256(abi.encode(registry.getUnderlying(address(stockToken)))), beforeState);
            vm.clearMockedCalls();
        }
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(good), bytes32("TEST"));
    }
}
