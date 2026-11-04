// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {UnderlyingRecord, QuoteTokenRecord} from "tsv-v1/types/TSVTypes.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice Registers a configured list of original quote tokens on XLayer.
/// @dev Each list item carries its own reason code. Calls are simulated unless --broadcast is passed.
contract RegisterQuoteTokens is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address admin = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        uint256 count = vm.envUint("TSV_QUOTE_COUNT");

        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");
        require(count != 0, "TSV_QUOTE_COUNT is zero");
        require(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), admin), "signer lacks SYMBOL_ADMIN_ROLE");

        IPermissionsAdapterFactory factory = IPermissionsAdapterFactory(registry.permissionsAdapterFactory());
        require(address(factory).code.length != 0, "Registry Factory has no code");

        address[] memory quotes = new address[](count);
        bytes32[] memory reasons = new bytes32[](count);
        bool[] memory shouldRegister = new bool[](count);
        uint256 registerCount;

        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            address quote = vm.envAddress(string.concat("TSV_QUOTE_TOKEN_", suffix));
            bytes32 reasonCode = vm.envBytes32(string.concat("TSV_QUOTE_REASON_", suffix));
            require(quote.code.length != 0, "quote token has no code");
            require(reasonCode != bytes32(0), "quote reason code must be nonzero");
            for (uint256 j; j < i; ++j) {
                require(quotes[j] != quote, "duplicate quote token in list");
            }

            QuoteTokenRecord memory quoteRecord = registry.getQuoteToken(quote);
            if (quoteRecord.registered) {
                console2.log("Quote already registered; skipping:", quote);
            } else {
                require(registry.getCurrencyUnderlying(quote) == address(0), "quote is already a stock wrapper");
                UnderlyingRecord memory underlyingRecord = registry.getUnderlying(quote);
                require(underlyingRecord.securityId == bytes32(0), "quote is already a stock underlying");
                require(factory.permissionsAdapterOf(quote) == address(0), "quote is a permissions adapter");
                uint8 decimals = IERC20Metadata(quote).decimals();
                require(decimals <= 18, "quote decimals exceed 18");
                shouldRegister[i] = true;
                registerCount++;
                console2.log("Quote token:", quote);
                console2.log("Quote decimals:", decimals);
            }

            quotes[i] = quote;
            reasons[i] = reasonCode;
            console2.log("Quote reason code:");
            console2.logBytes32(reasonCode);
        }

        if (registerCount == 0) {
            console2.log("No quote registration transactions required.");
            return;
        }

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("Admin:", admin);
        vm.startBroadcast(privateKey);
        for (uint256 i; i < count; ++i) {
            if (shouldRegister[i]) registry.registerQuoteToken(quotes[i], reasons[i]);
        }
        vm.stopBroadcast();
    }
}
