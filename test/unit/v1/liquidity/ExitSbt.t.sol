// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Permit_v4} from "v4-periphery/interfaces/IERC721Permit_v4.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    ITSVPermissionedRegistry,
    Currency,
    PoolKey,
    IHooks,
    Actions
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {
    PermissionFlag as RegistryPermissionFlag,
    PermissionFlags as RegistryPermissionFlags
} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TestTokenApproveProxy} from "../../../helpers/TokenApproveMocks.sol";
import {PaymentToken, PaymentAllowlist} from "./TokenApprovePayment.t.sol";

contract ExitCredentialRegistry {
    mapping(address => bool) public hasCredential;
    mapping(address => bool) private lpAllowed;
    bool private paused;

    function setCredential(address who, bool held) external {
        hasCredential[who] = held;
        lpAllowed[who] = held;
    }

    function setLpAllowed(address who, bool allowed) external {
        lpAllowed[who] = allowed;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function isAllowed(RegistryPermissionFlag permission, address who) external view returns (bool) {
        require(permission == RegistryPermissionFlags.LIQUIDITY_ALLOWED, "wrong permission");
        return hasCredential[who] && lpAllowed[who] && !paused;
    }
}

contract ExitAdapterFactory {
    mapping(address => address) public verifiedPermissionsAdapterOf;
    mapping(address => address) public permissionsAdapterOf;

    function setAdapter(address adapter, address token) external {
        verifiedPermissionsAdapterOf[adapter] = token;
        permissionsAdapterOf[adapter] = token;
    }
}

/// @dev Calls the alternate LP entry point inside an outer unlock; NFT approval remains required.
contract ExitOuterUnlock {
    IPoolManager private immutable manager;
    TSVLPManagerV1 private immutable lp;

    constructor(IPoolManager manager_, TSVLPManagerV1 lp_) {
        manager = manager_;
        lp = lp_;
    }

    function execute(bytes calldata actions, bytes[] calldata params) external {
        manager.unlock(abi.encode(actions, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bytes memory actions, bytes[] memory params) = abi.decode(data, (bytes, bytes[]));
        lp.modifyLiquiditiesWithoutUnlock(actions, params);
        return "";
    }
}

/// @dev Seeds a real ERC-6909 claim by paying its matching PM debt.
contract ExitClaimSeeder {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seed(Currency currency, address owner, uint256 amount) external {
        manager.unlock(abi.encode(currency, owner, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Currency currency, address owner, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        manager.mint(owner, uint256(uint160(Currency.unwrap(currency))), amount);
        manager.sync(currency);
        require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
        manager.settle();
        return "";
    }
}

/// @dev Real PM, adapter and LP proxy on a hookless test pool; Registry/SBT responses are controlled.
contract TSVExitSbtTest is Test {
    TSVLPManagerV1 private lp;
    IPoolManager private manager;
    ExitCredentialRegistry private registry;
    PaymentToken private underlying;
    PaymentToken private quote;
    PermissionsAdapter private adapter;
    TestTokenApproveProxy private approveProxy;
    PoolKey private key;
    address private constant USER = address(0xA11CE);
    uint256 private constant LIQUIDITY = 1 ether;

    function setUp() public {
        underlying = new PaymentToken();
        quote = new PaymentToken();
        registry = new ExitCredentialRegistry();
        ExitAdapterFactory factory = new ExitAdapterFactory();
        PaymentAllowlist checker = new PaymentAllowlist();
        checker.setAllowed(USER, true);
        manager = IPoolManager(address(new PoolManager(address(this))));
        adapter = new PermissionsAdapter(IERC20(address(underlying)), address(manager), address(this), checker);
        factory.setAdapter(address(adapter), address(underlying));
        approveProxy = new TestTokenApproveProxy();
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), address(0xCAFE), address(0xD00D));
        TSVLPManagerV1 implementation = new TSVLPManagerV1(
            manager,
            IAllowanceTransfer(address(0)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(address(factory)),
            300_000,
            ITSVPermissionedRegistry(address(registry)),
            approveProxy
        );
        lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            TSVLPManagerV1.initialize, (address(anchor), ITSVPermissionedRegistry(address(registry)))
                        )
                    )
                ))
        );
        approveProxy.setAllowed(address(lp), true);
        adapter.updateAllowedWrapper(address(lp), true);
        adapter.updateAllowedHook(IHooks(address(0)), true);
        registry.setCredential(USER, true);
        (address c0, address c1) =
            address(adapter) < address(quote) ? (address(adapter), address(quote)) : (address(quote), address(adapter));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        underlying.mint(USER, 10 ether);
        quote.mint(USER, 10 ether);
        vm.startPrank(USER);
        underlying.approve(approveProxy.tokenApprove(), type(uint256).max);
        quote.approve(approveProxy.tokenApprove(), type(uint256).max);
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(key, int24(-60), int24(60), LIQUIDITY, type(uint128).max, type(uint128).max, USER, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
        vm.stopPrank();
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testHolderCanDecreaseAndReceiveAssets() public {
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        uint256 beforeU = underlying.balanceOf(USER);
        uint256 beforeQ = quote.balanceOf(USER);
        vm.prank(USER);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY / 2);
        assertGt(underlying.balanceOf(USER), beforeU);
        assertGt(quote.balanceOf(USER), beforeQ);
    }

    function testHolderCanBurnPosition() public {
        (bytes memory actions, bytes[] memory params) = _exit(Actions.BURN_POSITION, 0);
        vm.prank(USER);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.expectRevert();
        lp.ownerOf(1);
    }

    function testRevokedHolderCannotDecrease() public {
        _assertExitRejected(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
    }

    function testRevokedHolderCannotCollectFeesViaZeroDecrease() public {
        _assertExitRejected(Actions.DECREASE_LIQUIDITY, 0);
    }

    function testRevokedHolderCannotBurn() public {
        _assertExitRejected(Actions.BURN_POSITION, 0);
    }

    function testRevokedHolderCannotCollectFeesViaZeroIncrease() public {
        _assertExitRejected(Actions.INCREASE_LIQUIDITY, 0);
    }

    function testApprovedOperatorCannotBypassRevokedOwnerSbt() public {
        vm.prank(USER);
        lp.approve(address(this), 1);
        registry.setCredential(USER, false);
        registry.setCredential(address(this), true);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.BURN_POSITION, 0);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testWithoutUnlockCannotBypassRevokedOwnerSbt() public {
        ExitOuterUnlock caller = new ExitOuterUnlock(manager, lp);
        vm.prank(USER);
        lp.approve(address(caller), 1);
        registry.setCredential(USER, false);
        registry.setCredential(address(caller), true);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        caller.execute(actions, params);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testEveryLpActionRejectsUnqualifiedCaller() public {
        vm.prank(USER);
        lp.approve(address(this), 1);
        uint256[6] memory actions = _lpActions();
        for (uint256 i; i < actions.length; ++i) {
            _assertActionRejected(actions[i], address(this), USER);
        }
    }

    function testEveryLpActionRejectsUnqualifiedOwner() public {
        vm.prank(USER);
        lp.approve(address(this), 1);
        registry.setCredential(address(this), true);
        registry.setCredential(USER, false);
        uint256[6] memory actions = _lpActions();
        for (uint256 i; i < actions.length; ++i) {
            _assertActionRejected(actions[i], address(this), USER);
        }
    }

    function testEveryLpActionRejectsPausedSbt() public {
        registry.setPaused(true);
        uint256[6] memory actions = _lpActions();
        for (uint256 i; i < actions.length; ++i) {
            _assertActionRejected(actions[i], USER, USER);
        }
    }

    function testHoldingSbtWithoutLpPermissionCannotExit() public {
        registry.setLpAllowed(USER, false);
        assertTrue(registry.hasCredential(USER));
        _assertActionRejected(Actions.DECREASE_LIQUIDITY, USER, USER);
        _assertActionRejected(Actions.BURN_POSITION, USER, USER);
    }

    function testQualifiedOperatorCanExitForQualifiedOwner() public {
        registry.setCredential(address(this), true);
        vm.prank(USER);
        lp.approve(address(this), 1);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY / 2);
    }

    function testWithoutUnlockRejectsUnqualifiedCallerWithQualifiedOwner() public {
        ExitOuterUnlock caller = new ExitOuterUnlock(manager, lp);
        vm.prank(USER);
        lp.approve(address(caller), 1);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        caller.execute(actions, params);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testWithoutUnlockAllowsQualifiedCallerAndOwner() public {
        ExitOuterUnlock caller = new ExitOuterUnlock(manager, lp);
        registry.setCredential(address(caller), true);
        vm.prank(USER);
        lp.approve(address(caller), 1);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        caller.execute(actions, params);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY / 2);
    }

    function testAdapterOwnerCanForceBurnWithoutSbt() public {
        registry.setCredential(USER, false);
        uint256 beforeU = underlying.balanceOf(USER);
        uint256 beforeQ = quote.balanceOf(USER);
        lp.unwindPosition(1, 0, 0, "");
        vm.expectRevert();
        lp.ownerOf(1);
        assertGt(underlying.balanceOf(USER), beforeU);
        assertGt(quote.balanceOf(USER), beforeQ);
    }

    function testUnwindRemainsRestrictedToAdapterOwner() public {
        registry.setCredential(USER, false);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.unwindPosition(1, 0, 0, "");
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testUnwindFailureDoesNotLeaveSbtBypass() public {
        registry.setCredential(USER, false);
        vm.expectRevert();
        lp.unwindPosition(1, type(uint128).max, type(uint128).max, "");
        _assertExitRejected(Actions.BURN_POSITION, 0);
    }

    function testAllSettlementActionsRejectUnqualifiedCaller() public {
        registry.setCredential(USER, false);
        uint256[11] memory actions = [
            uint256(Actions.SETTLE_PAIR),
            Actions.TAKE_PAIR,
            Actions.SETTLE,
            Actions.TAKE,
            Actions.CLOSE_CURRENCY,
            Actions.CLEAR_OR_TAKE,
            Actions.SWEEP,
            Actions.WRAP,
            Actions.UNWRAP,
            Actions.MINT_6909,
            Actions.BURN_6909
        ];
        bytes[] memory params = new bytes[](1);
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(USER);
            vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
            lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(actions[i])), params), block.timestamp);
        }
    }

    function testTakePairRejectsUnqualifiedRecipientAndRollsBackDecrease() public {
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        params[1] = abi.encode(key.currency0, key.currency1, address(0xBAD));
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testTakePairAllowsQualifiedRecipientDifferentFromOwner() public {
        address recipient = address(0xB0B);
        registry.setCredential(recipient, true);
        (bytes memory actions, bytes[] memory params) = _exit(Actions.DECREASE_LIQUIDITY, LIQUIDITY / 2);
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        vm.prank(USER);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertGt(underlying.balanceOf(recipient), 0);
        assertGt(quote.balanceOf(recipient), 0);
    }

    function testTakeRejectsUnqualifiedRecipientAndRollsBackDecrease() public {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(uint256(1), LIQUIDITY / 2, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, address(0xBAD), uint256(0));
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE)), params),
            block.timestamp
        );
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function testSweepRequiresQualifiedRecipient() public {
        quote.mint(address(lp), 1 ether);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(address(quote)), address(0xBAD));
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.SWEEP)), params), block.timestamp);
        assertEq(quote.balanceOf(address(lp)), 1 ether);
        registry.setCredential(address(0xBAD), true);
        vm.prank(USER);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.SWEEP)), params), block.timestamp);
        assertEq(quote.balanceOf(address(0xBAD)), 1 ether);
    }

    function testSweepResolvesMsgSenderRecipient() public {
        quote.mint(address(lp), 1 ether);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(address(quote)), address(1));
        uint256 beforeQ = quote.balanceOf(USER);
        vm.prank(USER);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.SWEEP)), params), block.timestamp);
        assertEq(quote.balanceOf(USER), beforeQ + 1 ether);
    }

    function testAddressThisRecipientHasNoImplicitSbtExemption() public {
        quote.mint(address(lp), 1 ether);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(address(quote)), address(2));
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.SWEEP)), params), block.timestamp);
    }

    function testOrdinaryCallerCannotUseForcedDeliveryPrimitive() public {
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(address(quote)), USER, uint256(0));
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.UNWIND_WITH_FALLBACK)), params), block.timestamp);
    }

    function testWithdrawClaimChecksCallerAndRecipient() public {
        _seedUserClaim();
        registry.setCredential(USER, false);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(Currency.wrap(address(quote)), 1 ether, USER);
        registry.setCredential(USER, true);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(Currency.wrap(address(quote)), 1 ether, address(0xBAD));
        assertEq(manager.balanceOf(USER, uint256(uint160(address(quote)))), 1 ether);
        uint256 beforeQ = quote.balanceOf(USER);
        vm.prank(USER);
        lp.withdrawClaim(Currency.wrap(address(quote)), 1 ether, address(1));
        assertEq(manager.balanceOf(USER, uint256(uint160(address(quote)))), 0);
        assertEq(quote.balanceOf(USER), beforeQ + 1 ether);
    }

    function testSuccessfulForcedExitDoesNotExemptLaterSweep() public {
        registry.setCredential(USER, false);
        lp.unwindPosition(1, 0, 0, "");
        quote.mint(address(lp), 1 ether);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(Currency.wrap(address(quote)), USER);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.SWEEP)), params), block.timestamp);
        assertEq(quote.balanceOf(address(lp)), 1 ether);
    }

    function _seedUserClaim() private {
        ExitClaimSeeder seeder = new ExitClaimSeeder(manager);
        quote.mint(address(seeder), 1 ether);
        seeder.seed(Currency.wrap(address(quote)), USER, 1 ether);
        vm.prank(USER);
        manager.setOperator(address(lp), true);
    }

    function _lpActions() private pure returns (uint256[6] memory) {
        return [
            uint256(Actions.MINT_POSITION),
            Actions.MINT_POSITION_FROM_DELTAS,
            Actions.INCREASE_LIQUIDITY,
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            Actions.DECREASE_LIQUIDITY,
            Actions.BURN_POSITION
        ];
    }

    function _assertActionRejected(uint256 action, address caller, address recipient) private {
        bytes[] memory params = new bytes[](1);
        if (action == Actions.MINT_POSITION) {
            params[0] = abi.encode(
                key, int24(-60), int24(60), LIQUIDITY, type(uint128).max, type(uint128).max, recipient, bytes("")
            );
        } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
            params[0] =
                abi.encode(key, int24(-60), int24(60), type(uint128).max, type(uint128).max, recipient, bytes(""));
        } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
            params[0] = abi.encode(uint256(1), type(uint128).max, type(uint128).max, bytes(""));
        } else {
            (, bytes[] memory exitParams) = _exit(action, 0);
            params[0] = exitParams[0];
        }
        vm.prank(caller);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(action)), params), block.timestamp);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
        assertEq(lp.nextTokenId(), 2);
    }

    function _assertExitRejected(uint256 action, uint256 amount) private {
        registry.setCredential(USER, false);
        (bytes memory actions, bytes[] memory params) = _exit(action, amount);
        vm.prank(USER);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        assertEq(lp.ownerOf(1), USER);
        assertEq(lp.getPositionLiquidity(1), LIQUIDITY);
    }

    function _exit(uint256 action, uint256 amount) private view returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(uint8(action), uint8(Actions.TAKE_PAIR));
        params = new bytes[](2);
        params[0] = action == Actions.BURN_POSITION
            ? abi.encode(uint256(1), uint128(0), uint128(0), bytes(""))
            : abi.encode(uint256(1), amount, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, USER);
    }
}
