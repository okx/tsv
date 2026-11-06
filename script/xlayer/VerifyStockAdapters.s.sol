// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice Deposits issuer-approved U into W and verifies W through the Registry's Factory.
/// @dev Run after the token issuer has allowlisted the newly created W address.
contract VerifyStockAdapters is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address depositor = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        uint256 count = vm.envUint("TSV_VERIFY_STOCK_COUNT");

        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");
        require(count != 0 && count <= 50, "TSV_VERIFY_STOCK_COUNT must be 1..50");
        IPermissionsAdapterFactory factory = IPermissionsAdapterFactory(registry.permissionsAdapterFactory());
        require(address(factory).code.length != 0, "Registry Factory has no code");

        address[] memory wrappers = new address[](count);
        address[] memory underlyings = new address[](count);
        uint256[] memory amounts = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            address wrapped = vm.envAddress(string.concat("TSV_VERIFY_STOCK_WRAPPED_", suffix));
            address underlying = vm.envAddress(string.concat("TSV_VERIFY_STOCK_UNDERLYING_", suffix));
            uint256 amount = vm.envUint(string.concat("TSV_VERIFY_STOCK_AMOUNT_", suffix));

            require(wrapped.code.length != 0, "stock W has no code");
            require(underlying.code.length != 0, "stock U has no code");
            require(amount != 0, "verification deposit must be nonzero");
            require(factory.permissionsAdapterOf(wrapped) == underlying, "W/U does not match Registry Factory");
            address verifiedUnderlying = factory.verifiedPermissionsAdapterOf(wrapped);
            require(verifiedUnderlying == address(0) || verifiedUnderlying == underlying, "W verified for another U");
            if (verifiedUnderlying == address(0)) {
                require(IERC20(underlying).balanceOf(depositor) >= amount, "depositor lacks verification U");
            }
            for (uint256 j; j < i; ++j) {
                require(wrappers[j] != wrapped, "duplicate W in verification list");
            }

            wrappers[i] = wrapped;
            underlyings[i] = underlying;
            amounts[i] = amount;

            console2.log("W:", wrapped);
            console2.log("U:", underlying);
            console2.log("Already Factory-verified:", verifiedUnderlying == underlying);
            if (verifiedUnderlying == address(0)) console2.log("Verification deposit (raw U):", amount);
        }

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("PermissionsAdapterFactory:", address(factory));
        console2.log("Depositor:", depositor);

        vm.startBroadcast(privateKey);
        for (uint256 i; i < count; ++i) {
            if (factory.verifiedPermissionsAdapterOf(wrappers[i]) == underlyings[i]) continue;
            require(IERC20(underlyings[i]).transfer(wrappers[i], amounts[i]), "verification token transfer failed");
            factory.verifyPermissionsAdapter(wrappers[i]);
            require(
                factory.verifiedPermissionsAdapterOf(wrappers[i]) == underlyings[i], "Factory verification mismatch"
            );
            console2.log("Factory-verified W:", wrappers[i]);
        }
        vm.stopBroadcast();
    }
}
