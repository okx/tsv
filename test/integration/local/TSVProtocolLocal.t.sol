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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {
    TokenConfig,
    TokenStatus,
    PoolStatus,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode,
    LPOperationMode,
    LPHookContext,
    LPBounds,
    SwapRequest
} from "tsv-v1/types/TSVTypes.sol";
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

/// @dev Exposes token metadata required by the local integration fixture.
interface ITestTokenMetadata {
    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() external view returns (uint8);
}

/// @dev Provides a configurable ERC-20 fixture for local protocol tests.
contract V1LocalERC20 is ERC20 {
    address public blockedRecipient;
    address public feeSender;
    uint16 public senderFeeBps;

    /// @dev Initializes the local token fixture with matching name and symbol.
    constructor(string memory n) ERC20(n, n) {}

    /// @dev Mints local test tokens to a recipient.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Configures whether the local token rejects transfers to a recipient.
    function setBlockedRecipient(address to) external {
        blockedRecipient = to;
    }

    /// @dev Configures the fee deducted from the sender by the local token.
    function setSenderFee(address sender, uint16 feeBps) external {
        require(feeBps <= 10_000);
        feeSender = sender;
        senderFeeBps = feeBps;
    }

    /// @dev Applies the local token transfer behavior, including configured fees and restrictions.
    function _update(address from, address to, uint256 value) internal override {
        require(to == address(0) || to != blockedRecipient, "issuer blocked recipient");
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && from == feeSender && senderFeeBps != 0) {
            uint256 fee = (value * senderFeeBps) / 10_000;
            if (fee != 0) super._update(from, address(this), fee);
        }
    }
}

/// @dev Provides configurable SBT pause and credential behavior for local tests.
contract V1LocalSBT {
    mapping(address => bool) public holds;
    bool private paused_;
    bool public failVerify;
    bool public failPaused;

    /// @dev Configures the holder and token identifier accepted by the local SBT fixture.
    function setHolder(address owner, bool value) external {
        holds[owner] = value;
    }

    /// @dev Configures the pause state reported by the local SBT fixture.
    function setPaused(bool value) external {
        paused_ = value;
    }

    /// @dev Configures whether SBT view calls revert in the local fixture.
    function setFailReads(bool verify_, bool pausedRead_) external {
        failVerify = verify_;
        failPaused = pausedRead_;
    }

    /// @dev Returns the pause state reported by the local SBT fixture.
    function paused() external view returns (bool) {
        require(!failPaused, "paused read failed");
        return paused_;
    }

    /// @dev Checks the configured participant credential in the local SBT fixture.
    function verify(address owner, uint256) external view returns (bool) {
        require(!failVerify, "verify read failed");
        return holds[owner];
    }
}

/// @dev Provides a contract-wallet participant for direct-call integration tests.
contract V1TestParticipantWallet {
    address public immutable admin;

    /// @dev Sets the account authorized to execute calls through the participant wallet.
    constructor(address admin_) {
        admin = admin_;
    }

    /// @dev Approves the Swap Router to transfer a selected input token.
    function approveToken(address token, address spender) external {
        require(msg.sender == admin);
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Runs an exact-input swap through the test participant wallet.
    function swapExactInput(TSVSwapRouterV1 router, SwapRequest calldata request)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        require(msg.sender == admin);
        return router.swapExactInput(request);
    }
}

/// @dev Routes a test swap through the Router's external Adapter entry.
contract V1TestExternalAdapter {
    /// @dev Approves the Router to pull the test Adapter's input Currency.
    function approveToken(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Executes a Router exact-input swap for the supplied participant.
    function swapExactInput(TSVSwapRouterV1 router, SwapRequest calldata request, address participant)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        return router.swapExactInputFromAdapter(request, participant);
    }
}

