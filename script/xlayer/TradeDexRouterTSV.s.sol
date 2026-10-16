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

/// @notice Simulates or broadcasts one signed, single-hop TSVAdapter swap through X Layer DexRouter.
/// @dev The trading wallet and the TSVAdapter backend signer are separate keys. No signing key is an operation input.
contract TradeDexRouterTSV is Script {
    using SafeERC20 for IERC20;

    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;
    uint256 private constant _WEIGHT_100_PERCENT = uint256(10_000) << 160;
    uint256 private constant _OUTPUT_INDEX_ONE = uint256(1) << 176;
    uint256 private constant _REVERSE_MASK = uint256(1) << 255;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected X Layer mainnet 196");

        uint256 operatorKey = vm.envUint("XLAYER_PRIVATE_KEY");
        uint256 authSignerKey = vm.envUint("TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY");
        address trader = vm.addr(operatorKey);
        address authSigner = vm.addr(authSignerKey);

        address dexRouterAddress = vm.envAddress("DEX_ROUTER");
        address tokenApproveAddress = vm.envAddress("DEX_TOKEN_APPROVE");
        address approveProxyAddress = vm.envAddress("DEX_TOKEN_APPROVE_PROXY");
        address adapterAddress = vm.envAddress("TSV_DEX_ADAPTER");
        address tsvRouterAddress = vm.envAddress("TSV_DEX_TSV_ROUTER");
        address currency0 = vm.envAddress("TSV_DEX_CURRENCY0");
        address currency1 = vm.envAddress("TSV_DEX_CURRENCY1");
        address hook = vm.envAddress("TSV_DEX_HOOK");
        address stockCurrency = vm.envAddress("TSV_DEX_STOCK_CURRENCY");
        address stockUnderlying = vm.envAddress("TSV_DEX_STOCK_UNDERLYING");
        address participant = vm.envOr("TSV_DEX_PARTICIPANT", trader);
        address receiver = vm.envOr("TSV_DEX_RECEIVER", participant);
        uint256 feeRaw = vm.envUint("TSV_DEX_FEE");
        int256 spacingRaw = vm.envInt("TSV_DEX_TICK_SPACING");
        uint256 amountIn = vm.envUint("TSV_DEX_AMOUNT_IN");
        uint256 minReturn = vm.envUint("TSV_DEX_MIN_RETURN");
        uint256 expectedMultiplier = vm.envUint("TSV_DEX_EXPECTED_MULTIPLIER");
        uint256 nonce = vm.envUint("TSV_DEX_NONCE");
        uint256 deadlineSeconds = vm.envUint("TSV_DEX_DEADLINE_SECONDS");
        string memory side = vm.envString("TSV_DEX_SIDE");

        require(dexRouterAddress.code.length != 0, "DEX_ROUTER has no code");
        require(tokenApproveAddress.code.length != 0, "DEX_TOKEN_APPROVE has no code");
        require(approveProxyAddress.code.length != 0, "DEX_TOKEN_APPROVE_PROXY has no code");
        require(adapterAddress.code.length != 0, "TSV_DEX_ADAPTER has no code");
        require(tsvRouterAddress.code.length != 0, "TSV_DEX_TSV_ROUTER has no code");
        require(currency0 != address(0) && currency0 < currency1, "pool currencies must be sorted");
        require(hook.code.length != 0, "TSV_DEX_HOOK has no code");
        require(feeRaw <= type(uint24).max, "TSV_DEX_FEE exceeds uint24");
        require(spacingRaw > 0 && spacingRaw <= 32767, "invalid TSV_DEX_TICK_SPACING");
        require(amountIn > 0 && amountIn <= uint256(uint128(type(int128).max)), "invalid TSV_DEX_AMOUNT_IN");
        require(minReturn > 0 && minReturn <= type(uint128).max, "invalid TSV_DEX_MIN_RETURN");
        require(expectedMultiplier != 0, "TSV_DEX_EXPECTED_MULTIPLIER must be nonzero");
        require(deadlineSeconds > 0 && deadlineSeconds <= type(uint64).max - block.timestamp, "invalid deadline");
        require(participant == trader && receiver == participant, "participant/receiver must be the signing wallet");
        bool isBuy = _isBuy(side);

        TSVAdapter adapter = TSVAdapter(adapterAddress);
        require(adapter.TSV_ROUTER() == tsvRouterAddress, "adapter TSV router mismatch");
        require(adapter.AUTH_SIGNER() == authSigner, "signer key does not match adapter AUTH_SIGNER");
        require(adapter.isDexRouter(dexRouterAddress), "DexRouter is not allowlisted by TSVAdapter");
        require(
            ITSVRouterAdapterPolicy(tsvRouterAddress).isAdapterAllowed(adapterAddress),
            "TSV Router has not allowlisted TSVAdapter"
        );
        require(!adapter.isNonceUsed(nonce), "TSVAdapter authorization nonce already used");

        IDexApproveProxy approveProxy = IDexApproveProxy(approveProxyAddress);
        require(approveProxy.tokenApprove() == tokenApproveAddress, "TokenApproveProxy target mismatch");
        require(approveProxy.isAllowedProxy(dexRouterAddress), "DexRouter is not allowed by TokenApproveProxy");

        ITSVSwapRouter.PoolKey memory key = ITSVSwapRouter.PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: uint24(feeRaw),
            tickSpacing: int24(spacingRaw),
            hooks: hook
        });
        ITSVSwapRouter router = ITSVSwapRouter(tsvRouterAddress);
        address settlement0 = router.settlementCurrency(currency0);
        address settlement1 = router.settlementCurrency(currency1);
        require(stockCurrency == currency0 || stockCurrency == currency1, "stock W is not in PoolKey");
        require(
            (stockCurrency == currency0 ? settlement0 : settlement1) == stockUnderlying
                && stockUnderlying != stockCurrency,
            "W settlement currency does not match supplied U"
        );
        address quoteCurrency = stockCurrency == currency0 ? currency1 : currency0;
        require(
            (quoteCurrency == currency0 ? settlement0 : settlement1) == quoteCurrency,
            "the non-stock PoolKey currency must be a registered QuoteToken"
        );

        bool zeroForOne = isBuy ? stockCurrency == currency1 : stockCurrency == currency0;
        address tokenIn = isBuy ? quoteCurrency : stockUnderlying;
        address tokenOut = isBuy ? stockUnderlying : quoteCurrency;
        address assetTo = isBuy ? adapterAddress : stockCurrency;
        uint256 deadline = block.timestamp + deadlineSeconds;
        IERC20 inputToken = IERC20(tokenIn);
        require(inputToken.balanceOf(trader) >= amountIn, "insufficient input-token balance");
        require(receiver != address(0), "receiver must be nonzero");

        address[] memory allowedCallers = new address[](1);
        allowedCallers[0] = dexRouterAddress;
        TSVAdapter.MoreInfo memory info = TSVAdapter.MoreInfo({
            key: key,
            expectedMultiplier: expectedMultiplier,
            amountIn: amountIn,
            allowedCallers: allowedCallers,
            nonce: nonce,
            deadline: deadline,
            authSig: bytes("")
        });
        bytes32 payloadHash = keccak256(
            abi.encode(key, expectedMultiplier, amountIn, zeroForOne, participant, receiver, deadline)
        );
        bytes32 inner = keccak256(abi.encode(adapterAddress, payloadHash, allowedCallers, nonce, block.chainid));
        (bytes32 r, bytes32 vs) = vm.signCompact(authSignerKey, ECDSA.toEthSignedMessageHash(inner));
        info.authSig = abi.encodePacked(r, vs);
        bytes memory moreInfo = abi.encode(info);

        uint256 rawData = uint256(uint160(tsvRouterAddress)) | _WEIGHT_100_PERCENT | _OUTPUT_INDEX_ONE;
        if (!zeroForOne) rawData |= _REVERSE_MASK;
        address[] memory adapters = new address[](1);
        adapters[0] = adapterAddress;
        address[] memory assetTos = new address[](1);
        assetTos[0] = assetTo;
        uint256[] memory rawDataList = new uint256[](1);
        rawDataList[0] = rawData;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = moreInfo;
        IDexRouter.RouterPath[] memory paths = new IDexRouter.RouterPath[](1);
        paths[0] = IDexRouter.RouterPath({
            mixAdapters: adapters,
            assetTo: assetTos,
            rawData: rawDataList,
            extraData: extraData,
            fromToken: uint256(uint160(tokenIn))
        });
        IDexRouter.BaseRequest memory request = IDexRouter.BaseRequest({
            fromToken: uint256(uint160(tokenIn)),
            toToken: tokenOut,
            fromTokenAmount: amountIn,
            minReturnAmount: minReturn,
            deadLine: deadline
        });

        console2.log("X Layer chainId:", block.chainid);
        console2.log("DexRouter:", dexRouterAddress);
        console2.log("TSVAdapter:", adapterAddress);
        console2.log("Trader / participant / receiver:", trader);
        console2.log("Side:", side);
        console2.log("Input token:", tokenIn);
        console2.log("AssetTo:", assetTo);
        console2.log("Input amount (raw, signed):", amountIn);
        console2.log("Minimum output (raw):", minReturn);
        console2.log("Expected multiplier:", expectedMultiplier);
        console2.log("Authorization nonce:", nonce);
        console2.log("Signature deadline:", deadline);
        console2.log("TokenApprove allowance spender:", tokenApproveAddress);
        if (inputToken.allowance(trader, tokenApproveAddress) < amountIn) {
            console2.log("Broadcast will first set exact TokenApprove allowance for this amount.");
        }

        vm.startBroadcast(operatorKey);
        if (inputToken.allowance(trader, tokenApproveAddress) < amountIn) {
            inputToken.forceApprove(tokenApproveAddress, amountIn);
        }
        uint256 amountOut = IDexRouter(dexRouterAddress).dagSwapTo(0, receiver, request, paths);
        vm.stopBroadcast();

        console2.log("DexRouter returned (raw):", amountOut);
    }

    function _isBuy(string memory side) private pure returns (bool) {
        bytes32 value = keccak256(bytes(side));
        if (value == keccak256("BUY_STOCK")) return true;
        require(value == keccak256("SELL_STOCK"), "TSV_DEX_SIDE must be BUY_STOCK or SELL_STOCK");
        return false;
    }
}
