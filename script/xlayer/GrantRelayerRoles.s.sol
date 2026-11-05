// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IRelayerRoleRegistry {
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
}

interface IRelayerRegistryBound {
    function registry() external view returns (address);
}

/// @notice Grants the four requested relayer assignments on the Registry proxy.
/// @dev Simulates by default. Use --sender plus --account and --broadcast to send.
contract GrantRelayerRoles is Script {
    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "wrong chain");
        address admin = vm.envAddress("TSV_ROLE_ADMIN");
        address registryAddress = vm.envAddress("TSV_REGISTRY");
        require(admin != address(0), "zero admin");
        require(registryAddress.code.length != 0, "Registry has no code");
        require(
            IRelayerRegistryBound(vm.envAddress("TSV_LEDGER")).registry() == registryAddress, "Ledger Registry mismatch"
        );
        require(
            IRelayerRegistryBound(vm.envAddress("TSV_LP_MANAGER")).registry() == registryAddress,
            "LP Manager Registry mismatch"
        );
        IRelayerRoleRegistry registry = IRelayerRoleRegistry(registryAddress);
        bytes32[4] memory roles = [
            keccak256("HALT_REPORTER_ROLE"),
            keccak256("VOLUME_ORACLE_ROLE"),
            keccak256("HALT_REPORTER_ROLE"),
            keccak256("FORCE_EXIT_ADMIN_ROLE")
        ];
        address[4] memory accounts = [
            vm.parseAddress("0xc7228a9ce9c36f035bad7e4e417a3974901249c9"),
            vm.parseAddress("0x60d0ce25e0930958b869a0b126f3d9a456559b5b"),
            vm.parseAddress("0xde739bd7e3281c167fab53d00f17b36aafc599dc"),
            vm.parseAddress("0x726880a6f4604ff4271740dc5cba73a91280800e")
        ];

        // Validate all four assignments before recording any transaction.
        for (uint256 i; i < roles.length; ++i) {
            require(registry.hasRole(registry.getRoleAdmin(roles[i]), admin), "sender lacks role admin");
        }
        console2.log("Chain ID:", block.chainid);
        console2.log("Registry:", registryAddress);
        console2.log("Admin:", admin);
        vm.startBroadcast(admin);
        for (uint256 i; i < roles.length; ++i) {
            if (registry.hasRole(roles[i], accounts[i])) {
                console2.log("Already granted; skipping:", accounts[i]);
            } else {
                console2.log("Granting to:", accounts[i]);
                console2.logBytes32(roles[i]);
                registry.grantRole(roles[i], accounts[i]);
            }
        }
        vm.stopBroadcast();
        for (uint256 i; i < roles.length; ++i) {
            require(registry.hasRole(roles[i], accounts[i]), "role readback failed");
        }
    }
}