/// @dev Exercises the protocol against a local Uniswap V4 pool manager.
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

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
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
                        address(ledger)
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

    function testAdmissionOpensRealV4PoolWithoutMarketReport() public view {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint8(registry.getToken(address(stock)).status), uint8(TokenStatus.APPROVED));
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.OPEN));
        assertEq(registry.marketSequence(SECURITY), 0);
        assertEq(inbox.lastSequence(0, SECURITY), 0);
        assertTrue(registry.isTradable(poolId));
        assertTrue(registry.isLPAllowed(poolId));
        assertGt(lpManager.getPosition(positionId).liquidity, 0);
    }

    function testMissingAdtvAllowsLiquidityButSwapRevertsAtomically() public {
        uint32 day = 20261101;
        vm.warp(ledger.dayStartUTC(day) + 1);
        (bool valid,) = ledger.remaining(SECURITY, day);
        assertFalse(valid);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, _pauseTestBounds());
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        bytes32 beforeState = _swapStateDigest(day);
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(TSVVolumeLedgerV1.MissingReport.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
        uint64 now_ = uint64(block.timestamp);
        inbox.submitAdtv(
            AdtvReport(SECURITY, 202610, 1e24, now_ - 1, now_ + 100, 1, 2, keccak256("nov-adtv"), keccak256("source"))
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertGt(ledger.used(SECURITY, day), 0);
    }

    function testPoolInitializationFailureLeavesNoPendingRecordOrCounts() public {
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        uint32 stockCount = registry.activePoolCountByCurrency(address(stock));
        uint32 quoteCount = registry.activePoolCountByCurrency(address(quote));
        vm.expectRevert();
        lpManager.initializePool(otherPool, 0, keccak256("bad-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ABSENT));
        assertFalse(registry.isKnownPool(otherPoolId));
        assertEq(registry.activePoolCountByCurrency(address(stock)), stockCount);
        assertEq(registry.activePoolCountByCurrency(address(quote)), quoteCount);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(otherPoolId));
        assertEq(price, 0);
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("correct-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ACTIVE));
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
    }

    function _swapStateDigest(uint32 day) private view returns (bytes32) {
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
                stock.balanceOf(alice),
                quote.balanceOf(alice),
                stock.balanceOf(address(router)),
                quote.balanceOf(address(router)),
                stock.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                stock.balanceOf(address(lpManager)),
                quote.balanceOf(address(lpManager)),
                lpManager.getPosition(positionId),
                lpManager.ownerOf(positionId),
                ledger.used(SECURITY, day)
            )
        );
    }

    /// @dev Verifies a real V4 pool swap accounts for the actual deltas.
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

    /// @dev Verifies an allowlisted Adapter uses the shared request for both directions and settles to itself.
    function testAllowlistedAdapterUsesSharedSwapRequestBothDirections() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        _runAdapterSwap(adapter, stockIsCurrency0);
        _runAdapterSwap(adapter, !stockIsCurrency0);
    }

    /// @dev Verifies the Adapter entry rejects callers outside the Router allowlist.
    function testAdapterEntryRejectsUnallowlistedCaller() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        router.swapExactInputFromAdapter(request, alice);
    }

    /// @dev Verifies an allowlisted Adapter cannot use an ineligible participant identity.
    function testAllowlistedAdapterRequiresEligibleParticipant() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        bool zeroForOne = address(stock) == Currency.unwrap(key.currency0);
        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        vm.prank(alice);
        IERC20(inputToken).transfer(address(adapter), 1e18);
        adapter.approveToken(inputToken, address(router));

        SwapRequest memory request = _swapRequest(zeroForOne, 1e18);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        adapter.swapExactInput(router, request, makeAddr("ineligible"));
    }

    /// @dev Verifies the LP Manager issues a non-transferable position receipt.
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

    /// @dev Verifies real V4 stock output records the net amount received.
    function testRealV4StockOutputCountsNetReceived() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(!stockIsCurrency0, 1e18);
        vm.prank(alice);
        (, uint256 actualOut) = router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), actualOut);
    }

    /// @dev Verifies swaps revert when the payer loses more than the raw input delta.
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

    /// @dev Verifies swaps revert when the pool loses more than the output delta.
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

    /// @dev Verifies swaps require an eligible direct caller.
    function testSwapRequiresEligibleDirectCaller() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        router.swapExactInput(request);

        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies an eligible contract wallet can submit a swap directly.
    function testContractWalletCanDirectlySubmitSwap() public {
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.approveToken(address(stock), address(router));
        wallet.approveToken(address(quote), address(router));

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        (uint256 actualIn, uint256 actualOut) = wallet.swapExactInput(router, request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies backed stock swaps in both directions use live issuer conversion.
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

    /// @dev Verifies backed stock LP increases and decreases settle raw token amounts.
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

    /// @dev Verifies LP increases revert when the owner loses more than the pool delta.
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

    /// @dev Verifies LP exits revert when the pool loses more than the output delta.
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

    /// @dev Verifies position close enforces the minimum output for a zero-delta Currency.
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

    /// @dev Verifies the direct LP lifecycle does not record liquidity as trade volume.
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

    /// @dev Verifies exact-output swaps deliver the full requested amount.
    function testExactOutputRequiresFullDelivery() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockIsCurrency0, 1e18);
        request.limitAmount = 2e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
        assertEq(actualOut, 1e18);
        assertLe(actualIn, 2e18);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, actualIn);
    }

    /// @dev Verifies exact-output stock purchases record net shares received.
    function testExactOutputStockPurchaseRecordsNetShares() public {
        stockUnderlying.setMultiplier(2e18, 1);

        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(quoteIsCurrency0, 1e18);
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

    /// @dev Verifies direct PoolManager swaps cannot bypass the Hook.
    function testDirectPoolManagerSwapCannotBypassHook() public {
        vm.expectRevert();
        manager.unlock(abi.encode(key));
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    /// @dev Implements the PoolManager unlock callback used to test direct swap access.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        PoolKey memory target = abi.decode(data, (PoolKey));
        manager.swap(target, IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1), "");
        return "";
    }

    /// @dev Verifies force exit returns the original owner assets after SBT revocation.
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

    /// @dev Verifies a force-exit admin can act as revoke executor while the owner still holds an SBT.
    function testForceExitAdminCanActWhenAlsoRevokeExecutorAndOwnerStillHasSbt() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        assertTrue(registry.hasCredential(alice));
        lpManager.forceExit(positionId, 1, 1, keccak256("incident"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
    }

    /// @dev Verifies force exit by the original owner reverts atomically.
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

    /// @dev Verifies an SBT pause blocks user swaps but allows force exit.
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

    /// @dev Verifies failed SBT reads are not treated as revocation.
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

    /// @dev Verifies the Registry rejects an SBT that lacks required selectors.
    function testRegistryRejectsSbtWithoutRequiredSelectors() public {
        address oldSbt = address(registry.participantSbt());
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(quote), 1, keccak256("bad-sbt"));
        assertEq(address(registry.participantSbt()), oldSbt);
        assertTrue(registry.isEligible(alice));
    }

    /// @dev Verifies force exit enforces both minimum outputs atomically.
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

    function testEmergencyTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, false);
    }

    function testEmergencyLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, false);
    }

    function testEmergencyAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, false);
    }

    function testMarketTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, true);
    }

    function testMarketLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, true);
    }

    function testMarketAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, true);
    }

    function testMarketAndEmergencyPausesRecoverSeparatelyWithRealV4() public {
        _seedPauseTestFees();
        _submitLocalMarket(MarketAction.HALT, PauseMode.LP);
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        _submitLocalMarket(MarketAction.RESUME, PauseMode.LP);
        _assertTradingBlocked();
        _exerciseAllowedLPLifecycle();
        registry.clearEmergencyPause(id, keccak256("resume"));
        vm.prank(alice);
        positionId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
        _exerciseAllowedTrading();
    }

    function testForceExitBypassesEveryEmergencyAndMarketPauseMode() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        for (uint8 mode = 1; mode <= 3; mode++) {
            _submitLocalMarket(MarketAction.HALT, PauseMode(mode));
            uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode(mode));
            uint256 stockBefore = stock.balanceOf(alice);
            uint256 quoteBefore = quote.balanceOf(alice);
            lpManager.forceExit(positionId, 1, 1, keccak256("pause-exit"), keccak256("evidence"));
            assertFalse(lpManager.getPosition(positionId).active);
            assertGt(stock.balanceOf(alice), stockBefore);
            assertGt(quote.balanceOf(alice), quoteBefore);
            vm.expectRevert();
            lpManager.ownerOf(positionId);
            registry.clearEmergencyPause(id, keccak256("resume"));
            _submitLocalMarket(MarketAction.RESUME, PauseMode.ALL);
            if (mode != uint8(PauseMode.ALL)) {
                vm.prank(alice);
                positionId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
            }
        }
    }

    function testHookIndependentlyChecksTradingAndLPPauses() public {
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, swapParams, "");
        registry.clearEmergencyPause(id, keccak256("resume"));
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.LP);
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(router), key, swapParams, "");
        assertEq(selector, IHooks.beforeSwap.selector);

        LPHookContext memory ctx = LPHookContext(
            PoolId.unwrap(key.toId()), -600, 600, LPOperationMode.INCREASE, bytes32(positionId), int256(1e18)
        );
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-600, 600, int256(1e18), bytes32(positionId));
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(lpManager), key, params, "");
        ctx.mode = LPOperationMode.COLLECT;
        ctx.liquidityDelta = 0;
        params.liquidityDelta = 0;
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(address(lpManager), key, params, "");
    }

    function testPoolInitializationRemainsAllowedDuringAllPauses() public {
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.ALL);
        _submitLocalMarket(MarketAction.HALT, PauseMode.ALL);
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("paused-price"));
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        assertTrue(registry.isKnownPool(otherPoolId));
        assertFalse(registry.isTradable(otherPoolId));
        assertFalse(registry.isLPAllowed(otherPoolId));
    }

    function testSbtAndDisabledAssetsStillBlockBothOperationTypes() public {
        _seedPauseTestFees();
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.LP);
        sbt.setPaused(true);
        SwapRequest memory request = _swapRequest(true, 1e18);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(alice);
        router.swapExactInput(request);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        sbt.setPaused(false);
        registry.clearEmergencyPause(id, keccak256("resume"));

        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable-token"));
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve-token"));
        registry.disablePool(PoolId.unwrap(key.toId()), keccak256("disable-pool"));
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
    }

    function _exercisePauseBehavior(PauseMode mode, bool marketPause) private {
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

    function _seedPauseTestFees() private {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
    }

    function _assertTradingBlocked() private {
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

    function _assertOrdinaryLPBlocked() private {
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

    function _exerciseAllowedTrading() private {
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

    function _exerciseAllowedLPLifecycle() private {
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

    function _pauseLocal(PauseScope scope, bytes32 target, PauseMode mode) private returns (uint256) {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"), keccak256("source"));
    }

    function _submitLocalMarket(MarketAction action, PauseMode mode) private {
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

    function _pauseTestBounds() private view returns (LPBounds memory bounds) {
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Deploys and initializes a proxy for the supplied implementation and initializer data.
    function _installProxy(address target, address implementation) private {
        vm.etch(target, type(TSVERC1967Proxy).runtimeCode);
        vm.store(target, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }

    /// @dev Deploys an initialized proxy for the supplied implementation.
    function _newProxy(address implementation, bytes memory data) private returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    /// @dev Builds a token registration configuration for the supplied currency and security.
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
        c.status = TokenStatus.APPROVED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    /// @dev Reads an account balance in the token display denomination.
    function _displayBalance(address account) private view returns (uint256) {
        return stockUnderlying.getUnderlyingAmountByShares(stock.balanceOf(account));
    }

    /// @dev Builds a swap request for the selected pool and trade parameters.
    function _swapRequest(bool zeroForOne, uint128 amount) private view returns (SwapRequest memory r) {
        r.key = key;
        r.zeroForOne = zeroForOne;
        r.amountSpecified = amount;
        r.limitAmount = 1;
        r.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Funds an approved test Adapter, executes one direction, and verifies exact balance settlement.
    function _runAdapterSwap(V1TestExternalAdapter adapter, bool zeroForOne) private {
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
    function _submitReports() private {
        uint64 now_ = uint64(block.timestamp);
        AdtvReport memory adtv =
            AdtvReport(SECURITY, 202609, 1e24, now_ - 1, now_ + 100, 1, 1, keccak256("adtv"), keccak256("source"));
        inbox.submitAdtv(adtv);
    }
}
