// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {IDexRouter, IDexApproveProxy} from "../../../lib/dexrouter-interfaces/IDexRouter.sol";
import {ProtocolFixture} from "../../helpers/v1/ProtocolFixture.sol";
import {TSVAdapterFixture, DexRouterTestWallet} from "../../helpers/v1/TSVAdapterFixture.sol";
import {TSVAdapter} from "dex-adapters/adapters/uniswap-v4/TSVAdapter.sol";

/// @dev Actual deployed DEX and approval contracts; TSV/V4/issuer/SBT fixtures are deployed on the fork.
///      No router etching, approval-list mutation, production-admin impersonation, or skip fallback.
contract TSVXLayerDexRouterTest is ProtocolFixture, TSVAdapterFixture {
    struct ContractPin {
        address deployed;
        bytes32 codehash;
        string kind;
    }
    uint256 internal constant FORK_BLOCK = 72_271_000;
    address internal constant DEX = 0x7c5bEE2a8091C3ef39072f64F18Fac913060AEaF;
    bytes32 internal constant DEX_CODEHASH = 0x7766cf8785ca58e8da2204bf28f5b5cb2da420e1dbad4f5b88828a7c768da885;
    IDexRouter internal dex;
    TSVAdapter internal adapter;
    address internal approveProxy;
    address internal tokenApprove;

    function setUp() public override {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        assertEq(block.chainid, 196, "wrong fork chain");
        assertEq(DEX.codehash, DEX_CODEHASH, "deployed DEX changed");
        _assertDeploymentPins();
        dex = IDexRouter(DEX);
        assertEq(dex.version(), "v1.0.10-rfq-anti-arbitrage");
        // Approval proxy recovered from the pinned on-chain DAG execution module.
        approveProxy = address(uint160(0xfAd6a9eEe5b32E9B81bb217BaeF37742B2ca5B83));
        tokenApprove = IDexApproveProxy(approveProxy).tokenApprove();
        assertTrue(IDexApproveProxy(approveProxy).isAllowedProxy(DEX), "DEX not authorized by approval proxy");
        assertGt(tokenApprove.code.length, 0);
        super.setUp();
        adapter = new TSVAdapter(address(router), vm.addr(TEST_AUTH_KEY));
        router.setAdapterAllowed(address(adapter), true);
        vm.startPrank(alice);
        stock.approve(tokenApprove, type(uint256).max);
        quote.approve(tokenApprove, type(uint256).max);
        vm.stopPrank();
    }

    function testPinnedDeploymentAndApprovalContractsAreReal() public view {
        assertEq(block.number, FORK_BLOCK);
        assertEq(DEX.codehash, DEX_CODEHASH);
        assertTrue(IDexApproveProxy(approveProxy).isAllowedProxy(DEX));
        assertGt(approveProxy.code.length, 0);
        assertGt(tokenApprove.code.length, 0);
    }

    function testFullDexRouteBothDirectionsSettlesAndAccountsActualDeltas() public {
        _trade(alice, true, 1e18, alice);
        _trade(alice, false, 1e18, alice);
    }

    function testDexSplitRouteExecutesEachLegAndAccountsTheirSum() public {
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(direction, 1e18);
        IDexRouter.RouterPath memory split = paths[0];
        split.mixAdapters = new address[](2);
        split.assetTo = new address[](2);
        split.rawData = new uint256[](2);
        split.extraData = new bytes[](2);
        for (uint256 i; i < 2; i++) {
            split.mixAdapters[i] = address(adapter);
            split.assetTo[i] = address(adapter);
            split.rawData[i] = uint256(uint160(address(router))) | (uint256(5000) << 160) | (uint256(1) << 176)
                | (direction ? 0 : uint256(1) << 255);
            split.extraData[i] = _adapterRoute(adapter, DEX, key);
        }
        paths[0] = split;
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        assertGt(dex.dagSwapByOrderId(48, base, paths), 0);
        assertEq(beforeStock - stock.balanceOf(alice), 1e18);
        assertEq(ledger.used(SECURITY, DAY) - beforeUsed, 1e18);
        _assertNoTransitBalances();
    }

    function testDexTwoHopRouteUsesOriginalParticipantAndCountsEveryStockLeg() public {
        V1MockIssuerWrapped finalStock = new V1MockIssuerWrapped(stockUnderlying);
        BackedAutoFeeLegalShareAdapter legalAdapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(finalStock), 1);
        registry.registerToken(_config(address(finalStock), SECURITY, address(legalAdapter)), keccak256("second-stock"));
        PoolKey memory finalKey = PoolKey(
            Currency.wrap(address(finalStock) < address(quote) ? address(finalStock) : address(quote)),
            Currency.wrap(address(finalStock) < address(quote) ? address(quote) : address(finalStock)),
            3000,
            60,
            IHooks(address(hook))
        );
        lpManager.initializePool(finalKey, uint160(1 << 96), keccak256("second-hop-price"));
        finalStock.mintTestShares(alice, 1e24);
        vm.startPrank(alice);
        finalStock.approve(address(lpManager), type(uint256).max);
        lpManager.openPosition(finalKey, -600, 600, 1e20, _pauseTestBounds());
        vm.stopPrank();
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        (, uint256 intermediateAmount) = router.swapExactInput(_swapRequest(direction, 1e18));
        vm.revertToState(snapshot);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory first) = _route(direction, 1e18);
        (, IDexRouter.RouterPath[] memory second) = _route(!direction, uint128(intermediateAmount));
        IDexRouter.RouterPath[] memory paths = new IDexRouter.RouterPath[](2);
        paths[0] = first[0];
        paths[1] = second[0];
        bool finalDirection = Currency.unwrap(finalKey.currency0) == address(quote);
        paths[1].extraData[0] = _adapterRoute(adapter, DEX, finalKey);
        // First edge 0->1 settles to the DEX; second edge 1->2 delivers to the original caller.
        paths[1].rawData[0] = uint256(uint160(address(router))) | (uint256(10_000) << 160) | (uint256(1) << 184)
            | (uint256(2) << 176) | (finalDirection ? 0 : uint256(1) << 255);
        base.toToken = address(finalStock);
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeFinalStock = finalStock.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        vm.recordLogs();
        vm.prank(alice);
        uint256 finalOutput = dex.dagSwapByOrderId(49, base, paths);
        _assertSwapParticipant(address(router), alice);
        assertGt(finalOutput, 0);
        assertEq(beforeStock - stock.balanceOf(alice), 1e18);
        assertEq(finalStock.balanceOf(alice) - beforeFinalStock, finalOutput);
        assertEq(ledger.used(SECURITY, DAY) - beforeUsed, 1e18 + finalOutput);
        _assertNoTransitBalances();
        assertEq(finalStock.balanceOf(DEX), 0);
        assertEq(finalStock.balanceOf(address(adapter)), 0);
        assertEq(finalStock.balanceOf(address(router)), 0);
    }

    function testDexExplicitReceiverPreservesOriginalParticipant() public {
        address recipient = makeAddr("recipient-without-sbt");
        assertFalse(registry.isEligible(recipient));
        _trade(alice, true, 1e18, recipient);
    }

    function testContractWalletMarkerUsesWalletInsteadOfTransactionOrigin() public {
        DexRouterTestWallet wallet = new DexRouterTestWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.execute(address(stock), abi.encodeCall(IERC20.approve, (tokenApprove, type(uint256).max)));
        wallet.execute(address(quote), abi.encodeCall(IERC20.approve, (tokenApprove, type(uint256).max)));
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        assertFalse(registry.isEligible(address(this)));
        vm.recordLogs();
        wallet.execute(DEX, abi.encodeCall(IDexRouter.dagSwapByOrderId, (42, base, paths)));
        _assertSwapParticipant(address(router), address(wallet));
        assertGt(IERC20(Currency.unwrap(key.currency1)).balanceOf(address(wallet)), 1e21);
        _assertNoTransitBalances();
    }

    function testIneligibleDexCallerCannotBorrowEligibleOrigin() public {
        sbt.setHolder(alice, false);
        address origin = makeAddr("eligible-origin");
        sbt.setHolder(origin, true);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(alice, origin);
        dex.dagSwapByOrderId(43, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        _assertNoTransitBalances();
    }

    function testDexGlobalMinReturnFailureRevertsTransfersPoolQuotaAndAdapterWrites() public {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        base.minReturnAmount = type(uint128).max;
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert();
        vm.prank(alice);
        dex.dagSwapByOrderId(44, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        assertFalse(adapter.isNonceUsed(0));
        _assertNoTransitBalances();
        _trade(alice, true, 1e18, alice);
    }

    function testPartialFillRefundsUnusedInputToAuthenticatedParticipant() public {
        uint256 beforeInput = stock.balanceOf(alice);
        _trade(alice, address(stock) == Currency.unwrap(key.currency0), 1e22, alice);
        uint256 actualIn = beforeInput - stock.balanceOf(alice);
        assertLt(actualIn, 1e22);
        assertGt(actualIn, 0);
        _assertNoTransitBalances();
    }

    function testAdapterRevocationAndTradingPauseRevertDexFundingAtomically() public {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        router.setAdapterAllowed(address(adapter), false);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        vm.prank(alice);
        dex.dagSwapByOrderId(45, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        router.setAdapterAllowed(address(adapter), true);
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        dex.dagSwapByOrderId(46, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        _assertNoTransitBalances();
    }

    function testFullDexSwapAndLPLifecycleSharesPoolWithoutCountingLiquidityAsVolume() public {
        vm.prank(alice);
        uint256 id = lpManager.openPosition(key, -600, 600, 1e19, _pauseTestBounds());
        vm.prank(alice);
        lpManager.increaseLiquidity(id, 1e18, _pauseTestBounds());
        _trade(alice, true, 1e18, alice);
        _trade(alice, false, 1e18, alice);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        lpManager.collectFees(id, _pauseTestBounds());
        lpManager.decreaseLiquidity(id, 1e18, _pauseTestBounds());
        lpManager.closePosition(id, _pauseTestBounds());
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertFalse(lpManager.getPosition(id).active);
        _assertNoTransitBalances();
    }

    function _route(bool direction, uint128 amount)
        internal
        returns (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths)
    {
        address input = Currency.unwrap(direction ? key.currency0 : key.currency1);
        address output = Currency.unwrap(direction ? key.currency1 : key.currency0);
        base = IDexRouter.BaseRequest(uint256(uint160(input)), output, amount, 1, block.timestamp + 100);
        paths = new IDexRouter.RouterPath[](1);
        paths[0].mixAdapters = new address[](1);
        paths[0].assetTo = new address[](1);
        paths[0].rawData = new uint256[](1);
        paths[0].extraData = new bytes[](1);
        paths[0].mixAdapters[0] = address(adapter);
        paths[0].assetTo[0] = address(adapter);
        // DAG input index 0, output index 1, weight 10_000; bit 255 selects sellQuote.
        paths[0].rawData[0] = uint256(uint160(address(router))) | (uint256(10_000) << 160) | (uint256(1) << 176)
            | (direction ? 0 : uint256(1) << 255);
        paths[0].extraData[0] = _adapterRoute(adapter, DEX, key);
        paths[0].fromToken = uint256(uint160(input));
    }

    function _trade(address participant, bool direction, uint128 amount, address recipient) internal {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(direction, amount);
        IERC20 input = IERC20(address(uint160(base.fromToken)));
        IERC20 output = IERC20(base.toToken);
        uint256 inputBefore = input.balanceOf(participant);
        uint256 outputBefore = output.balanceOf(recipient);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.recordLogs();
        vm.prank(participant);
        uint256 reportedOut = dex.dagSwapTo(47, recipient, base, paths);
        _assertSwapParticipant(address(router), participant);
        uint256 actualIn = inputBefore - input.balanceOf(participant);
        uint256 actualOut = output.balanceOf(recipient) - outputBefore;
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        assertEq(reportedOut, actualOut);
        bool stockInput = address(input) == address(stock);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockInput ? actualIn : actualOut);
        _assertNoTransitBalances();
    }

    function _assertNoTransitBalances() internal view {
        address[4] memory transit = [DEX, address(adapter), address(router), address(lpManager)];
        for (uint256 i; i < transit.length; i++) {
            assertEq(stock.balanceOf(transit[i]), 0);
            assertEq(quote.balanceOf(transit[i]), 0);
        }
        assertEq(stock.allowance(address(adapter), address(router)), 0);
        assertEq(quote.allowance(address(adapter), address(router)), 0);
    }

    function _assertDeploymentPins() internal view {
        string memory manifest = vm.readFile("test/integration/xlayer/deployment.json");
        assertEq(vm.parseJsonUint(manifest, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(manifest, ".block"), block.number);
        // JSON object keys are ABI-encoded alphabetically: address, codehash, kind.
        ContractPin[] memory pins = abi.decode(vm.parseJson(manifest, ".contracts"), (ContractPin[]));
        for (uint256 i; i < pins.length; i++) {
            assertEq(pins[i].deployed.codehash, pins[i].codehash, pins[i].kind);
        }
    }
}
