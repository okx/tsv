// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlag, PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

interface IXLayerSmartWalletSbt {
    function issue(address[] calldata users, uint256 tokenId) external;
    function verify(address user, uint256 tokenId) external view returns (bool);
    function issuerRole(uint256 tokenId) external pure returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Issues the already-configured TSV operator SBT to the active operator wallet.
contract IssueOperatorSbt is Script {
    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address operator = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        IXLayerSmartWalletSbt sbt = IXLayerSmartWalletSbt(vm.envAddress("TSV_SBT"));
        uint256 tokenId = vm.envUint("TSV_SBT_TOKEN_ID");

        require(address(registry).code.length != 0, "Registry has no code");
        require(address(sbt).code.length != 0, "SBT has no code");
        require(registry.participantSbt() == address(sbt), "SBT does not match Registry binding");
        (bool registered, PermissionFlag permissions) = registry.sbtIdentityConfig(tokenId);
        require(registered, "SBT identity is not configured in Registry");
        require(
            permissions == (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED),
            "SBT identity lacks SWAP and LP permissions"
        );
        require(!sbt.verify(operator, tokenId), "operator already holds this SBT");
        bytes32 issueRole = sbt.issuerRole(tokenId);
        require(sbt.hasRole(issueRole, operator), "operator lacks SBT issuer role");

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        console2.log("XLayer chainId:", block.chainid);
        console2.log("SBT:", address(sbt));
        console2.log("Token ID:", tokenId);
        console2.log("Recipient:", operator);

        vm.startBroadcast(privateKey);
        sbt.issue(recipients, tokenId);
        vm.stopBroadcast();

        require(sbt.verify(operator, tokenId), "SBT issue verification failed");
        require(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, operator), "SWAP permission is inactive");
        require(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, operator), "LP permission is inactive");
        console2.log("Issued and verified SWAP|LP SBT for operator");
    }
}
