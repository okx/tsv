// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Burns signer-owned zero-liquidity LP NFTs, then delists only pools whose tick count reaches zero.
contract BurnAndDelistTSVPools is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        uint256 burnCount = vm.envUint("TSV_LP_BURN_POSITION_COUNT");
        uint256 delistCount = vm.envUint("TSV_POOL_DELIST_COUNT");
        uint256 deadlineSeconds = vm.envOr("TSV_DEADLINE_SECONDS", uint256(300));
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        TSVRegistryV1 registry = TSVRegistryV1(address(lp.registry()));

        require(burnCount > 0 && burnCount <= 64, "position count must be 1..64");
        require(delistCount > 0 && delistCount <= 64, "pool count must be 1..64");
        require(deadlineSeconds > 0, "deadline must be greater than zero");
        require(!registry.isPaused(), "Registry is paused");
        require(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner), "owner lacks LP permission");
        require(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), owner), "operator lacks SYMBOL_ADMIN_ROLE");

        uint256[] memory positionIds = new uint256[](burnCount);
        bytes32[] memory positionPoolIds = new bytes32[](burnCount);
        bytes memory actions = new bytes(burnCount);
        bytes[] memory actionParams = new bytes[](burnCount);
        console2.log("XLayer chainId:", block.chainid);
        console2.log("Operator:", owner);

        for (uint256 i; i < burnCount; ++i) {
            uint256 positionId = vm.envUint(string.concat("TSV_LP_BURN_POSITION_", vm.toString(i)));
            require(positionId != 0, "position ID must be greater than zero");
            for (uint256 j; j < i; ++j) {
                require(positionIds[j] != positionId, "duplicate position ID");
            }
            require(lp.ownerOf(positionId) == owner, "signer does not own position");
            require(lp.getPositionLiquidity(positionId) == 0, "position still has liquidity");
            (PoolKey memory key,) = lp.getPoolAndPositionInfo(positionId);
            bytes32 poolId = PoolId.unwrap(key.toId());
            require(registry.isLPAllowed(poolId), "position pool is not LP allowed");

            positionIds[i] = positionId;
            positionPoolIds[i] = poolId;
            actions[i] = bytes1(uint8(Actions.BURN_POSITION));
            actionParams[i] = abi.encode(positionId, uint128(0), uint128(0), bytes(""));
            console2.log("Burn zero-liquidity Position NFT:", positionId);
            console2.log("Position pool ID:");
            console2.logBytes32(poolId);
        }

        bytes32[] memory delistPoolIds = new bytes32[](delistCount);
        bytes32[] memory reasonCodes = new bytes32[](delistCount);
        for (uint256 i; i < delistCount; ++i) {
            string memory suffix = vm.toString(i);
            bytes32 poolId = vm.envBytes32(string.concat("TSV_POOL_DELIST_POOL_ID_", suffix));
            bytes32 reasonCode = vm.envBytes32(string.concat("TSV_POOL_DELIST_REASON_CODE_", suffix));
            require(reasonCode != bytes32(0), "reason code must be nonzero");
            for (uint256 j; j < i; ++j) {
                require(delistPoolIds[j] != poolId, "duplicate pool ID");
                require(reasonCodes[j] != reasonCode, "reason codes must be unique per pool operation");
            }
            require(registry.isKnownPool(poolId), "pool is unknown");
            require(registry.getPoolLifeCycle(poolId) != PoolLifecycle.DELIST, "pool already delisted");

            uint256 ticksToBurn;
            for (uint256 j; j < burnCount; ++j) {
                if (positionPoolIds[j] == poolId) ticksToBurn++;
            }
            uint256 currentTickCount = registry.getPoolTickCount(poolId);
            require(currentTickCount >= ticksToBurn, "pool tick count is below selected NFT count");
            require(currentTickCount - ticksToBurn == 0, "pool has NFT positions outside the selected owner");

            delistPoolIds[i] = poolId;
            reasonCodes[i] = reasonCode;
            console2.log("Delist pool ID:");
            console2.logBytes32(poolId);
            console2.log("Current tick count:", currentTickCount);
            console2.log("Unique reason code:");
            console2.logBytes32(reasonCode);
        }

        vm.startBroadcast(privateKey);
        lp.modifyLiquidities(abi.encode(actions, actionParams), block.timestamp + deadlineSeconds);
        for (uint256 i; i < delistCount; ++i) {
            registry.updatePoolLifeCycle(delistPoolIds[i], PoolLifecycle.DELIST, reasonCodes[i]);
        }
        vm.stopBroadcast();

        for (uint256 i; i < burnCount; ++i) {
            (bool stillExists,) =
                address(lp).staticcall(abi.encodeWithSelector(bytes4(keccak256("ownerOf(uint256)")), positionIds[i]));
            require(!stillExists, "position NFT was not burned");
        }
        for (uint256 i; i < delistCount; ++i) {
            require(registry.getPoolTickCount(delistPoolIds[i]) == 0, "delisted pool still has NFT count");
            require(
                registry.getPoolLifeCycle(delistPoolIds[i]) == PoolLifecycle.DELIST,
                "pool lifecycle did not become DELIST"
            );
        }
        console2.log("Zero-liquidity Position NFTs burned:", burnCount);
        console2.log("Pools set to DELIST:", delistCount);
    }
}
