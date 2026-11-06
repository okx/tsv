// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, PoolKey, Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Removes all liquidity from an LP-owned position containing a requested currency.
contract WithdrawLiquidityTSV is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        uint256 positionId = vm.envUint("TSV_LP_POSITION_ID");
        address requiredCurrency = vm.envAddress("TSV_LP_REQUIRED_CURRENCY");
        uint256 deadlineSeconds = vm.envOr("TSV_DEADLINE_SECONDS", uint256(300));
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));

        require(address(lp).code.length != 0, "LP Manager has no code");
        require(deadlineSeconds != 0, "deadline must be greater than zero");
        require(lp.ownerOf(positionId) == owner, "signer does not own this position");
        (PoolKey memory poolKey,) = lp.getPoolAndPositionInfo(positionId);
        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);
        require(
            requiredCurrency == currency0 || requiredCurrency == currency1,
            "position does not contain requested currency"
        );

        uint128 liquidity = lp.getPositionLiquidity(positionId);
        require(liquidity != 0, "position has no liquidity");

        TSVRegistryV1 registry = TSVRegistryV1(address(lp.registry()));
        require(!registry.isPaused(), "Registry is paused");
        require(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner), "owner lacks LP permission");
        PoolId poolId = poolKey.toId();
        require(registry.isLPAllowed(PoolId.unwrap(poolId)), "position pool is not LP allowed");

        address asset0 = registry.getCurrencyUnderlying(currency0);
        address asset1 = registry.getCurrencyUnderlying(currency1);
        if (asset0 == address(0)) asset0 = currency0;
        if (asset1 == address(0)) asset1 = currency1;
        require(asset0.code.length != 0 && asset1.code.length != 0, "withdrawal asset has no code");

        uint256 balance0Before = IERC20(asset0).balanceOf(owner);
        uint256 balance1Before = IERC20(asset1).balanceOf(owner);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, owner);

        console2.log("XLayer chainId:", block.chainid);
        console2.log("LP owner:", owner);
        console2.log("Position ID:", positionId);
        console2.log("Pool ID:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Currency0:", currency0);
        console2.log("Currency1:", currency1);
        console2.log("Underlying delivered for currency0:", asset0);
        console2.log("Underlying delivered for currency1:", asset1);
        console2.log("Liquidity removed:", liquidity);
        console2.log("Minimum amount0 raw:", uint256(0));
        console2.log("Minimum amount1 raw:", uint256(0));

        vm.startBroadcast(privateKey);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp + deadlineSeconds
        );
        vm.stopBroadcast();

        require(lp.getPositionLiquidity(positionId) == 0, "position still has liquidity");
        uint256 balance0After = IERC20(asset0).balanceOf(owner);
        uint256 balance1After = IERC20(asset1).balanceOf(owner);
        require(balance0After >= balance0Before && balance1After >= balance1Before, "withdrawal balance check failed");
        console2.log("Amount0 returned raw:", balance0After - balance0Before);
        console2.log("Amount1 returned raw:", balance1After - balance1Before);
    }
}
