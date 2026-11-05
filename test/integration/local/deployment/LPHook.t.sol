// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    PoolKey,
    Currency,
    IHooks,
    Actions
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVLPManagerLib} from "tsv-v1/libraries/TSVLPManagerLib.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {PermissionedRegisterParam, PoolLifecycle, SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlag, PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {V1LocalSBT} from "../../../helpers/v1/LocalMocks.sol";
import {V1SwapToken} from "../../../helpers/v1/WrappedSwapMocks.sol";
import {V1MockIssuerShares} from "../../../helpers/v1/MockIssuerTokens.sol";
import {V1IssuerAllowlistChecker} from "../../../helpers/v1/PermissionedMocks.sol";
import {PoolKey as HookPoolKey} from "v4-core/types/PoolKey.sol";
import {Currency as HookCurrency} from "v4-core/types/Currency.sol";
import {IHooks as HookIHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager as HookPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @dev Real PoolManager, LP Manager, Hook, Registry, Factory and Adapter; issuer/SBT/approval dependencies are fixtures.
contract LPHookTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant SECURITY = keccak256("LP_HOOK_STOCK");
    uint128 private constant LIQUIDITY = 1e18;
    PoolManager private manager;
    TSVRegistryV1 private registry;
    TSVHookV1 private hook;
    TSVLPManagerV1 private lp;
    PermissionsAdapter private stock;
    V1SwapToken private underlying;
    V1SwapToken private quote;
    V1MockIssuerShares private issuer;
    V1IssuerAllowlistChecker private checker;
    V1LocalSBT private sbt;
    PoolKey private key;
    address private alice;

    function setUp() public {
        alice = makeAddr("lp-owner");
        manager = new PoolManager(address(this));
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        PermissionsAdapterFactory factory = new PermissionsAdapterFactory(address(manager));
        TSVLPManagerV1 implementation = new TSVLPManagerV1(
            IPoolManager(address(manager)),
            IAllowanceTransfer(address(this)),
            200_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(address(factory)),
            500_000
        );
        lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(TSVLPManagerV1.initialize, (ITSVPermissionedRegistry(address(registry))))
                    )
                ))
        );
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook.initialize(address(manager), address(registry), address(this), address(this), address(lp));
        sbt = new V1LocalSBT();
        registry.bindComponents(address(hook), address(lp), address(factory), address(sbt));
        registry.setSbtConfig(1, PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        sbt.setHolder(alice, 1, true);
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.grantRole(registry.HALT_REPORTER_ROLE(), address(this));
        registry.grantRole(lp.POOL_CREATOR_ROLE(), address(this));
        registry.grantRole(lp.FORCE_EXIT_ADMIN_ROLE(), address(this));
        registry.setTierPolicy(1, 10, bytes32("TEST"));
        issuer = new V1MockIssuerShares();
        underlying = new V1SwapToken("LP_STOCK", 18, address(issuer));
        quote = new V1SwapToken("LP_QUOTE", 18, address(0));
        checker = new V1IssuerAllowlistChecker();
        stock = PermissionsAdapter(
            factory.createPermissionsAdapter(
                IERC20(address(underlying)), address(this), IAllowlistChecker(address(checker))
            )
        );
        underlying.mint(address(stock), 17);
        factory.verifyPermissionsAdapter(address(stock));
        stock.updateAllowedWrapper(address(this), true);
        stock.updateAllowedWrapper(address(lp), true);
        stock.updateAllowedHook(IHooks(address(hook)), true);
        ERC8056DirectLegalShareAdapter legal = new ERC8056DirectLegalShareAdapter(address(underlying));
        registry.registerPermissionedCurrency(
            PermissionedRegisterParam(address(stock), SECURITY, address(legal)), 1, bytes32("TEST")
        );
        registry.registerQuoteToken(address(quote), bytes32("TEST"));
        (address a, address b) =
            address(stock) < address(quote) ? (address(stock), address(quote)) : (address(quote), address(stock));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        lp.initializePool(key, uint160(1 << 96));
        underlying.mint(alice, 1e24);
        quote.mint(alice, 1e24);
        vm.startPrank(alice);
        underlying.approve(address(lp), type(uint256).max);
        quote.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _mint(bytes memory hookData) private returns (uint256 tokenId) {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-60), int24(60), uint256(LIQUIDITY), type(uint128).max, type(uint128).max, alice, hookData
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(alice);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
        tokenId = lp.nextTokenId() - 1;
    }

    function _change(uint256 tokenId, uint256 action, uint128 liquidity, bytes memory hookData) private {
        bool adding = action == Actions.INCREASE_LIQUIDITY;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            uint256(liquidity),
            adding ? type(uint128).max : uint128(0),
            adding ? type(uint128).max : uint128(0),
            hookData
        );
        params[1] = adding ? abi.encode(key.currency0, key.currency1) : abi.encode(key.currency0, key.currency1, alice);
        vm.prank(alice);
        lp.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(action), uint8(adding ? Actions.SETTLE_PAIR : Actions.TAKE_PAIR)), params
            ),
            block.timestamp
        );
    }

    function _authorizeExit() private {
        sbt.setHolder(alice, 1, false);
        checker.setPermissions(alice, address(underlying), PermissionFlag.wrap(0x8000));
    }

    function _setSecurityMode(SecurityPauseMode mode, bool enable) private {
        registry.applySecurityStatus(SECURITY, mode, enable, bytes32("TEST"));
    }

    function testRealManagerMintIncreaseDecreaseCollectAndBurnWithoutLegacyContext() public {
        uint256 tokenId = _mint("");
        assertEq(lp.ownerOf(tokenId), alice);
        assertFalse(registry.hasCredential(address(lp)));
        assertEq(lp.getPositionLiquidity(tokenId), LIQUIDITY);
        _change(tokenId, Actions.INCREASE_LIQUIDITY, 0, "");
        _change(tokenId, Actions.INCREASE_LIQUIDITY, LIQUIDITY, "");
        _change(tokenId, Actions.DECREASE_LIQUIDITY, LIQUIDITY, "");
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 0, "");
        assertEq(lp.getPositionLiquidity(tokenId), LIQUIDITY);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, alice);
        vm.prank(alice);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp
        );
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 0);
    }

    function testTsvUnwindSummaryReportsUnderlyingReceivedByLp() public {
        _assertUnwindSummary(true, false, false);
    }

    function testIssuerUnwindSummaryReportsUnderlyingReceivedByLp() public {
        _assertUnwindSummary(false, false, false);
    }

    function testIssuerUnwindSummaryReportsUnderlyingReceivedByIssuer() public {
        _assertUnwindSummary(false, true, false);
    }

    function testTsvEmptyUnwindSummaryReportsZeroReceived() public {
        _assertUnwindSummary(true, false, true);
    }

    function testIssuerEmptyUnwindSummaryReportsZeroReceived() public {
        _assertUnwindSummary(false, false, true);
    }

    /// @dev Uses real W unwrapping, not a mock that credits W balances to the recipient.
    function _assertUnwindSummary(bool tsv, bool fallbackToIssuer, bool empty) private {
        uint256 tokenId = _mint("");
        if (empty) _change(tokenId, Actions.DECREASE_LIQUIDITY, LIQUIDITY, "");
        _authorizeExit();
        if (fallbackToIssuer) underlying.setBlockedRecipient(alice);

        // Existing balances must not be included in this position's received amounts.
        underlying.mint(address(this), 123);
        quote.mint(address(this), 456);
        uint256 lpStockBefore = underlying.balanceOf(alice);
        uint256 issuerStockBefore = underlying.balanceOf(address(this));
        uint256 lpQuoteBefore = quote.balanceOf(alice);
        uint256 issuerQuoteBefore = quote.balanceOf(address(this));
        assertEq(stock.balanceOf(alice), 0);
        assertEq(stock.balanceOf(address(this)), 0);

        vm.recordLogs();
        if (tsv) lp.unwindPositionByTsv(tokenId, 0, 0, "");
        else lp.unwindPosition(tokenId, 0, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventId = tsv
            ? keccak256("TsvPositionUnwound(uint256,address,address,address,address,uint256,uint256,uint256,uint256)")
            : keccak256("IssuerPositionUnwound(uint256,address,address,address,address,uint256,uint256,uint256,uint256)");
        uint256 matched;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(lp) || logs[i].topics.length == 0 || logs[i].topics[0] != eventId) {
                continue;
            }
            ++matched;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[1], bytes32(tokenId));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(this)))));
            (
                address token0,
                address token1,
                uint256 lpAmount0,
                uint256 issuerAmount0,
                uint256 lpAmount1,
                uint256 issuerAmount1
            ) = abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256));
            // Event identity stays in pool-currency order; amounts track actual U/Q balances.
            assertEq(token0, Currency.unwrap(key.currency0));
            assertEq(token1, Currency.unwrap(key.currency1));
            bool stockIs0 = token0 == address(stock);
            assertEq(stockIs0 ? lpAmount0 : lpAmount1, underlying.balanceOf(alice) - lpStockBefore);
            assertEq(
                stockIs0 ? issuerAmount0 : issuerAmount1, underlying.balanceOf(address(this)) - issuerStockBefore
            );
            assertEq(stockIs0 ? lpAmount1 : lpAmount0, quote.balanceOf(alice) - lpQuoteBefore);
            assertEq(
                stockIs0 ? issuerAmount1 : issuerAmount0, quote.balanceOf(address(this)) - issuerQuoteBefore
            );
            if (empty) {
                assertEq(lpAmount0 + issuerAmount0 + lpAmount1 + issuerAmount1, 0);
            } else {
                uint256 stockReceived = fallbackToIssuer
                    ? (stockIs0 ? issuerAmount0 : issuerAmount1)
                    : (stockIs0 ? lpAmount0 : lpAmount1);
                assertGt(stockReceived, 0);
                assertGt(stockIs0 ? lpAmount1 : lpAmount0, 0);
            }
        }
        assertEq(matched, 1);
        assertEq(stock.balanceOf(alice), 0);
        assertEq(stock.balanceOf(address(this)), 0);
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        lp.ownerOf(tokenId);
    }

    function testLPAndUnwindFollowRegistryGateForLifecyclePause() public {
        registry.updatePoolLifeCycle(PoolId.unwrap(key.toId()), PoolLifecycle.PAUSE, bytes32("TEST"));
        assertTrue(registry.isLPAllowed(PoolId.unwrap(key.toId())));
        uint256 tokenId = _mint("");
        uint256 second = _mint("");
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 0, "");
        _authorizeExit();
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        lp.unwindPosition(second, 0, 0, "");
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 0);
        registry.updatePoolLifeCycle(PoolId.unwrap(key.toId()), PoolLifecycle.DELIST, bytes32("TEST"));
        sbt.setHolder(alice, 1, true);
        checker.setPermissions(alice, address(underlying), PermissionFlags.LIQUIDITY_ALLOWED);
        vm.expectRevert(TSVLPManagerLib.PoolNotAllowed.selector);
        _mint("");
    }

    function testSecurityLpPauseBlocksOrdinaryChangesAndAllowsBothAuthorizedUnwinds() public {
        uint256 first = _mint("");
        uint256 second = _mint("");
        _setSecurityMode(SecurityPauseMode.LP, true);
        vm.expectRevert();
        _change(first, Actions.INCREASE_LIQUIDITY, 1, "");
        vm.expectRevert();
        _change(first, Actions.DECREASE_LIQUIDITY, 1, "");
        vm.expectRevert();
        _change(first, Actions.DECREASE_LIQUIDITY, 0, "");
        _authorizeExit();
        lp.unwindPositionByTsv(first, 0, 0, "");
        lp.unwindPosition(second, 0, 0, "");
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 0);
        _setSecurityMode(SecurityPauseMode.ALL, false);
        sbt.setHolder(alice, 1, true);
        checker.setPermissions(alice, address(underlying), PermissionFlags.LIQUIDITY_ALLOWED);
        _mint("");
    }

    function testGlobalPauseStillBlocksOrdinaryAndForcedActions() public {
        uint256 tokenId = _mint("");
        _authorizeExit();
        registry.setEmergencyPauseEnable(true, keccak256("global"));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 0, "");
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.unwindPosition(tokenId, 0, 0, "");
    }

    function testUnwindFailureRestoresPosition() public {
        uint256 tokenId = _mint("");
        _authorizeExit();
        underlying.setBlockedRecipient(alice);
        vm.expectRevert();
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), alice);
        assertEq(lp.getPositionLiquidity(tokenId), LIQUIDITY);
        underlying.setBlockedRecipient(address(0));
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
    }

    function testEmptyPositionAuthorizedUnwindBypassesSecurityPauseAndStillChecksGlobalPause() public {
        uint256 tokenId = _mint("");
        _change(tokenId, Actions.DECREASE_LIQUIDITY, LIQUIDITY, "");
        assertEq(lp.getPositionLiquidity(tokenId), 0);
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 1);
        _authorizeExit();
        _setSecurityMode(SecurityPauseMode.ALL, true);
        registry.setEmergencyPauseEnable(true, bytes32("TEST"));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), alice);
        registry.setEmergencyPauseEnable(false, bytes32("TEST"));
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(lp.balanceOf(alice), 0);
        assertEq(registry.getPoolTickCount(PoolId.unwrap(key.toId())), 0);
    }

    function testUnwindCannotBeAuthorizedByUserHookDataOrUnapprovedCaller() public {
        uint256 tokenId = _mint("");
        bytes memory snapshot = abi.encode(issuer.multiplier());
        _setSecurityMode(SecurityPauseMode.LP, true);
        vm.expectRevert();
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 1, snapshot);
        _authorizeExit();
        vm.prank(alice);
        vm.expectRevert();
        lp.unwindPosition(tokenId, 0, 0, "");
        assertEq(lp.getPositionLiquidity(tokenId), LIQUIDITY);
    }

    function testOptionalSnapshotAcceptsMatchingRejectsStaleAndMalformed() public {
        bytes memory snapshot = abi.encode(issuer.multiplier());
        uint256 tokenId = _mint(snapshot);
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 0, snapshot);
        issuer.setMultiplier(2e18, 1);
        vm.expectRevert();
        _change(tokenId, Actions.INCREASE_LIQUIDITY, 1, snapshot);
        vm.expectRevert();
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 1, snapshot);
        vm.expectRevert();
        _change(tokenId, Actions.INCREASE_LIQUIDITY, 1, hex"01");
        vm.expectRevert();
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 1, hex"01");
        _change(tokenId, Actions.INCREASE_LIQUIDITY, 1, "");
        _change(tokenId, Actions.DECREASE_LIQUIDITY, 1, "");
        _authorizeExit();
        vm.expectRevert();
        lp.unwindPositionByTsv(tokenId, 0, 0, snapshot);
        lp.unwindPositionByTsv(tokenId, 0, 0, abi.encode(issuer.multiplier()));
    }

    function testAfterCallbacksRecheckOptionalSnapshotAndReturnZero() public {
        HookPoolKey memory hookKey = HookPoolKey(
            HookCurrency.wrap(Currency.unwrap(key.currency0)),
            HookCurrency.wrap(Currency.unwrap(key.currency1)),
            key.fee,
            key.tickSpacing,
            HookIHooks(address(hook))
        );
        HookPoolManager.ModifyLiquidityParams memory params =
            HookPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(uint256(1)));
        bytes memory snapshot = abi.encode(issuer.multiplier());
        vm.startPrank(address(manager));
        (, BalanceDelta delta) =
            hook.afterAddLiquidity(address(lp), hookKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), snapshot);
        assertEq(BalanceDelta.unwrap(delta), 0);
        issuer.setMultiplier(2e18, 1);
        vm.expectRevert(TSVHookV1.MultiplierChanged.selector);
        hook.afterAddLiquidity(address(lp), hookKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), snapshot);
        params.liquidityDelta = -1;
        vm.expectRevert(TSVHookV1.MultiplierChanged.selector);
        hook.afterRemoveLiquidity(address(lp), hookKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), snapshot);
        (, delta) =
            hook.afterRemoveLiquidity(address(lp), hookKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        assertEq(BalanceDelta.unwrap(delta), 0);
        vm.stopPrank();
    }
}
