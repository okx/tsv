// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TokenConfig, TokenStatus, MarketAction, LPBounds, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";

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
    bool private paused_;
    bool public failVerify;
    bool public failPaused;

    function setHolder(address owner, bool value) external {
        holds[owner] = value;
    }

    function setPaused(bool value) external {
        paused_ = value;
    }

    function setFailReads(bool verify_, bool pausedRead_) external {
        failVerify = verify_;
        failPaused = pausedRead_;
    }

    function paused() external view returns (bool) {
        require(!failPaused, "paused read failed");
        return paused_;
    }

    function verify(address owner, uint256) external view returns (bool) {
        require(!failVerify, "verify read failed");
        return holds[owner];
    }
}

contract V1TestParticipantWallet {
    address public immutable admin;

    constructor(address admin_) {
        admin = admin_;
    }

    function approveToken(address token, address spender) external {
        require(msg.sender == admin);
        IERC20(token).approve(spender, type(uint256).max);
    }

    function swapExactInput(TSVSwapRouterV1 router, SwapRequest calldata request)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        require(msg.sender == admin);
        return router.swapExactInput(request);
    }
}

contract TSVProtocolLocalTest is Test {
    using PoolIdLibrary for PoolKey;

    address private constant HOOK_ADDRESS = address(uint160(0x3FFF));
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant SECURITY = keccak256("SEC_A");
    uint32 private constant DAY = 20261001;

    PoolManager internal manager;
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

    function setUp() public {
        vm.warp(1_790_827_201);
        alice = makeAddr("alice");
        manager = new PoolManager(address(this));
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        address guardian = makeAddr("guardian");
        TSVUpgradeTimelock timelock = new TSVUpgradeTimelock(address(this), guardian, makeAddr("council"), executors);
        TSVBusinessAuthority authority = new TSVBusinessAuthority(address(this), address(timelock));
        TSVEmergencyUpgradeController controller =
            new TSVEmergencyUpgradeController(address(this), guardian, address(timelock));
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(timelock), address(authority), address(controller));
        registry = TSVRegistryV1(
            _newProxy(
                address(new TSVRegistryV1()),
                abi.encodeCall(TSVRegistryV1.initialize, (address(anchor), address(timelock), address(controller)))
            )
        );
        ledger = TSVVolumeLedgerV1(
            _newProxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(
                    TSVVolumeLedgerV1.initialize,
                    (address(anchor), address(timelock), address(controller), address(registry), 14_400)
                )
            )
        );
        inbox = TSVDataInboxV1(
            _newProxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(
                    TSVDataInboxV1.initialize,
                    (address(anchor), address(timelock), address(controller), address(registry), address(ledger))
                )
            )
        );
        sbt = new V1LocalSBT();
        sbt.setHolder(alice, true);
        registry.setSbtConfig(address(sbt), 1, keccak256("sbt-config"));
        router = TSVSwapRouterV1(
            _newProxy(
                address(new TSVSwapRouterV1()),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize,
                    (
                        address(anchor),
                        address(timelock),
                        address(controller),
                        address(manager),
                        address(registry),
                        address(ledger),
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
                    (address(anchor), address(timelock), address(controller), address(manager), address(registry))
                )
            )
        );
        hook = TSVHookV1(HOOK_ADDRESS);
        _installProxy(HOOK_ADDRESS, address(new TSVHookV1()));
        hook.initialize(
            address(anchor),
            address(timelock),
            address(controller),
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
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 10_000, 10, keccak256("tier"));
        registry.listSecurity(SECURITY, keccak256("STDx"), 1, keccak256("list"));
        stockUnderlying = new V1MockIssuerShares();
        stock = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1LocalERC20("QUOTE");
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        registry.registerToken(_config(address(stock), SECURITY, address(adapter)), keccak256("stock"));
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve"));
        registry.setTokenStatus(address(quote), TokenStatus.APPROVED, keccak256("approve"));
        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        lpManager.initializePool(key, uint160(1 << 96), keccak256("price"));
        _submitReports();
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
    }

    function testRealV4OnePoolSwapAccountsActualDelta() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint160(address(hook)) & uint160(0x3FFF), uint160(0x3FFF));
        assertEq(lpManager.ownerOf(positionId), alice);
        assertTrue(registry.isTradable(poolId));
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        uint256 used = ledger.used(SECURITY, DAY) - beforeUsed;
        assertEq(used, actualIn);
    }

    function testLpManagerHostsNonTransferableReceipt() public {
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(lpManager.balanceOf(alice), 1);
        assertTrue(lpManager.supportsInterface(0x80ac58cd));

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.transferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.safeTransferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.approve(address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.setApprovalForAll(address(this), true);
    }

    function testRealV4StockOutputCountsNetReceived() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(!stockIsCurrency0, 1e18);
        vm.prank(alice);
        (, uint256 actualOut) = router.swapExactInput(request);
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
        router.swapExactInput(_swapRequest(quoteIsCurrency0, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function testSwapRevertsIfPoolLosesMoreThanOutputDelta() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        quote.setSenderFee(address(manager), 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function testSwapMustBeSubmittedByParticipant() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.swapExactInput(request);

        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    function testContractWalletCanDirectlySubmitSwap() public {
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.approveToken(address(stock), address(router));
        wallet.approveToken(address(quote), address(router));

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);
        request.participant = address(wallet);
        request.payer = address(wallet);
        request.recipient = address(wallet);

        (uint256 actualIn, uint256 actualOut) = wallet.swapExactInput(router, request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    function testBackedStockSwapBothWaysUsesLiveIssuerConversion() public {
        uint256 aliceRawBeforeUpdate = stock.balanceOf(alice);
        uint256 managerRawBeforeUpdate = stock.balanceOf(address(manager));
        stockUnderlying.setMultiplier(2e18, 1);
        assertEq(stock.balanceOf(alice), aliceRawBeforeUpdate);
        assertEq(stock.balanceOf(address(manager)), managerRawBeforeUpdate);
        assertEq(_displayBalance(alice), aliceRawBeforeUpdate * 2);
        assertEq(_displayBalance(address(manager)), managerRawBeforeUpdate * 2);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        (uint256 stockIn, uint256 quoteOut) = router.swapExactInput(_swapRequest(stockIsCurrency0, 1e18));
        assertGt(stockIn, 0);
        assertGt(quoteOut, 0);
        assertEq(aliceRawBefore - stock.balanceOf(alice), stockIn);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockIn * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactInput(_swapRequest(!stockIsCurrency0, 1e18));
        assertGt(quoteIn, 0);
        assertGt(stockOut, 0);
        assertEq(stock.balanceOf(alice) - aliceRawBefore, stockOut);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    function testBackedStockLPIncreaseAndDecreaseSettleRawAmounts() public {
        stockUnderlying.setMultiplier(2e18, 1);

        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawIn = aliceRawBefore - stock.balanceOf(alice);
        assertGt(stockRawIn, 0);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockRawIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockRawIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawOut = stock.balanceOf(alice) - aliceRawBefore;
        assertGt(stockRawOut, 0);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockRawOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockRawOut * 2);

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

    function testLpExitRevertsIfPoolLosesMoreThanOutputDelta() public {
        quote.setSenderFee(address(manager), 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        LPBounds memory bounds;
        bounds.deadline = uint64(block.timestamp + 100);

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    function testClosePositionEnforcesMinimumForZeroDeltaCurrency() public {
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        vm.prank(alice);
        uint256 boundaryPositionId = lpManager.openPosition(key, 0, 60, 1e18, bounds);

        bounds.minPoolOut1 = 1;
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.closePosition(boundaryPositionId, bounds);

        TSVLPManagerV1.Position memory position = lpManager.getPosition(boundaryPositionId);
        assertTrue(position.active);
        assertEq(position.liquidity, 1e18);
        assertEq(lpManager.ownerOf(boundaryPositionId), alice);
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

    function testExactOutputRequiresFullDelivery() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockIsCurrency0, 1e18);
        request.exactInput = false;
        request.limitAmount = 2e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
        assertEq(actualOut, 1e18);
        assertLe(actualIn, 2e18);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, actualIn);
    }

    function testExactOutputStockPurchaseRecordsNetShares() public {
        stockUnderlying.setMultiplier(2e18, 1);

        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(quoteIsCurrency0, 1e18);
        request.exactInput = false;
        request.limitAmount = 2e18;
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 displayedBefore = _displayBalance(alice);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactOutput(request);

        assertLe(quoteIn, request.limitAmount);
        assertEq(stockOut, request.amountSpecified);
        assertEq(quoteBefore - quote.balanceOf(alice), quoteIn);
        assertEq(stock.balanceOf(alice) - stockBefore, stockOut);
        assertEq(_displayBalance(alice) - displayedBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
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
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"), keccak256("evidence"));
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(quote.balanceOf(alice), quoteBefore);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        lpManager.ownerOf(positionId);
    }

    function testForceExitAdminCanActWhenAlsoRevokeExecutorAndOwnerStillHasSbt() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        assertTrue(registry.hasCredential(alice));
        lpManager.forceExit(positionId, 1, 1, keccak256("incident"), keccak256("evidence"));
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
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
        assertEq(stock.balanceOf(alice), beforeStock);
        assertEq(quote.balanceOf(alice), beforeQuote);
        assertEq(ledger.used(SECURITY, DAY), beforeUsed);
        assertEq(lpManager.getPosition(positionId).liquidity, beforeLiquidity);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    function testSbtPauseBlocksUserSwapButNotForceExit() public {
        assertTrue(registry.isEligible(alice));
        sbt.setPaused(true);
        assertFalse(registry.isEligible(alice));
        vm.prank(alice);
        vm.expectRevert();
        router.swapExactInput(_swapRequest(true, 1e18));
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
    }

    function testSbtReadFailuresDoNotBecomeRevocationSignals() public {
        sbt.setFailReads(true, false);
        vm.expectRevert();
        registry.hasCredential(alice);
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        assertEq(lpManager.ownerOf(positionId), alice);

        sbt.setFailReads(false, true);
        vm.expectRevert();
        registry.isEligible(alice);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    function testRegistryRejectsSbtWithoutRequiredSelectors() public {
        address oldSbt = address(registry.participantSbt());
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(quote), 1, keccak256("bad-sbt"));
        assertEq(address(registry.participantSbt()), oldSbt);
        assertTrue(registry.isEligible(alice));
    }

    function testForceExitEnforcesBothMinimumOutputsAtomically() public {
        sbt.setHolder(alice, false);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, type(uint256).max, 0, keccak256("revoke"), keccak256("evidence"));

        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, 0, type(uint256).max, keccak256("revoke"), keccak256("evidence"));

        TSVLPManagerV1.Position memory position = lpManager.getPosition(positionId);
        assertTrue(position.active);
        assertEq(position.liquidity, liquidityBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(stock.balanceOf(alice), stockBefore);
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _installProxy(address target, address implementation) private {
        vm.etch(target, type(TSVERC1967Proxy).runtimeCode);
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
        c.poolCurrency = token;
        uint8 tokenDecimals = ITestTokenMetadata(token).decimals();
        c.poolDecimals = tokenDecimals;
        c.securityId = securityId;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        // Stock classification follows securityId and the bound adapter.
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("backed-policy");
        c.status = TokenStatus.UNREVIEWED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    function _displayBalance(address account) private view returns (uint256) {
        return stockUnderlying.getUnderlyingAmountByShares(stock.balanceOf(account));
    }

    function _swapRequest(bool zeroForOne, uint128 amount) private view returns (SwapRequest memory r) {
        r.key = key;
        r.participant = alice;
        r.payer = alice;
        r.recipient = alice;
        r.zeroForOne = zeroForOne;
        r.exactInput = true;
        r.amountSpecified = amount;
        r.limitAmount = 1;
        r.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        r.deadline = uint64(block.timestamp + 100);
    }

    function _submitReports() private {
        uint64 now_ = uint64(block.timestamp);
        MarketReport memory market = MarketReport(
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
        inbox.submitMarketStatus(market);
        AdtvReport memory adtv =
            AdtvReport(SECURITY, 202609, 1e24, now_ - 1, now_ + 100, 1, 1, keccak256("adtv"), keccak256("source"));
        inbox.submitAdtv(adtv);
    }
}
