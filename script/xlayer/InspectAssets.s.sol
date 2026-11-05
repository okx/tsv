// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {UnderlyingRecord, QuoteTokenRecord, SecurityRecord} from "tsv-v1/types/TSVTypes.sol";

/// @notice Read-only inspection of configured U, W, Q and security lists.
contract InspectAssets is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external view {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");

        uint256 underlyingCount = vm.envUint("TSV_INSPECT_U_COUNT");
        for (uint256 i; i < underlyingCount; ++i) {
            address underlying = vm.envAddress(string.concat("TSV_INSPECT_U_", vm.toString(i)));
            UnderlyingRecord memory record = registry.getUnderlying(underlying);
            console2.log("U:", underlying);
            console2.log("  registered:", record.registered);
            console2.log("  decimals:", record.rawDecimals);
            console2.log("  legal-share adapter:", record.legalShareAdapter);
            console2.log("  security ID:");
            console2.logBytes32(record.securityId);
        }

        uint256 wrappedCount = vm.envUint("TSV_INSPECT_W_COUNT");
        for (uint256 i; i < wrappedCount; ++i) {
            address wrapped = vm.envAddress(string.concat("TSV_INSPECT_W_", vm.toString(i)));
            address underlying = registry.getCurrencyUnderlying(wrapped);
            console2.log("W:", wrapped);
            console2.log("  registered:", underlying != address(0));
            console2.log("  underlying U:", underlying);
            if (underlying != address(0)) {
                UnderlyingRecord memory record = registry.getUnderlying(underlying);
                console2.log("  U active for new pools:", record.registered);
                console2.log("  legal-share adapter:", record.legalShareAdapter);
                console2.log("  security ID:");
                console2.logBytes32(record.securityId);
            }
        }

        uint256 quoteCount = vm.envUint("TSV_INSPECT_Q_COUNT");
        for (uint256 i; i < quoteCount; ++i) {
            address quote = vm.envAddress(string.concat("TSV_INSPECT_Q_", vm.toString(i)));
            QuoteTokenRecord memory record = registry.getQuoteToken(quote);
            console2.log("Q:", quote);
            console2.log("  registered for new pools:", record.registered);
            console2.log("  decimals:", record.rawDecimals);
        }

        uint256 securityCount = vm.envUint("TSV_INSPECT_SECURITY_COUNT");
        for (uint256 i; i < securityCount; ++i) {
            bytes32 securityId = vm.envBytes32(string.concat("TSV_INSPECT_SECURITY_", vm.toString(i)));
            SecurityRecord memory record = registry.getSecurity(securityId);
            console2.log("Security ID:");
            console2.logBytes32(securityId);
            console2.log("  exists:", record.securityId != bytes32(0));
            console2.log("  listed:", record.listed);
            console2.log("  tier:", record.tierId);
            console2.log("  active pools:", record.listedPoolCount);
            console2.log("  pause mask (TRADE=1, LP=2):", registry.getSecurityPauseMode(securityId));
        }

        console2.log("Registry paused:", registry.isPaused());
    }
}
