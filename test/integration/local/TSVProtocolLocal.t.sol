// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {
    TokenConfig,
    AssetClass,
    SettlementMode,
    TokenStatus,
    MarketAction,
    RateSnapshot,
    LPBounds,
    SwapRequest
} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVSBTAdapterV1} from "tsv-v1/periphery/TSVSBTAdapterV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVReceiptV1} from "tsv-v1/periphery/TSVReceiptV1.sol";
import {StaticLegalShareAdapter} from "tsv-v1/adapters/StaticLegalShareAdapter.sol";
import {ERC8056LegalShareAdapter} from "tsv-v1/adapters/ERC8056LegalShareAdapter.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {IssuerShareSettlementAdapter} from "tsv-v1/adapters/IssuerShareSettlementAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";
import {ERC8056TestToken} from "../../../lib/TestToken/erc8056/ERC8056TestToken.sol";

interface ITestTokenMetadata {
    function decimals() external view returns (uint8);
}

contract V1LocalERC20 is ERC20 {
    address public blockedRecipient;
    address public feeSender;
    uint16 public senderFeeBps;
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedRecipient(address to) external {
        blockedRecipient = to;
    }

    function setSenderFee(address sender, uint16 feeBps) external {
        require(feeBps <= 10_000);
        feeSender = sender;
        senderFeeBps = feeBps;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(to == address(0) || to != blockedRecipient, "issuer blocked recipient");
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && from == feeSender && senderFeeBps != 0) {
            uint256 fee = (value * senderFeeBps) / 10_000;
            if (fee != 0) super._update(from, address(this), fee);
        }
    }
}

