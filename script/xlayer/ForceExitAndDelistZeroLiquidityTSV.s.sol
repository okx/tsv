// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";

/// @notice Permanently grants FORCE_EXIT_ADMIN_ROLE to the operator, force-burns selected foreign zero-liquidity
///         positions, and delists their pool once its tracked position count reaches zero.
contract ForceExitAndDelistZeroLiquidityTSV is Script {
    using PoolIdLibrary for PoolKey;

    struct Context {
        uint256 privateKey;
        address operator;
        uint256 positionCount;
        bytes32 poolId;
        bytes32 reasonCode;
        TSVLPManagerV1 lp;
        TSVRegistryV1 registry;
        bool forceExitRoleAlreadyHeld;
    }

    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        Context memory c;
        c.privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        c.operator = vm.addr(c.privateKey);
        c.positionCount = vm.envUint("TSV_FORCE_EXIT_POSITION_COUNT");
        c.poolId = vm.envBytes32("TSV_FORCE_EXIT_POOL_ID");
        c.reasonCode = vm.envBytes32("TSV_FORCE_EXIT_DELIST_REASON_CODE");
        c.lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        c.registry = TSVRegistryV1(address(c.lp.registry()));

        _validateContext(c);
        uint256[] memory positionIds = _validatePositions(c);
        _execute(c, positionIds);
        _verify(c, positionIds);
        console2.log("Foreign zero-liquidity Position NFTs force-exited:", c.positionCount);
        console2.log("FORCE_EXIT_ADMIN_ROLE retained by operator");
        console2.log("Pool set to DELIST");
    }

    function _validateContext(Context memory c) private view {
        require(c.positionCount > 0 && c.positionCount <= 64, "position count must be 1..64");
        require(c.poolId != bytes32(0), "expected pool ID must be nonzero");
        require(c.reasonCode != bytes32(0), "delist reason code must be nonzero");
        require(!c.registry.isPaused(), "Registry is paused");
        require(c.registry.hasRole(c.registry.DEFAULT_ADMIN_ROLE(), c.operator), "operator lacks DEFAULT_ADMIN_ROLE");
        require(c.registry.hasRole(c.registry.SYMBOL_ADMIN_ROLE(), c.operator), "operator lacks SYMBOL_ADMIN_ROLE");
        require(c.registry.isKnownPool(c.poolId), "pool is unknown");
        require(c.registry.getPoolLifeCycle(c.poolId) != PoolLifecycle.DELIST, "pool already delisted");
        c.forceExitRoleAlreadyHeld = c.registry.hasRole(c.lp.FORCE_EXIT_ADMIN_ROLE(), c.operator);
        require(
            c.registry.getPoolTickCount(c.poolId) == c.positionCount, "pool has positions outside the selected NFTs"
        );

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Operator:", c.operator);
        console2.log("FORCE_EXIT_ADMIN_ROLE will remain assigned:", c.operator);
        console2.log("Pool to delist:");
        console2.logBytes32(c.poolId);
        console2.log("Unique delist reason code:");
        console2.logBytes32(c.reasonCode);
    }

    function _validatePositions(Context memory c) private view returns (uint256[] memory positionIds) {
        positionIds = new uint256[](c.positionCount);
        for (uint256 i; i < c.positionCount; ++i) {
            positionIds[i] = _validatePosition(c, i, positionIds);
        }
    }

    function _validatePosition(Context memory c, uint256 index, uint256[] memory priorIds)
        private
        view
        returns (uint256 positionId)
    {
        string memory suffix = vm.toString(index);
        positionId = vm.envUint(string.concat("TSV_FORCE_EXIT_POSITION_ID_", suffix));
        address expectedOwner = vm.envAddress(string.concat("TSV_FORCE_EXIT_EXPECTED_OWNER_", suffix));
        require(positionId != 0, "position ID must be greater than zero");
        require(expectedOwner != address(0) && expectedOwner != c.operator, "expected owner must be another wallet");
        for (uint256 j; j < index; ++j) {
            require(priorIds[j] != positionId, "duplicate position ID");
        }
        require(c.lp.ownerOf(positionId) == expectedOwner, "position owner changed");
        require(c.lp.getPositionLiquidity(positionId) == 0, "position still has liquidity");
        (PoolKey memory key,) = c.lp.getPoolAndPositionInfo(positionId);
        require(PoolId.unwrap(key.toId()) == c.poolId, "position belongs to another pool");

        console2.log("Force-exit zero-liquidity Position NFT:", positionId);
        console2.log("Current owner:", expectedOwner);
    }

    function _execute(Context memory c, uint256[] memory positionIds) private {
        vm.startBroadcast(c.privateKey);
        if (!c.forceExitRoleAlreadyHeld) c.registry.grantRole(c.lp.FORCE_EXIT_ADMIN_ROLE(), c.operator);
        for (uint256 i; i < positionIds.length; ++i) {
            c.lp.unwindPositionByTsv(positionIds[i], 0, 0, bytes(""));
        }
        c.registry.updatePoolLifeCycle(c.poolId, PoolLifecycle.DELIST, c.reasonCode);
        vm.stopBroadcast();
    }

    function _verify(Context memory c, uint256[] memory positionIds) private view {
        require(c.registry.hasRole(c.lp.FORCE_EXIT_ADMIN_ROLE(), c.operator), "FORCE_EXIT_ADMIN_ROLE was not retained");
        for (uint256 i; i < positionIds.length; ++i) {
            (bool stillExists,) =
                address(c.lp).staticcall(abi.encodeWithSelector(bytes4(keccak256("ownerOf(uint256)")), positionIds[i]));
            require(!stillExists, "position NFT was not burned");
        }
        require(c.registry.getPoolTickCount(c.poolId) == 0, "pool tick count is not zero");
        require(c.registry.getPoolLifeCycle(c.poolId) == PoolLifecycle.DELIST, "pool lifecycle is not DELIST");
    }
}
