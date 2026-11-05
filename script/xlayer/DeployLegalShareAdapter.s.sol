// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";

interface IERC8056DirectMultiplierSource {
    function uiMultiplier() external view returns (uint256);
}

/// @notice Deploys a Legal-share Adapter for an existing ERC-8056 underlying token.
contract DeployLegalShareAdapter is Script {
    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address underlying = vm.envAddress("TSV_LEGAL_ADAPTER_UNDERLYING");
        require(underlying.code.length != 0, "underlying has no code");
        require(IERC20Metadata(underlying).decimals() <= 18, "underlying decimals exceed 18");
        require(IERC8056DirectMultiplierSource(underlying).uiMultiplier() != 0, "underlying multiplier is zero");

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Underlying U:", underlying);
        vm.startBroadcast(privateKey);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(underlying);
        vm.stopBroadcast();

        console2.log("Created Legal-share Adapter:", address(adapter));
        console2.log("Current multiplier:", adapter.currentMultiplier(underlying));
    }
}
