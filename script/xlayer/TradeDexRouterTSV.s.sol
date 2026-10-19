// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "dex-adapters/interfaces/IERC20.sol";
import {ITSVSwapRouter} from "dex-adapters/interfaces/ITSVSwapRouter.sol";
import {TSVAdapter} from "dex-adapters/adapters/uniswap-v4/TSVAdapter.sol";
import {ECDSA} from "dex-adapters/libraries/ECDSA.sol";
import {SafeERC20} from "dex-adapters/libraries/SafeERC20.sol";
import {IDexRouter, IDexApproveProxy} from "../../lib/dexrouter-interfaces/IDexRouter.sol";

interface ITSVRouterAdapterPolicy {
    function isAdapterAllowed(address adapter) external view returns (bool);
}

/// @notice Simulates or broadcasts one single-hop TSVAdapter swap (signed sells, unsigned buys) through X Layer DexRouter.
/// @dev The trading wallet and the TSVAdapter backend signer are separate keys. No signing key is an operation input.
contract TradeDexRouterTSV is Script {
    using SafeERC20 for IERC20;

    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;
    uint256 private constant _WEIGHT_100_PERCENT = uint256(10_000) << 160;
    uint256 private constant _OUTPUT_INDEX_ONE = uint256(1) << 176;
    uint256 private constant _REVERSE_MASK = uint256(1) << 255;

    struct TradeConfig {
        address dexRouter;
        address tokenApprove;
        address approveProxy;
        address adapter;
        address tsvRouter;
        address stockCurrency;
        address stockUnderlying;
        address participant;
        address receiver;
        ITSVSwapRouter.PoolKey key;
        uint256 amountIn;
        uint256 minReturn;
        uint256 expectedMultiplier;
        uint256 nonce;
        uint256 deadline;
        bool isBuy;
        bool zeroForOne;
        address tokenIn;
        address tokenOut;
        address assetTo;
    }

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected X Layer mainnet 196");
        uint256 operatorKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address trader = vm.addr(operatorKey);
        TradeConfig memory c = _readConfig(trader);
        _validate(c, trader);

        address[] memory allowedCallers = new address[](1);
        allowedCallers[0] = c.dexRouter;
        TSVAdapter.MoreInfo memory info = TSVAdapter.MoreInfo({
            key: c.key,
            expectedMultiplier: c.expectedMultiplier,
            amountIn: c.amountIn,
            allowedCallers: allowedCallers,
            nonce: c.nonce,
            deadline: c.deadline,
            authSig: bytes("")
        });
        bytes memory moreInfo = _buildMoreInfo(c.isBuy, c.adapter, info, c.zeroForOne, c.participant);
        IDexRouter.RouterPath[] memory paths = _paths(c, moreInfo);
        IDexRouter.BaseRequest memory request = IDexRouter.BaseRequest({
            fromToken: uint256(uint160(c.tokenIn)),
            toToken: c.tokenOut,
            fromTokenAmount: c.amountIn,
            minReturnAmount: c.minReturn,
            deadLine: c.deadline
        });
        _logTrade(c, trader);
        IERC20 inputToken = IERC20(c.tokenIn);
        vm.startBroadcast(operatorKey);
        if (inputToken.allowance(trader, c.tokenApprove) < c.amountIn) {
            inputToken.forceApprove(c.tokenApprove, c.amountIn);
        }
        uint256 amountOut = IDexRouter(c.dexRouter).dagSwapTo(0, c.receiver, request, paths);
        vm.stopBroadcast();
        console2.log("DexRouter returned (raw):", amountOut);
    }

    function _readConfig(address trader) private view returns (TradeConfig memory c) {
        c.dexRouter = vm.envAddress("DEX_ROUTER");
        c.tokenApprove = vm.envAddress("DEX_TOKEN_APPROVE");
        c.approveProxy = vm.envAddress("DEX_TOKEN_APPROVE_PROXY");
        c.adapter = vm.envAddress("TSV_DEX_ADAPTER");
        c.tsvRouter = vm.envAddress("TSV_DEX_TSV_ROUTER");
        c.key.currency0 = vm.envAddress("TSV_DEX_CURRENCY0");
        c.key.currency1 = vm.envAddress("TSV_DEX_CURRENCY1");
        c.key.hooks = vm.envAddress("TSV_DEX_HOOK");
        c.stockCurrency = vm.envAddress("TSV_DEX_STOCK_CURRENCY");
        c.stockUnderlying = vm.envAddress("TSV_DEX_STOCK_UNDERLYING");
        c.participant = vm.envOr("TSV_DEX_PARTICIPANT", trader);
        c.receiver = vm.envOr("TSV_DEX_RECEIVER", c.participant);
        uint256 feeRaw = vm.envUint("TSV_DEX_FEE");
        int256 spacingRaw = vm.envInt("TSV_DEX_TICK_SPACING");
        require(feeRaw <= type(uint24).max, "TSV_DEX_FEE exceeds uint24");
        require(spacingRaw > 0 && spacingRaw <= 32767, "invalid TSV_DEX_TICK_SPACING");
        c.key.fee = uint24(feeRaw);
        c.key.tickSpacing = int24(spacingRaw);
        c.amountIn = vm.envUint("TSV_DEX_AMOUNT_IN");
        c.minReturn = vm.envUint("TSV_DEX_MIN_RETURN");
        c.expectedMultiplier = vm.envUint("TSV_DEX_EXPECTED_MULTIPLIER");
        c.isBuy = _isBuy(vm.envString("TSV_DEX_SIDE"));
        c.nonce = c.isBuy ? 0 : vm.envUint("TSV_DEX_NONCE");
        uint256 deadlineSeconds = vm.envUint("TSV_DEX_DEADLINE_SECONDS");
        require(
            block.timestamp <= type(uint64).max && deadlineSeconds > 0
                && deadlineSeconds <= type(uint64).max - block.timestamp,
            "invalid deadline"
        );
        c.deadline = block.timestamp + deadlineSeconds;
        address quoteCurrency = c.stockCurrency == c.key.currency0 ? c.key.currency1 : c.key.currency0;
        c.zeroForOne = c.isBuy ? c.stockCurrency == c.key.currency1 : c.stockCurrency == c.key.currency0;
        c.tokenIn = c.isBuy ? quoteCurrency : c.stockUnderlying;
        c.tokenOut = c.isBuy ? c.stockUnderlying : quoteCurrency;
        c.assetTo = c.isBuy ? c.adapter : c.stockCurrency;
    }

    function _validate(TradeConfig memory c, address trader) private view {
        require(c.dexRouter.code.length != 0, "DEX_ROUTER has no code");
        require(c.tokenApprove.code.length != 0, "DEX_TOKEN_APPROVE has no code");
        require(c.approveProxy.code.length != 0, "DEX_TOKEN_APPROVE_PROXY has no code");
        require(c.adapter.code.length != 0, "TSV_DEX_ADAPTER has no code");
        require(c.tsvRouter.code.length != 0, "TSV_DEX_TSV_ROUTER has no code");
        require(c.key.currency0 != address(0) && c.key.currency0 < c.key.currency1, "pool currencies must be sorted");
        require(c.key.hooks.code.length != 0, "TSV_DEX_HOOK has no code");
        require(c.amountIn > 0 && c.amountIn <= uint256(uint128(type(int128).max)), "invalid TSV_DEX_AMOUNT_IN");
        require(c.minReturn > 0 && c.minReturn <= type(uint128).max, "invalid TSV_DEX_MIN_RETURN");
        require(c.expectedMultiplier != 0, "TSV_DEX_EXPECTED_MULTIPLIER must be nonzero");
        require(
            c.participant == trader && c.receiver == c.participant, "participant/receiver must be the signing wallet"
        );
        require(c.receiver != address(0), "receiver must be nonzero");
        TSVAdapter adapter = TSVAdapter(c.adapter);
        require(adapter.TSV_ROUTER() == c.tsvRouter, "adapter TSV router mismatch");
        require(adapter.isDexRouter(c.dexRouter), "DexRouter is not allowlisted by TSVAdapter");
        require(
            ITSVRouterAdapterPolicy(c.tsvRouter).isAdapterAllowed(c.adapter),
            "TSV Router has not allowlisted TSVAdapter"
        );
        IDexApproveProxy approveProxy = IDexApproveProxy(c.approveProxy);
        require(approveProxy.tokenApprove() == c.tokenApprove, "TokenApproveProxy target mismatch");
        require(approveProxy.isAllowedProxy(c.dexRouter), "DexRouter is not allowed by TokenApproveProxy");
        require(c.stockCurrency == c.key.currency0 || c.stockCurrency == c.key.currency1, "stock W is not in PoolKey");
        ITSVSwapRouter router = ITSVSwapRouter(c.tsvRouter);
        require(
            router.settlementCurrency(c.stockCurrency) == c.stockUnderlying && c.stockUnderlying != c.stockCurrency,
            "W settlement currency does not match supplied U"
        );
        address quoteCurrency = c.isBuy ? c.tokenIn : c.tokenOut;
        require(
            router.settlementCurrency(quoteCurrency) == quoteCurrency,
            "the non-stock PoolKey currency must be a registered QuoteToken"
        );
        require(IERC20(c.tokenIn).balanceOf(trader) >= c.amountIn, "insufficient input-token balance");
    }

    function _paths(TradeConfig memory c, bytes memory moreInfo)
        private
        pure
        returns (IDexRouter.RouterPath[] memory paths)
    {
        uint256 rawData = uint256(uint160(c.tsvRouter)) | _WEIGHT_100_PERCENT | _OUTPUT_INDEX_ONE;
        if (!c.zeroForOne) rawData |= _REVERSE_MASK;
        address[] memory adapters = new address[](1);
        adapters[0] = c.adapter;
        address[] memory assetTos = new address[](1);
        assetTos[0] = c.assetTo;
        uint256[] memory rawDataList = new uint256[](1);
        rawDataList[0] = rawData;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = moreInfo;
        paths = new IDexRouter.RouterPath[](1);
        paths[0] = IDexRouter.RouterPath(adapters, assetTos, rawDataList, extraData, uint256(uint160(c.tokenIn)));
    }

    function _logTrade(TradeConfig memory c, address trader) private view {
        console2.log("X Layer chainId:", block.chainid);
        console2.log("DexRouter:", c.dexRouter);
        console2.log("TSVAdapter:", c.adapter);
        console2.log("Trader / participant / receiver:", trader);
        console2.log("Side:", c.isBuy ? "BUY_STOCK" : "SELL_STOCK");
        console2.log("Input token:", c.tokenIn);
        console2.log("AssetTo:", c.assetTo);
        console2.log("DexRouter input amount (raw):", c.amountIn);
        console2.log("Minimum output (raw):", c.minReturn);
        console2.log("Expected multiplier:", c.expectedMultiplier);
        console2.log("DexRouter deadline:", c.deadline);
        if (!c.isBuy) console2.log("Sell authorization nonce:", c.nonce);
        console2.log("TokenApprove allowance spender:", c.tokenApprove);
        if (IERC20(c.tokenIn).allowance(trader, c.tokenApprove) < c.amountIn) {
            console2.log("Broadcast will first set exact TokenApprove allowance for this amount.");
        }
    }

    /// @dev The SDK's amountIn funds DexRouter in both directions; buy MoreInfo carries no authorization.
    function _buildMoreInfo(
        bool isBuy,
        address adapterAddress,
        TSVAdapter.MoreInfo memory info,
        bool zeroForOne,
        address participant
    ) internal returns (bytes memory) {
        if (isBuy) {
            info.amountIn = 0;
            info.allowedCallers = new address[](0);
            info.nonce = 0;
            info.deadline = 0;
            info.authSig = bytes("");
        } else {
            uint256 authSignerKey = vm.envUint("TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY");
            TSVAdapter adapter = TSVAdapter(adapterAddress);
            require(adapter.AUTH_SIGNER() == vm.addr(authSignerKey), "signer key does not match adapter AUTH_SIGNER");
            require(!adapter.isNonceUsed(info.nonce), "TSVAdapter authorization nonce already used");
            bytes32 payloadHash = keccak256(
                abi.encode(info.key, info.expectedMultiplier, info.amountIn, zeroForOne, participant, info.deadline)
            );
            bytes32 inner =
                keccak256(abi.encode(adapterAddress, payloadHash, info.allowedCallers, info.nonce, block.chainid));
            (bytes32 r, bytes32 vs) = vm.signCompact(authSignerKey, ECDSA.toEthSignedMessageHash(inner));
            info.authSig = abi.encodePacked(r, vs);
        }
        return abi.encode(info);
    }

    function _isBuy(string memory side) private pure returns (bool) {
        bytes32 value = keccak256(bytes(side));
        if (value == keccak256("BUY_STOCK")) return true;
        require(value == keccak256("SELL_STOCK"), "TSV_DEX_SIDE must be BUY_STOCK or SELL_STOCK");
        return false;
    }
}
