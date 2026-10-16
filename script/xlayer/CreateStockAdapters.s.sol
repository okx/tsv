// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC20 as VendorIERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";

interface IERC8056MultiplierSource {
    function uiMultiplier() external view returns (uint256);
}

/// @notice Creates W plus the bound legal-share adapter for each stock U.
/// @dev The token issuer must allowlist W before VerifyStockAdapters.s.sol can deposit and verify it.
contract CreateStockAdapters is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        uint256 count = vm.envUint("TSV_CREATE_STOCK_COUNT");

        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");
        require(count != 0 && count <= 50, "TSV_CREATE_STOCK_COUNT must be 1..50");
        IPermissionsAdapterFactory factory = IPermissionsAdapterFactory(registry.permissionsAdapterFactory());
        require(address(factory).code.length != 0, "Registry Factory has no code");
        require(factory.POOL_MANAGER() == vm.envAddress("TSV_POOL_MANAGER"), "Factory PoolManager mismatch");

        address[] memory underlyings = new address[](count);
        address[] memory owners = new address[](count);
        address[] memory checkers = new address[](count);

        for (uint256 i; i < count; ++i) {
            string memory suffix = vm.toString(i);
            address underlying = vm.envAddress(string.concat("TSV_CREATE_STOCK_UNDERLYING_", suffix));
            address initialOwner = vm.envAddress(string.concat("TSV_CREATE_STOCK_OWNER_", suffix));
            address checker = vm.envAddress(string.concat("TSV_CREATE_STOCK_ALLOWLIST_", suffix));

            require(underlying.code.length != 0, "stock U has no code");
            require(initialOwner != address(0), "W initial owner is zero");
            require(checker.code.length != 0, "Allowlist Checker has no code");
            require(IERC20Metadata(underlying).decimals() <= 18, "stock U decimals exceed 18");
            require(IERC8056MultiplierSource(underlying).uiMultiplier() != 0, "stock U multiplier is zero");
            require(
                IERC165(checker).supportsInterface(type(IAllowlistChecker).interfaceId),
                "Allowlist Checker lacks IAllowlistChecker"
            );
            require(registry.getCurrencyUnderlying(underlying) == address(0), "stock U is already a registered W");
            require(!registry.getQuoteToken(underlying).registered, "stock U is an active quote token");
            for (uint256 j; j < i; ++j) require(underlyings[j] != underlying, "duplicate stock U in list");

            underlyings[i] = underlying;
            owners[i] = initialOwner;
            checkers[i] = checker;

            console2.log("Stock U:", underlying);
            console2.log("W initial owner:", initialOwner);
            console2.log("Allowlist Checker:", checker);
        }

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("PermissionsAdapterFactory:", address(factory));

        vm.startBroadcast(privateKey);
        for (uint256 i; i < count; ++i) {
            ERC8056DirectLegalShareAdapter legalAdapter = new ERC8056DirectLegalShareAdapter(underlyings[i]);
            address wrapped = factory.createPermissionsAdapter(
                VendorIERC20(underlyings[i]), owners[i], IAllowlistChecker(checkers[i])
            );

            console2.log("Created W:", wrapped);
            console2.log("Created Legal-share Adapter:", address(legalAdapter));
            console2.log("Next: issuer allowlist W, then run VerifyStockAdapters.s.sol");
        }
        vm.stopBroadcast();
    }
}
