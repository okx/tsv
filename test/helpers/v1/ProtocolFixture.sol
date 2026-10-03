// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {
    TokenConfig,
    TokenStatus,
    MarketAction,
    PauseScope,
    PauseMode,
    LPBounds,
    SwapRequest
} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "./MockIssuerTokens.sol";
import {ITestTokenMetadata, V1LocalERC20, V1LocalSBT, V1TestExternalAdapter} from "./LocalMocks.sol";

/// @dev ProtocolFixture scenarios; inherited fixtures contain no test functions.
abstract contract ProtocolFixture is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant HOOK_ADDRESS = address(uint160(0x3FFF));
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant SECURITY = keccak256("SEC_A");
    uint32 internal constant DAY = 20261001;

    PoolManager internal manager;
    TSVGovernanceAnchor internal anchor;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    TSVLPManagerV1 internal lpManager;
    V1LocalSBT internal sbt;
    V1MockIssuerShares internal stockUnderlying;
    V1MockIssuerWrapped internal stock;
    V1LocalERC20 internal quote;
    PoolKey internal key;
    address internal alice;
    uint256 internal positionId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public virtual {
        vm.warp(1_790_827_201);
        alice = makeAddr("alice");
        manager = new PoolManager(address(this));
        anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
        registry = TSVRegistryV1(
            _newProxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor))))
        );
        ledger = TSVVolumeLedgerV1(
            _newProxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
            )
        );
        inbox = TSVDataInboxV1(
            _newProxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
            )
        );
        sbt = new V1LocalSBT();
        sbt.setHolder(alice, true);
        registry.setSbtConfig(address(sbt), 1, keccak256("sbt-config"));
        router = TSVSwapRouterV1(
            _newProxy(
                address(new TSVSwapRouterV1()),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize, (address(anchor), address(manager), address(registry), address(ledger))
                )
            )
        );
        lpManager = TSVLPManagerV1(
            _newProxy(
                address(new TSVLPManagerV1()),
                abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), address(manager), address(registry)))
            )
        );
        hook = TSVHookV1(HOOK_ADDRESS);
        _installProxy(HOOK_ADDRESS, address(new TSVHookV1()));
        hook.initialize(
            address(anchor), address(manager), address(registry), address(ledger), address(router), address(lpManager)
        );
        registry.bindComponents(address(hook), address(lpManager), address(inbox));
        ledger.bindWriters(address(hook), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        lpManager.grantRole(lpManager.POOL_CREATOR_ROLE(), address(this));
        lpManager.grantRole(lpManager.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 10_000, 10, keccak256("tier"));
        stockUnderlying = new V1MockIssuerShares();
        stock = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1LocalERC20("QUOTE");
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        registry.admitSecurity(
            SECURITY, keccak256("STDx"), 1, _config(address(stock), SECURITY, address(adapter)), keccak256("stock")
        );
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));
        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        lpManager.initializePool(key, uint160(1 << 96), keccak256("price"));
        stock.mintTestShares(alice, 1e24);
        quote.mint(alice, 1e24);
        vm.startPrank(alice);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        positionId = lpManager.openPosition(key, -600, 600, 1e20, bounds);
        vm.stopPrank();
        _submitReports();
    }

    function _swapStateDigest(uint32 day) internal view returns (bytes32) {
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, id);
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(manager, id);
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                StateLibrary.getLiquidity(manager, id),
                keccak256(
                    abi.encode(
                        stock.balanceOf(alice),
                        quote.balanceOf(alice),
                        stock.balanceOf(address(router)),
                        quote.balanceOf(address(router)),
                        stock.balanceOf(address(manager)),
                        quote.balanceOf(address(manager)),
                        stock.balanceOf(address(lpManager)),
                        quote.balanceOf(address(lpManager))
                    )
                ),
                keccak256(abi.encode(lpManager.getPosition(positionId))),
                lpManager.ownerOf(positionId),
                ledger.used(SECURITY, day)
            )
        );
    }

    function _assertDirectLpLifecycle() internal {
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        vm.startPrank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
        uint256 usedAfterSwap = ledger.used(SECURITY, DAY);
        assertGt(usedAfterSwap, usedBefore);
        vm.startPrank(alice);
        lpManager.collectFees(positionId, bounds);
        lpManager.closePosition(positionId, bounds);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedAfterSwap);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        lpManager.ownerOf(positionId);
    }

    /// @dev Implements the PoolManager unlock callback used to test direct swap access.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        PoolKey memory target = abi.decode(data, (PoolKey));
        manager.swap(target, IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1), "");
        return "";
    }

    function _exercisePauseBehavior(PauseMode mode, bool marketPause) internal {
        _seedPauseTestFees();
        if (marketPause) _submitLocalMarket(MarketAction.HALT, mode);
        else _pauseLocal(PauseScope.POOL, PoolId.unwrap(key.toId()), mode);
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(registry.isTradable(poolId), mode == PauseMode.LP);
        assertEq(registry.isLPAllowed(poolId), mode == PauseMode.TRADE);
        if (mode == PauseMode.LP) _exerciseAllowedTrading();
        else _assertTradingBlocked();
        if (mode == PauseMode.TRADE) _exerciseAllowedLPLifecycle();
        else _assertOrdinaryLPBlocked();
    }

    function _seedPauseTestFees() internal {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
    }

    function _assertTradingBlocked() internal {
        SwapRequest memory request = _swapRequest(true, 1e16);
        request.limitAmount = 1e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        router.swapExactInput(request);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        router.swapExactOutput(request);
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        adapter.swapExactInput(router, request, alice);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _assertOrdinaryLPBlocked() internal {
        LPBounds memory bounds = _pauseTestBounds();
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        uint256 nextId = lpManager.nextPositionId();
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.openPosition(key, -600, 600, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.closePosition(positionId, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
        assertEq(lpManager.nextPositionId(), nextId);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    function _exerciseAllowedTrading() internal {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) = router.swapExactInput(_swapRequest(stockInput, 1e16));
        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        SwapRequest memory request = _swapRequest(!stockInput, 1e15);
        request.limitAmount = 1e18;
        vm.prank(alice);
        (, amountOut) = router.swapExactOutput(request);
        assertEq(amountOut, 1e15);
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        _runAdapterSwap(adapter, stockInput);
        _runAdapterSwap(adapter, !stockInput);
        assertGt(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _exerciseAllowedLPLifecycle() internal {
        LPBounds memory bounds = _pauseTestBounds();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, bounds);
        lpManager.collectFees(positionId, bounds);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
        lpManager.closePosition(positionId, bounds);
        lpManager.closePosition(newId, bounds);
        vm.stopPrank();
        assertFalse(lpManager.getPosition(positionId).active);
        assertFalse(lpManager.getPosition(newId).active);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _pauseLocal(PauseScope scope, bytes32 target, PauseMode mode) internal returns (uint256) {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"), keccak256("source"));
    }

    function _submitLocalMarket(MarketAction action, PauseMode mode) internal {
        uint64 sequence = registry.marketSequence(SECURITY) + 1;
        MarketReport memory report = MarketReport(
            SECURITY,
            action,
            mode,
            keccak256("reason"),
            keccak256("exchange"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            keccak256(abi.encode("pause-mode-report", action, mode, sequence)),
            keccak256("source")
        );
        inbox.submitMarketStatus(report);
    }

    function _pauseTestBounds() internal view returns (LPBounds memory bounds) {
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Deploys and initializes a proxy for the supplied implementation and initializer data.
    function _installProxy(address target, address implementation) internal {
        vm.etch(target, type(TSVERC1967Proxy).runtimeCode);
        vm.store(target, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }

    /// @dev Deploys an initialized proxy for the supplied implementation.
    function _newProxy(address implementation, bytes memory data) internal returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    /// @dev Builds a token registration configuration for the supplied currency and security.
    function _config(address token, bytes32 securityId, address legalAdapter)
        internal
        view
        returns (TokenConfig memory c)
    {
        c.poolCurrency = token;
        uint8 tokenDecimals = ITestTokenMetadata(token).decimals();
        c.poolDecimals = tokenDecimals;
        c.securityId = securityId;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        // Stock classification follows securityId and the bound adapter.
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("backed-policy");
        c.status = TokenStatus.APPROVED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter == address(0) ? bytes32(0) : legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    /// @dev Reads an account balance in the token display denomination.
    function _displayBalance(address account) internal view returns (uint256) {
        return stockUnderlying.getUnderlyingAmountByShares(stock.balanceOf(account));
    }

    /// @dev Builds a swap request for the selected pool and trade parameters.
    function _swapRequest(bool zeroForOne, uint128 amount) internal view returns (SwapRequest memory r) {
        r.key = key;
        r.zeroForOne = zeroForOne;
        r.amountSpecified = amount;
        r.limitAmount = 1;
        r.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Funds an approved test Adapter, executes one direction, and verifies exact balance settlement.
    function _runAdapterSwap(V1TestExternalAdapter adapter, bool zeroForOne) internal {
        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address outputToken = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        vm.prank(alice);
        IERC20(inputToken).transfer(address(adapter), 1e18);
        adapter.approveToken(inputToken, address(router));

        uint256 inputBefore = IERC20(inputToken).balanceOf(address(adapter));
        uint256 outputBefore = IERC20(outputToken).balanceOf(address(adapter));
        SwapRequest memory request = _swapRequest(zeroForOne, 1e18);
        (uint256 actualIn, uint256 actualOut) = adapter.swapExactInput(router, request, alice);

        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        assertEq(inputBefore - IERC20(inputToken).balanceOf(address(adapter)), actualIn);
        assertEq(IERC20(outputToken).balanceOf(address(adapter)) - outputBefore, actualOut);
    }

    /// @dev Submits the monthly ADTV report required by the test; admission already opens the market.
    function _submitReports() internal {
        uint64 now_ = uint64(block.timestamp);
        AdtvReport memory adtv =
            AdtvReport(SECURITY, 202609, 1e24, now_ - 1, now_ + 100, 1, 1, keccak256("adtv"), keccak256("source"));
        inbox.submitAdtv(adtv);
    }
}
