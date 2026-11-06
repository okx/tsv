// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Burns only signer-owned LP NFTs that already have zero liquidity.
contract BurnZeroLiquidityTSV is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        uint256 count = vm.envUint("TSV_LP_BURN_POSITION_COUNT");
        uint256 deadlineSeconds = vm.envOr("TSV_DEADLINE_SECONDS", uint256(300));
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        TSVRegistryV1 registry = TSVRegistryV1(address(lp.registry()));

        require(count > 0 && count <= 64, "position count must be 1..64");
        require(deadlineSeconds > 0, "deadline must be greater than zero");
        require(!registry.isPaused(), "Registry is paused");
        require(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner), "owner lacks LP permission");

        uint256[] memory positionIds = new uint256[](count);
        bytes32[] memory poolIds = new bytes32[](count);
        uint256[] memory poolTicksBefore = new uint256[](count);
        uint256[] memory burnsPerPool = new uint256[](count);
        uint256 uniquePoolCount;
        bytes memory actions = new bytes(count);
        bytes[] memory params = new bytes[](count);

        console2.log("XLayer chainId:", block.chainid);
        console2.log("LP owner:", owner);
        console2.log("Zero-liquidity positions to burn:", count);

        for (uint256 i; i < count; ++i) {
            uint256 positionId = vm.envUint(string.concat("TSV_LP_BURN_POSITION_", vm.toString(i)));
            require(positionId != 0, "position ID must be greater than zero");
            for (uint256 j; j < i; ++j) {
                require(positionIds[j] != positionId, "duplicate position ID");
            }
            require(lp.ownerOf(positionId) == owner, "signer does not own position");
            require(lp.getPositionLiquidity(positionId) == 0, "position still has liquidity");

            (PoolKey memory poolKey,) = lp.getPoolAndPositionInfo(positionId);
            bytes32 poolId = PoolId.unwrap(poolKey.toId());
            require(registry.isLPAllowed(poolId), "position pool is not LP allowed");

            uint256 poolIndex = type(uint256).max;
            for (uint256 j; j < uniquePoolCount; ++j) {
                if (poolIds[j] == poolId) {
                    poolIndex = j;
                    break;
                }
            }
            if (poolIndex == type(uint256).max) {
                poolIndex = uniquePoolCount++;
                poolIds[poolIndex] = poolId;
                poolTicksBefore[poolIndex] = registry.getPoolTickCount(poolId);
            }
            require(poolTicksBefore[poolIndex] > burnsPerPool[poolIndex], "pool tick count is too small");
            burnsPerPool[poolIndex]++;

            positionIds[i] = positionId;
            actions[i] = bytes1(uint8(Actions.BURN_POSITION));
            params[i] = abi.encode(positionId, uint128(0), uint128(0), bytes(""));

            console2.log("Position ID:", positionId);
            console2.log("Pool ID:");
            console2.logBytes32(poolId);
            console2.log("Liquidity:", uint256(0));
        }

        vm.startBroadcast(privateKey);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp + deadlineSeconds);
        vm.stopBroadcast();

        for (uint256 i; i < count; ++i) {
            (bool stillExists,) =
                address(lp).staticcall(abi.encodeWithSelector(bytes4(keccak256("ownerOf(uint256)")), positionIds[i]));
            require(!stillExists, "position NFT was not burned");
        }
        for (uint256 i; i < uniquePoolCount; ++i) {
            require(
                registry.getPoolTickCount(poolIds[i]) == poolTicksBefore[i] - burnsPerPool[i],
                "pool tick count did not decrease as expected"
            );
        }
        console2.log("Burned zero-liquidity position NFTs:", count);
    }
}
