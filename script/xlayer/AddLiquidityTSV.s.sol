// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, PoolKey, IHooks, Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolKey as CorePoolKey} from "v4-core/types/PoolKey.sol";
import {Currency as CoreCurrency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks as CoreHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";

interface IERC20AllowanceXLayer is IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Adds one TSV W/Q liquidity position using caller-specified maximum raw amounts.
contract AddLiquidityTSV is Script {
    using PoolIdLibrary for CorePoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        require(block.chainid == 196, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        require(
            owner == vm.envOr("TSV_LIQUIDITY_EXPECTED_OWNER", owner),
            "signing wallet differs from expected LP owner"
        );
        address currency0Address = vm.envAddress("TSV_CURRENCY0");
        address currency1Address = vm.envAddress("TSV_CURRENCY1");
        address hookAddress = vm.envAddress("TSV_HOOK");
        uint256 feeRaw = vm.envUint("TSV_FEE");
        uint256 spacingRaw = vm.envUint("TSV_TICK_SPACING");
        uint256 amount0Max = vm.envUint("TSV_LIQUIDITY_AMOUNT0_MAX");
        uint256 amount1Max = vm.envUint("TSV_LIQUIDITY_AMOUNT1_MAX");
        uint256 rangeRaw = vm.envOr("TSV_LIQUIDITY_TICK_RADIUS", uint256(600));

        require(currency0Address != address(0) && currency0Address < currency1Address, "currencies must be sorted");
        require(hookAddress.code.length != 0, "hook has no code");
        require(feeRaw <= type(uint24).max, "fee exceeds uint24");
        require(spacingRaw > 0 && spacingRaw <= uint256(uint24(type(int24).max)), "invalid tick spacing");
        require(amount0Max != 0 && amount1Max != 0, "both liquidity amounts must be nonzero");
        require(rangeRaw != 0 && rangeRaw <= uint256(uint24(type(int24).max)), "invalid tick radius");

        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        IPoolManager poolManager = IPoolManager(vm.envAddress("TSV_POOL_MANAGER"));
        require(address(registry).code.length != 0 && address(lp).code.length != 0, "TSV component has no code");
        require(address(poolManager).code.length != 0, "PoolManager has no code");
        require(address(lp.registry()) == address(registry), "LP Manager Registry mismatch");
        require(registry.hook() == hookAddress, "hook does not match Registry");
        require(!registry.isPaused(), "Registry is paused");
        require(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner), "operator lacks LP permission");

        CorePoolKey memory coreKey = CorePoolKey(
            CoreCurrency.wrap(currency0Address),
            CoreCurrency.wrap(currency1Address),
            uint24(feeRaw),
            _toInt24(spacingRaw),
            CoreHooks(hookAddress)
        );
        PoolId poolId = coreKey.toId();
        require(registry.isTradable(PoolId.unwrap(poolId)), "pool is not registered and active");
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "pool is not initialized");

        address underlying0 = registry.getCurrencyUnderlying(currency0Address);
        address underlying1 = registry.getCurrencyUnderlying(currency1Address);
        require((underlying0 == address(0)) != (underlying1 == address(0)), "pool must contain exactly one W");
        address stockInput = underlying0 == address(0) ? underlying1 : underlying0;
        address token0Input = underlying0 == address(0) ? currency0Address : underlying0;
        address token1Input = underlying1 == address(0) ? currency1Address : underlying1;
        IERC20 token0 = IERC20(token0Input);
        IERC20 token1 = IERC20(token1Input);
        require(token0.balanceOf(owner) >= amount0Max, "insufficient currency0 input balance");
        require(token1.balanceOf(owner) >= amount1Max, "insufficient currency1 input balance");

        int24 spacing = _toInt24(spacingRaw);
        int24 radius = _toInt24(rangeRaw);
        int24 alignedTick = (currentTick / spacing) * spacing;
        if (currentTick < 0 && currentTick % spacing != 0) alignedTick -= spacing;
        int24 tickLower = alignedTick - radius;
        int24 tickUpper = alignedTick + radius;
        require(tickLower >= TickMath.MIN_TICK && tickUpper <= TickMath.MAX_TICK, "liquidity range out of bounds");
        tickLower = (tickLower / spacing) * spacing;
        tickUpper = (tickUpper / spacing) * spacing;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amount0Max, amount1Max
        );
        require(liquidity != 0, "liquidity rounds to zero");

        PoolKey memory pool = PoolKey(
            Currency.wrap(currency0Address),
            Currency.wrap(currency1Address),
            uint24(feeRaw),
            spacing,
            IHooks(hookAddress)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            pool, tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, owner, bytes("")
        );
        params[1] = abi.encode(pool.currency0, pool.currency1);

        console2.log("XLayer chainId:", block.chainid);
        console2.log("LP owner:", owner);
        console2.log("Pool ID:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Stock U input:", stockInput);
        console2.log("Currency0 input:", token0Input);
        console2.log("Currency1 input:", token1Input);
        console2.log("Current tick:", currentTick);
        console2.log("Tick lower:", tickLower);
        console2.log("Tick upper:", tickUpper);
        console2.log("Maximum amount0 raw:", amount0Max);
        console2.log("Maximum amount1 raw:", amount1Max);
        console2.log("Liquidity:", liquidity);

        vm.startBroadcast(privateKey);
        _approveIfNeeded(token0, owner, address(lp), amount0Max);
        _approveIfNeeded(token1, owner, address(lp), amount1Max);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        console2.log("Position token ID:", lp.nextTokenId() - 1);
    }

    function _approveIfNeeded(IERC20 token, address owner, address spender, uint256 amount) private {
        IERC20AllowanceXLayer tokenWithAllowance = IERC20AllowanceXLayer(address(token));
        uint256 currentAllowance = tokenWithAllowance.allowance(owner, spender);
        if (currentAllowance >= amount) return;
        if (currentAllowance != 0) require(token.approve(spender, 0), "approval reset failed");
        require(token.approve(spender, amount), "approval failed");
    }

    function _toInt24(uint256 value) private pure returns (int24) {
        require(value <= uint256(uint24(type(int24).max)), "value exceeds int24");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(uint24(value));
    }
}