contract V1LocalSBT {
    mapping(address => bool) public holds;
    bool public paused;

    function setHolder(address owner, bool value) external {
        holds[owner] = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function verify(address owner, uint256) external view returns (bool) {
        return holds[owner];
    }
}

contract TSVProtocolLocalTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant REPORTER_KEY = 0xABC123;
    address private constant HOOK_ADDRESS = address(uint160(0x3FFF));
    address private constant RECEIPT_ADDRESS = address(uint160(0xBEEF0));
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant SECURITY = keccak256("SEC_A");
    uint32 private constant DAY = 20261001;

    PoolManager internal manager;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVSBTAdapterV1 internal sbtAdapter;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    TSVLPManagerV1 internal lpManager;
    TSVReceiptV1 internal receipt;
    V1LocalSBT internal sbt;
    ERC8056TestToken internal stock;
    V1LocalERC20 internal quote;
    PoolKey internal key;
    address internal alice;
    address internal reporter;
    uint256 internal positionId;

    function setUp() public {
        vm.warp(1_790_827_201);
        alice = makeAddr("alice");
        reporter = vm.addr(REPORTER_KEY);
        manager = new PoolManager(address(this));
        TSVBusinessAuthority authority = new TSVBusinessAuthority(address(this), address(0xA11CE));
        registry = TSVRegistryV1(
            _newProxy(
                address(new TSVRegistryV1()),
                abi.encodeCall(TSVRegistryV1.initialize, (address(authority), address(0xA11CE), address(0xCAFE)))
            )
        );
        ledger = TSVVolumeLedgerV1(
            _newProxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(
                    TSVVolumeLedgerV1.initialize,
                    (address(authority), address(0xA11CE), address(0xCAFE), address(registry), 14_400)
                )
            )
        );
        inbox = TSVDataInboxV1(
            _newProxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(
                    TSVDataInboxV1.initialize,
                    (address(authority), address(0xA11CE), address(0xCAFE), address(registry), address(ledger))
                )
            )
        );
        sbt = new V1LocalSBT();
        sbt.setHolder(alice, true);
        sbtAdapter = TSVSBTAdapterV1(
            _newProxy(
                address(new TSVSBTAdapterV1()),
                abi.encodeCall(
                    TSVSBTAdapterV1.initialize, (address(authority), address(0xA11CE), address(0xCAFE), address(sbt), 1)
                )
            )
        );
        router = TSVSwapRouterV1(
            _newProxy(
                address(new TSVSwapRouterV1()),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize,
                    (
                        address(authority),
                        address(0xA11CE),
                        address(0xCAFE),
                        address(manager),
                        address(registry),
                        address(ledger),
                        address(sbtAdapter),
                        HOOK_ADDRESS
                    )
                )
            )
        );
        lpManager = TSVLPManagerV1(
            _newProxy(
                address(new TSVLPManagerV1()),
                abi.encodeCall(
                    TSVLPManagerV1.initialize,
                    (
                        address(authority),
                        address(0xA11CE),
                        address(0xCAFE),
                        address(manager),
                        address(registry),
                        address(sbtAdapter),
                        RECEIPT_ADDRESS
                    )
                )
            )
        );
        receipt = TSVReceiptV1(RECEIPT_ADDRESS);
        _installProxy(RECEIPT_ADDRESS, address(new TSVReceiptV1()));
        receipt.initialize(address(authority), address(0xA11CE), address(0xCAFE), address(lpManager));
        hook = TSVHookV1(HOOK_ADDRESS);
        _installProxy(HOOK_ADDRESS, address(new TSVHookV1()));
        hook.initialize(
            address(authority),
            address(0xA11CE),
            address(0xCAFE),
            address(manager),
            address(registry),
            address(ledger),
            address(router),
            address(lpManager)
        );
        registry.bindComponents(address(hook), address(lpManager), address(inbox));
        ledger.bindWriters(address(hook), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        lpManager.grantRole(lpManager.POOL_CREATOR_ROLE(), address(this));
        lpManager.grantRole(lpManager.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), reporter);
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), reporter);
        registry.setTierPolicy(1, 10_000, 10, keccak256("tier"));
        registry.listSecurity(SECURITY, keccak256("STDx"), 1, keccak256("list"));
        stock = new ERC8056TestToken("STDx", "STDx", 18, 0);
        quote = new V1LocalERC20("QUOTE");
        ERC8056LegalShareAdapter adapter = new ERC8056LegalShareAdapter(address(stock), 1);
        registry.registerToken(_config(address(stock), SECURITY, address(adapter)), keccak256("stock"));
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve"));
        registry.setTokenStatus(address(quote), TokenStatus.APPROVED, keccak256("approve"));
        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        lpManager.initializePool(key, uint160(1 << 96), keccak256("price"));
        _submitReports();
        stock.mint(alice, 1e24);
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
    }

    function testRealV4OnePoolSwapAccountsActualDelta() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint160(address(hook)) & uint160(0x3FFF), uint160(0x3FFF));
        assertEq(receipt.ownerOf(positionId), alice);
        assertTrue(registry.isTradable(poolId));
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        SwapRequest memory request = _swapRequest(stockInput, 1e18, 1);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request, "");
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        uint256 used = ledger.used(SECURITY, DAY) - beforeUsed;
        assertEq(used, actualIn);
    }

    function testRealV4StockOutputCountsNetReceived() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(!stockIsCurrency0, 1e18, 2);
        vm.prank(alice);
        (, uint256 actualOut) = router.swapExactInput(request, "");
        assertEq(ledger.used(SECURITY, DAY), actualOut);
    }

    function testSwapRevertsIfPayerLosesMoreThanRawDelta() public {
        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        quote.setSenderFee(alice, 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(quoteIsCurrency0, 1e18, 701), "");
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertFalse(router.nonceUnavailable(alice, 701));
    }

    function testERC8056StockSwapBothWaysUsesDynamicUiMultiplier() public {
        assertTrue(stock.supportsInterface(0xa60bf13d));
        assertTrue(stock.supportsInterface(0x4bd27648));
        assertTrue(stock.supportsInterface(0x57854fc3));
        assertTrue(stock.supportsInterface(0xd890fd71));

        uint256 aliceRawBeforeUpdate = stock.balanceOf(alice);
        uint256 managerRawBeforeUpdate = stock.balanceOf(address(manager));
        stock.setUIMultiplier(2e18, block.timestamp + 2);
        assertEq(stock.uiMultiplier(), 1e18);
        assertEq(stock.balanceOf(alice), aliceRawBeforeUpdate);
        assertEq(stock.balanceOfUI(alice), aliceRawBeforeUpdate);

        vm.warp(block.timestamp + 2);
        assertEq(stock.uiMultiplier(), 2e18);
        assertEq(stock.balanceOf(alice), aliceRawBeforeUpdate);
        assertEq(stock.balanceOf(address(manager)), managerRawBeforeUpdate);
        assertEq(stock.balanceOfUI(alice), aliceRawBeforeUpdate * 2);
        assertEq(stock.balanceOfUI(address(manager)), managerRawBeforeUpdate * 2);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceUIBefore = stock.balanceOfUI(alice);
        vm.prank(alice);
        (uint256 stockIn, uint256 quoteOut) = router.swapExactInput(_swapRequest(stockIsCurrency0, 1e18, 801), "");
        assertGt(stockIn, 0);
        assertGt(quoteOut, 0);
        assertEq(aliceRawBefore - stock.balanceOf(alice), stockIn);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockIn);
        assertEq(aliceUIBefore - stock.balanceOfUI(alice), stockIn * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceUIBefore = stock.balanceOfUI(alice);
        usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactInput(_swapRequest(!stockIsCurrency0, 1e18, 802), "");
        assertGt(quoteIn, 0);
        assertGt(stockOut, 0);
        assertEq(stock.balanceOf(alice) - aliceRawBefore, stockOut);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockOut);
        assertEq(stock.balanceOfUI(alice) - aliceUIBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    function testERC8056StockLPIncreaseAndDecreaseSettleRawAmounts() public {
        stock.setUIMultiplier(2e18, block.timestamp + 1);
        vm.warp(block.timestamp + 1);

        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceUIBefore = stock.balanceOfUI(alice);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawIn = aliceRawBefore - stock.balanceOf(alice);
        assertGt(stockRawIn, 0);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockRawIn);
        assertEq(aliceUIBefore - stock.balanceOfUI(alice), stockRawIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceUIBefore = stock.balanceOfUI(alice);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawOut = stock.balanceOf(alice) - aliceRawBefore;
        assertGt(stockRawOut, 0);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockRawOut);
        assertEq(stock.balanceOfUI(alice) - aliceUIBefore, stockRawOut * 2);

        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
    }

    function testLPIncreaseRevertsIfOwnerLosesMoreThanPoolDelta() public {
        quote.setSenderFee(alice, 100);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
    }

    function testDirectLpLifecycleDoesNotRecordLiquidityAsTradeVolume() public {
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
        router.swapExactInput(_swapRequest(stockInput, 1e18, 90), "");
        uint256 usedAfterSwap = ledger.used(SECURITY, DAY);
        assertGt(usedAfterSwap, usedBefore);
        vm.startPrank(alice);
        lpManager.collectFees(positionId, bounds);
        lpManager.closePosition(positionId, bounds);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedAfterSwap);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        receipt.ownerOf(positionId);
    }

    function testExactOutputRequiresFullDelivery() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockIsCurrency0, 1e18, 3);
        request.exactInput = false;
        request.limitAmount = 2e18;
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request, "");
        assertEq(actualOut, 1e18);
        assertLe(actualIn, 2e18);
    }

    function testDirectPoolManagerSwapCannotBypassHook() public {
        vm.expectRevert();
        manager.unlock(abi.encode(key));
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        PoolKey memory target = abi.decode(data, (PoolKey));
        manager.swap(target, IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1), "");
        return "";
    }

    function testForceExitWhenSbtRevokedReturnsOriginalOwnerAssets() public {
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, keccak256("revoke"), keccak256("evidence"));
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(quote.balanceOf(alice), quoteBefore);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        receipt.ownerOf(positionId);
    }

    function testForceExitAdminCanActWhenAlsoRevokeExecutorAndOwnerStillHasSbt() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        assertTrue(sbtAdapter.hasCredential(alice));
        lpManager.forceExit(positionId, keccak256("incident"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
    }

    function testForceExitRejectsOriginalOwnerRollsBackEverything() public {
        sbt.setHolder(alice, false);
        quote.setBlockedRecipient(alice);
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeQuote = quote.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        uint128 beforeLiquidity = lpManager.getPosition(positionId).liquidity;
        vm.expectRevert();
        lpManager.forceExit(positionId, keccak256("revoke"), keccak256("evidence"));
        assertEq(stock.balanceOf(alice), beforeStock);
        assertEq(quote.balanceOf(alice), beforeQuote);
        assertEq(ledger.used(SECURITY, DAY), beforeUsed);
        assertEq(lpManager.getPosition(positionId).liquidity, beforeLiquidity);
        assertEq(receipt.ownerOf(positionId), alice);
    }

    function testSbtPauseBlocksUserSwapButNotForceExit() public {
        sbt.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        router.swapExactInput(_swapRequest(true, 1e18, 1), "");
        vm.expectRevert();
        lpManager.forceExit(positionId, keccak256("reason"), keccak256("evidence"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, keccak256("reason"), keccak256("evidence"));
    }

    function testLegacyIssuerWrappedSettlementPathIsRejected() public {
        bytes32 security = keccak256("TSLA");
        registry.listSecurity(security, keccak256("TSLAx"), 1, keccak256("list-tsla"));
        V1MockIssuerShares tsla = new V1MockIssuerShares();
        tsla.setMultiplier(0.9e18, 7);
        V1MockIssuerWrapped wtsla = new V1MockIssuerWrapped(tsla);
        IssuerShareSettlementAdapter issuerAdapter =
            new IssuerShareSettlementAdapter(address(tsla), address(wtsla), address(router), address(lpManager));
        BackedAutoFeeLegalShareAdapter legal = new BackedAutoFeeLegalShareAdapter(address(tsla), address(wtsla), 1);
        TokenConfig memory c;
        c.userToken = address(tsla);
        c.poolCurrency = address(wtsla);
        c.userDecimals = 18;
        c.poolDecimals = 18;
        c.assetClass = AssetClass.ISSUER_WRAPPED_DYNAMIC;
        c.securityId = security;
        c.settlementMode = SettlementMode.ISSUER_SHARE_WRAPPED;
        c.settlementAdapter = address(issuerAdapter);
        c.settlementVersion = 1;
        c.legalShareAdapter = address(legal);
        c.legalAdapterVersion = 1;
        c.ratioEvidenceHash = keccak256("ratio-tsla");
        c.status = TokenStatus.UNREVIEWED;
        c.userRuntimeCodeHash = address(tsla).codehash;
        c.poolRuntimeCodeHash = address(wtsla).codehash;
        c.settlementAdapterCodeHash = address(issuerAdapter).codehash;
        c.legalAdapterCodeHash = address(legal).codehash;
        c.reviewHash = keccak256("review-tsla");
        // V1 settles the pool Currency directly. An issuer-side TSLAx ->
        // wTSLAx settlement adapter is intentionally outside the admission ABI.
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(c, keccak256("register-tsla"));
        assertEq(registry.currencyOf(address(tsla)), address(0));
        assertEq(registry.currencyOf(address(wtsla)), address(0));
    }

    function _installProxy(address target, address implementation) private {
        TSVERC1967Proxy template = new TSVERC1967Proxy(implementation, "");
        vm.etch(target, address(template).code);
        vm.store(target, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }

    function _newProxy(address implementation, bytes memory data) private returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    function _config(address token, bytes32 securityId, address legalAdapter)
        private
        view
        returns (TokenConfig memory c)
    {
        c.userToken = token;
        c.poolCurrency = token;
        uint8 tokenDecimals = ITestTokenMetadata(token).decimals();
        c.userDecimals = tokenDecimals;
        c.poolDecimals = tokenDecimals;
        c.assetClass = securityId == 0 ? AssetClass.QUOTE_ERC20 : AssetClass.ONCHAIN_DYNAMIC;
        c.securityId = securityId;
        c.settlementMode = SettlementMode.DIRECT_ERC20;
        c.settlementVersion = 1;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        // Dynamic ERC-8056 stock uses the adapter's live multiplier; Registry
        // must not carry a second static ratio copy.
        c.sharesPerWholeTokenWad = 0;
        c.ratioEvidenceHash = bytes32(0);
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("erc8056-policy");
        c.status = TokenStatus.UNREVIEWED;
        c.userRuntimeCodeHash = token.codehash;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    function _swapRequest(bool zeroForOne, uint128 amount, uint256 nonce) private view returns (SwapRequest memory r) {
        r.key = key;
        r.participant = alice;
        r.payer = alice;
        r.recipient = alice;
        r.zeroForOne = zeroForOne;
        r.exactInput = true;
        r.amountSpecified = amount;
        r.limitAmount = 1;
        r.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        r.nonce = nonce;
        r.deadline = uint64(block.timestamp + 100);
    }

    function _sign(bytes32 typeHash, bytes memory encodedReport) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TSVDataInbox"),
                keccak256("2"),
                block.chainid,
                address(inbox)
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encodePacked(typeHash, encodedReport))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(REPORTER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submitReports() private {
        uint64 now_ = uint64(block.timestamp);
        MarketReport memory market = MarketReport(
            reporter,
            SECURITY,
            MarketAction.INITIAL_OPEN,
            keccak256("open"),
            keccak256("exchange"),
            now_ - 1,
            now_ + 100,
            1,
            keccak256("market"),
            keccak256("source")
        );
        inbox.submitMarketStatus(market, _sign(inbox.MARKET_TYPEHASH(), abi.encode(market)));
        AdtvReport memory adtv = AdtvReport(
            reporter, SECURITY, 202609, 1e24, now_ - 1, now_ + 100, 1, 1, keccak256("adtv"), keccak256("source")
        );
        inbox.submitAdtv(adtv, _sign(inbox.ADTV_TYPEHASH(), abi.encode(adtv)));
    }
}
