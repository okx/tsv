// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey, Currency, IHooks, Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PoolKey as SwapPoolKey} from "v4-core/types/PoolKey.sol";
import {Currency as SwapCurrency} from "v4-core/types/Currency.sol";
import {IHooks as SwapHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev Sends add, fee-collect and full-remove as distinct mainnet transactions.
///      Run each operation with --broadcast and without --verify.
contract XLayerMainnetLPTransactions20261014 is Script {
    // X Layer has migrated the wallet balance to USDT0; this is the quote asset
    // held by the active signer and used for the smoke pool below.
    address private constant USDT = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address private constant REGISTRY = 0x2233EA2044FFA04CccEeEf0b9AdFe0799505a908;
    uint160 private constant SQRT_W0 = 79_228_162_514_264_337_593_543;
    uint160 private constant SQRT_USDT0 = 79_228_162_514_264_337_593_543_950_336_000_000;

    function prepareUsdt0() external {
        uint256 key = vm.envUint("PK");
        address wrapped = vm.envAddress("TSV_WRAPPED");
        address hook = vm.envAddress("TSV_HOOK");
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        require(block.chainid == 196, "wrong chain");
        vm.startBroadcast(key);
        TSVRegistryV1(REGISTRY).registerQuoteToken(USDT, bytes32("XLAYER_USDT0_20261014"));
        bool stockIsCurrency0 = wrapped < USDT;
        PoolKey memory pool = PoolKey(
            Currency.wrap(stockIsCurrency0 ? wrapped : USDT),
            Currency.wrap(stockIsCurrency0 ? USDT : wrapped),
            3000,
            60,
            IHooks(hook)
        );
        lp.initializePool(pool, stockIsCurrency0 ? SQRT_W0 : SQRT_USDT0);
        vm.stopBroadcast();
    }

    function add() external {
        uint256 key = vm.envUint("PK");
        address owner = vm.addr(key);
        address underlying = vm.envAddress("MOCK_8056_TOKEN");
        address wrapped = vm.envAddress("TSV_WRAPPED");
        address hook = vm.envAddress("TSV_HOOK");
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        require(block.chainid == 196, "wrong chain");
        require(IERC20(USDT).balanceOf(owner) >= 10_000, "need 0.01 USDT");
        require(IERC20(underlying).balanceOf(owner) >= 1e16, "need 0.01 mock U");

        vm.startBroadcast(key);
        require(IERC20(underlying).approve(address(lp), type(uint256).max), "approve U to LP Manager");
        require(IERC20(USDT).approve(address(lp), type(uint256).max), "approve USDT0 to LP Manager");

        bool stockIsCurrency0 = wrapped < USDT;
        PoolKey memory pool = PoolKey(
            Currency.wrap(stockIsCurrency0 ? wrapped : USDT),
            Currency.wrap(stockIsCurrency0 ? USDT : wrapped),
            3000,
            60,
            IHooks(hook)
        );
        uint160 sqrtPriceX96 = stockIsCurrency0 ? SQRT_W0 : SQRT_USDT0;
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 alignedTick = currentTick - (currentTick % 60);
        if (currentTick < 0 && currentTick % 60 != 0) alignedTick -= 60;
        int24 tickLower = alignedTick - 600;
        int24 tickUpper = alignedTick + 600;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 amount0Max = uint128(stockIsCurrency0 ? 1e16 : 10_000);
        uint128 amount1Max = uint128(stockIsCurrency0 ? 10_000 : 1e16);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0Max, amount1Max);
        require(liquidity != 0, "liquidity rounds to zero");

        uint256 tokenId = lp.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(pool, tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, owner, bytes(""));
        params[1] = abi.encode(pool.currency0, pool.currency1);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        console2.log("position id", tokenId);
        console2.log("liquidity", liquidity);
        console2.log("tick lower", tickLower);
        console2.log("tick upper", tickUpper);
    }

    function swap() external {
        uint256 key = vm.envUint("PK");
        address owner = vm.addr(key);
        address wrapped = vm.envAddress("TSV_WRAPPED");
        address hook = vm.envAddress("TSV_HOOK");
        TSVSwapRouterV1 router = TSVSwapRouterV1(vm.envAddress("TSV_ROUTER"));
        require(block.chainid == 196, "wrong chain");
        require(IERC20(USDT).balanceOf(owner) >= 1_000, "need 0.001 USDT");

        SwapPoolKey memory pool = SwapPoolKey(
            SwapCurrency.wrap(wrapped < USDT ? wrapped : USDT),
            SwapCurrency.wrap(wrapped < USDT ? USDT : wrapped),
            3000,
            60,
            SwapHooks(hook)
        );
        bool zeroForOne = USDT == SwapCurrency.unwrap(pool.currency0);
        vm.startBroadcast(key);
        require(IERC20(USDT).approve(address(router), 1_000), "approve USDT to router");
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(
            SwapRequest({
                key: pool,
                zeroForOne: zeroForOne,
                amountSpecified: 1_000,
                limitAmount: 800_000_000_000_000,
                deadline: uint64(block.timestamp + 1 hours),
                expectedMultiplier: 1e18
            })
        );
        vm.stopBroadcast();
        console2.log("swap input raw", actualIn);
        console2.log("swap output raw", actualOut);
    }

    function collect(uint256 tokenId) external {
        _liquidityAction(tokenId, 0, "collect");
    }

    function remove(uint256 tokenId) external {
        uint128 liquidity = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER"))).getPositionLiquidity(tokenId);
        require(liquidity != 0, "position has no liquidity");
        _liquidityAction(tokenId, liquidity, "remove");
    }

    function _liquidityAction(uint256 tokenId, uint128 liquidity, string memory label) private {
        uint256 key = vm.envUint("PK");
        address owner = vm.addr(key);
        address wrapped = vm.envAddress("TSV_WRAPPED");
        address hook = vm.envAddress("TSV_HOOK");
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(vm.envAddress("TSV_LP_MANAGER")));
        PoolKey memory pool = PoolKey(
            Currency.wrap(wrapped < USDT ? wrapped : USDT),
            Currency.wrap(wrapped < USDT ? USDT : wrapped),
            3000,
            60,
            IHooks(hook)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(pool.currency0, pool.currency1, owner);
        vm.startBroadcast(key);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        console2.log(label, tokenId);
        console2.log("liquidity removed", liquidity);
    }
}
