// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPLinkedFixture, LPLinkedPoolManager, TSVLPManagerV1, Currency, ITSVPermissionedRegistry, Actions} from "../../../helpers/v1/LPLinkedFixture.sol";
import {V1LocalERC20} from "../../../helpers/v1/LocalMocks.sol";
import {Test} from "forge-std/Test.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TSVLPManagerLib} from "tsv-v1/libraries/TSVLPManagerLib.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";

// Preserve ordinary ERC20 transfers; the existing PM fixture records delivery instead of transferring.
// Adding its delivery counter to balanceOf models the one-token exit output in this fixture.
contract AuditObservedQuote is V1LocalERC20 {
    LPLinkedPoolManager private immutable manager;
    constructor(LPLinkedPoolManager manager_) V1LocalERC20("observed quote") { manager = manager_; }
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + manager.delivered(account, address(this));
    }
}

contract AuditDrainingSubscriber {
    V1LocalERC20 private immutable quote;
    address private immutable owner;
    address private constant SINK = address(0xBEEF);
    constructor(V1LocalERC20 quote_, address owner_) { quote = quote_; owner = owner_; }
    function notifySubscribe(uint256, bytes calldata) external {}
    function notifyUnsubscribe(uint256) external { quote.transferFrom(owner, SINK, 1000); }
}

contract AuditCallbackUnderflowTest is LPLinkedFixture {
    AuditDrainingSubscriber private attacker;
    function setUp() public override {
        super.setUp();
        vm.etch(address(quoteToken), address(new AuditObservedQuote(manager)).code);
        quoteToken.mint(owner, 1000);
        attacker = new AuditDrainingSubscriber(quoteToken, owner);
        vm.startPrank(owner);
        quoteToken.approve(address(attacker), 1000);
        lp.subscribe(tokenId, address(attacker), "");
        vm.stopPrank();
    }
    function testTsvExitUnderflowsAndRemainsBlockedOnRetry() public {
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
            lp.unwindPositionByTsv(tokenId, 0, 0, "");
            _assertRolledBack();
        }
    }
    function testIssuerExitUnderflowsAndRemainsBlockedOnRetry() public {
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
            lp.unwindPosition(tokenId, 0, 0, "");
            _assertRolledBack();
        }
    }
    function testExitSucceedsWhenCallbackCannotTransferOldBalance() public {
        vm.prank(owner);
        quoteToken.approve(address(attacker), 0);
        // Failed subscriber calls are swallowed; the exit still delivers its one token.
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(manager.delivered(owner, address(quoteToken)), 1);
        assertEq(quoteToken.balanceOf(owner), 1001);
    }
    function _assertRolledBack() private view {
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(address(lp.subscriber(tokenId)), address(attacker));
        assertEq(quoteToken.balanceOf(owner), 1000);
        assertEq(quoteToken.balanceOf(address(0xBEEF)), 0);
        assertEq(manager.delivered(owner, address(quoteToken)), 0);
    }
}

contract AuditAggregateDeltaTest is Test {
    using Pool for Pool.State;
    using BalanceDeltaLibrary for BalanceDelta;
    Pool.State private pool;
    int128 private constant STEP = int128(uint128(1) << 71);
    function modify(int128 delta) external returns (int128 amount0) {
        (BalanceDelta result,) = pool.modifyLiquidity(Pool.ModifyLiquidityParams({
            owner:address(this), tickLower:-887220, tickUpper:-887160,
            liquidityDelta:delta, tickSpacing:60, salt:bytes32(0)
        }));
        return result.amount0();
    }
    function testTwoLegalIncreasesCannotBeRemovedInOneCall() public {
        pool.initialize(TickMath.getSqrtPriceAtTick(-887260), 3000);
        int128 first = this.modify(STEP);
        int128 second = this.modify(STEP);
        assertLt(first, 0); assertEq(first, second);
        uint256 totalOutput = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(-887220),TickMath.getSqrtPriceAtTick(-887160),uint128(STEP)*2,false
        );
        assertGt(totalOutput,uint256(uint128(type(int128).max)));
        emit log_named_uint("one increase raw amount",uint256(-int256(first)));
        emit log_named_uint("aggregate removal raw amount",totalOutput);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        this.modify(-STEP*2);
        // Both smaller withdrawals succeed: liquidity and tick limits did not prohibit the state.
        assertGt(this.modify(-STEP),0);
        assertGt(this.modify(-STEP),0);
    }
}

contract AuditPolicyBoundaryTest is LPLinkedFixture {
    function testApprovedOperatorWithoutSbtCannotModifyPosition() public {
        address operator = address(0xBAD);
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isSbtAllowed,
            (PermissionFlags.LIQUIDITY_ALLOWED, operator)), abi.encode(false));
        vm.prank(owner);
        lp.approve(operator, tokenId);
        assertEq(lp.getApproved(tokenId), operator);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        vm.prank(operator);
        vm.expectRevert(TSVLPManagerLib.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY)),params),block.timestamp);
        assertEq(lp.ownerOf(tokenId), owner);
    }
    function testPausedLpRejectsEvenAuthorizedUpgrade() public {
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.hasRole,
            (lp.UPGRADE_ADMIN_ROLE(),address(this))),abi.encode(true));
        vm.mockCall(registry,abi.encodeCall(ITSVPermissionedRegistry.isPaused,()),abi.encode(true));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.upgradeToAndCall(address(lp), "");
    }
}
