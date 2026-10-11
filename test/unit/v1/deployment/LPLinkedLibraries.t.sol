// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LPLinkedFixture,
    LPLinkedHarness,
    LPLinkedDependencies,
    TSVLPManagerV1,
    ITSVPermissionedRegistry,
    IPermissionsAdapter,
    Currency,
    Actions,
    IAllowanceTransfer
} from "../../../helpers/v1/LPLinkedFixture.sol";
import {ERC721PermitHash} from "v4-periphery/libraries/ERC721PermitHash.sol";
import {IUnorderedNonce} from "v4-periphery/interfaces/IUnorderedNonce.sol";
import {CustomRevert} from "tsv-v1/vendor/permissionedPools/base/Notifier.sol";
import {ISubscriber} from "v4-periphery/interfaces/ISubscriber.sol";
import {INotifier} from "v4-periphery/interfaces/INotifier.sol";
import {IERC721Permit_v4} from "v4-periphery/interfaces/IERC721Permit_v4.sol";
import {LPPositionMath} from "tsv-v1/vendor/permissionedPools/libraries/LPPositionMath.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TSVLPManagerLib} from "tsv-v1/libraries/TSVLPManagerLib.sol";

contract LPLinkedLibrariesTest is LPLinkedFixture {
    function testNftPermitUsesProxyDomainAndStorageAndRejectsReplay() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ERC721PermitHash.hashPermit(address(this), tokenId, 7, deadline));
        vm.deal(address(this), 1);
        lp.permit{value: 1}(address(this), tokenId, deadline, 7, sig);
        assertEq(lp.getApproved(tokenId), address(this));
        assertEq(lp.nonces(owner, 0), 1 << 7);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        lp.permit(address(this), tokenId, deadline, 7, sig);
    }

    function testPermitForAllAndDeadline() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ERC721PermitHash.hashPermitForAll(address(this), true, 8, deadline));
        lp.permitForAll(owner, address(this), true, deadline, 8, sig);
        assertTrue(lp.isApprovedForAll(owner, address(this)));
        vm.warp(deadline + 1);
        vm.expectRevert(IERC721Permit_v4.SignatureDeadlineExpired.selector);
        lp.permitForAll(owner, address(this), true, deadline, 8, sig);
    }

    function testMulticallPreservesCallerAndRollsBackEarlierWrites() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.setApprovalForAll, (address(this), true));
        calls[1] = abi.encodeCall(lp.revokeNonce, (uint256(10)));
        vm.prank(owner);
        lp.multicall(calls);
        assertTrue(lp.isApprovedForAll(owner, address(this)));
        calls[0] = abi.encodeCall(lp.setApprovalForAll, (address(this), false));
        vm.prank(owner);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        lp.multicall(calls);
        assertTrue(lp.isApprovedForAll(owner, address(this)));
    }

    function testPermit2CallerAndCatchReturnArePreserved() public {
        IAllowanceTransfer.PermitSingle memory single;
        assertEq(lp.permit(owner, single, ""), "");
        assertEq(deps.caller(), address(lp));
        assertEq(deps.payer(), owner);
        deps.setRejectPermit(true);
        assertEq(lp.permit(owner, single, ""), abi.encodeWithSelector(LPLinkedDependencies.PermitRejected.selector));
        IAllowanceTransfer.PermitBatch memory batch;
        batch.details = new IAllowanceTransfer.PermitDetails[](0);
        assertEq(lp.permitBatch(owner, batch, ""), abi.encodeWithSelector(LPLinkedDependencies.PermitRejected.selector));
    }

    function testSubscriptionStateCallerAndUnsubscribeArePreserved() public {
        vm.prank(owner);
        lp.subscribe(tokenId, address(sub), "hello");
        assertEq(address(lp.subscriber(tokenId)), address(sub));
        assertEq(sub.caller(), address(lp));
        vm.prank(owner);
        lp.unsubscribe(tokenId);
        assertEq(address(lp.subscriber(tokenId)), address(0));
        assertEq(sub.unsubscriptions(), 1);
    }

    function testSubscriptionFailureRollsBackStateAndBubblesOriginalError() public {
        sub.configure(false, true);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(sub),
                ISubscriber.notifySubscribe.selector,
                abi.encodeWithSignature("Error(string)", "SUBSCRIBE_REJECTED"),
                abi.encodePacked(INotifier.SubscriptionReverted.selector)
            )
        );
        lp.subscribe(tokenId, address(sub), "");
        assertEq(address(lp.subscriber(tokenId)), address(0));
    }

    function testPaymentsKeepManagerCallerAndUserPayer() public {
        vm.prank(owner);
        lp.payForTest(key.currency1, owner, 9);
        assertEq(deps.caller(), address(lp));
        assertEq(deps.payer(), owner);
        assertEq(deps.recipient(), address(manager));
        assertEq(deps.amount(), 9);
        vm.prank(owner);
        lp.payForTest(key.currency0, owner, 9);
        assertEq(deps.token(), underlying);
        assertEq(deps.recipient(), Currency.unwrap(key.currency0));
    }

    function testIssuerUnwindDeliversFullClaimsToLp() public {
        manager.seedClaim(address(lp), uint160(Currency.unwrap(key.currency0)), 10);
        lp.unwindPosition(tokenId, 0, 0, "");
        assertEq(manager.delivered(owner, Currency.unwrap(key.currency0)), 11);
        assertEq(manager.delivered(owner, Currency.unwrap(key.currency1)), 1);
        vm.expectRevert(bytes("NOT_MINTED"));
        lp.ownerOf(tokenId);
    }

    function testIssuerUnwindQuoteDeliveryFailureRollsBackAdminDelivery() public {
        manager.setRejected(owner, true);
        vm.expectRevert(TSVLPManagerLib.UnAcceptableScenario.selector);
        lp.unwindPosition(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(manager.delivered(address(this), Currency.unwrap(key.currency0)), 0);
        assertEq(manager.balanceOf(owner, uint160(Currency.unwrap(key.currency1))), 0);
        assertEq(manager.balanceOf(address(lp), uint160(Currency.unwrap(key.currency0))), 0);
        assertEq(manager.balanceOf(address(lp), uint160(Currency.unwrap(key.currency1))), 0);
    }

    function testIssuerUnwindBothRecipientsRejectRollsBackBurn() public {
        manager.setRejected(owner, true);
        manager.setRejected(address(this), true);
        vm.expectRevert(TSVLPManagerLib.UnAcceptableScenario.selector);
        lp.unwindPosition(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(manager.balanceOf(address(this), uint160(Currency.unwrap(key.currency0))), 0);
        assertEq(manager.balanceOf(address(lp), uint160(Currency.unwrap(key.currency0))), 0);
    }

    function testInheritedClaimWithdrawalIsForbidden() public {
        uint256 id = uint160(Currency.unwrap(key.currency0));
        manager.seedClaim(address(this), id, 9);
        vm.expectRevert(TSVLPManagerV1.WithdrawClaimForbidden.selector);
        lp.withdrawClaim(key.currency0, 9, address(this));
        assertEq(manager.balanceOf(address(this), id), 9);
        assertEq(manager.delivered(address(this), Currency.unwrap(key.currency0)), 0);
    }

    function testNormalActionsCannotRedeemClaims() public {
        uint256 id = uint160(Currency.unwrap(key.currency1));
        manager.seedClaim(owner, id, 9);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key.currency1, owner, uint256(9));
        params[1] = abi.encode(key.currency1, owner, uint256(9));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TSVLPManagerLib.UnsupportedAction.selector, Actions.BURN_6909));
        lp.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE)), params), block.timestamp
        );
        assertEq(manager.balanceOf(owner, id), 9);
        assertEq(manager.delivered(owner, Currency.unwrap(key.currency1)), 0);
    }

    function testOkxUnwindIsDirectAndDeliveryFailureRollsBackBurn() public {
        manager.setRejected(owner, true);
        vm.expectRevert(bytes("REJECTED"));
        lp.unwindPositionByOkx(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(lp.getApproved(tokenId), address(0));
        manager.setRejected(owner, false);
        lp.unwindPositionByOkx(tokenId, 0, 0, "");
        assertEq(manager.delivered(owner, Currency.unwrap(key.currency0)), 1);
    }

    function testUnwindClearsReattachedSubscriberAndDoesNotNotifyBurn() public {
        vm.startPrank(owner);
        lp.setApprovalForAll(address(sub), true);
        lp.subscribe(tokenId, address(sub), "");
        vm.stopPrank();
        sub.configure(true, false);
        lp.unwindPosition(tokenId, 0, 0, "");
        assertEq(sub.subscriptions(), 2);
        assertEq(sub.unsubscriptions(), 1);
        assertEq(address(lp.subscriber(tokenId)), address(0));
    }

    function testTickCountFailureUpdateRollsBackEntireExit() public {
        vm.mockCall(
            registry, abi.encodeCall(ITSVPermissionedRegistry.updatePoolTickCount, (key, int256(-1))), abi.encode(false)
        );
        vm.expectRevert(TSVLPManagerV1.PoolTickCountUpdateFailed.selector);
        lp.unwindPositionByOkx(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(manager.delivered(owner, Currency.unwrap(key.currency0)), 0);
    }

    function testNormalActionCannotUseUnwindAuthorizationAfterExit() public {
        lp.unwindPosition(tokenId, 0, 0, "");
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key.currency0);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.MINT_6909)), params), block.timestamp);
    }

    function testRegistryPausePrecedesLinkedOperations() public {
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isPaused, ()), abi.encode(true));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.unwindPositionByOkx(tokenId, 0, 0, "");
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.subscribe(tokenId, address(sub), "");
        bytes[] memory calls = new bytes[](0);
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.multicall(calls);
    }

    function testSweepsOrdinaryCurrencyAndPermissionedUnderlying() public {
        vm.etch(underlying, hex"00");
        address quote = Currency.unwrap(key.currency1);
        vm.mockCall(quote, abi.encodeWithSignature("balanceOf(address)", address(lp)), abi.encode(uint256(9)));
        vm.mockCall(underlying, abi.encodeWithSignature("balanceOf(address)", address(lp)), abi.encode(uint256(7)));
        vm.mockCall(quote, abi.encodeWithSignature("transfer(address,uint256)", owner, 9), abi.encode(true));
        vm.mockCall(underlying, abi.encodeWithSignature("transfer(address,uint256)", owner, 7), abi.encode(true));
        vm.expectCall(quote, abi.encodeWithSignature("transfer(address,uint256)", owner, 9));
        lp.sweepForTest(key.currency1, owner);
        vm.expectCall(underlying, abi.encodeWithSignature("transfer(address,uint256)", owner, 7));
        lp.sweepForTest(key.currency0, owner);
    }

    function testOrdinaryBurnKeepsRegistryPermissionAndPoolGateChecks() public {
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        bytes memory data = abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION)), params);
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isSbtAllowed.selector), abi.encode(false));
        vm.prank(owner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.modifyLiquidities(data, block.timestamp);
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isSbtAllowed.selector), abi.encode(true));
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isLPAllowed.selector), abi.encode(false));
        vm.prank(owner);
        vm.expectRevert(TSVLPManagerLib.PoolNotAllowed.selector);
        lp.modifyLiquidities(data, block.timestamp);
        assertEq(lp.ownerOf(tokenId), owner);
    }

    function testFuzzLinkedMathMatchesOriginal(int24 tick, uint128 amount0, uint128 amount1) public view {
        tick = int24(bound(int256(tick), -887272, 887272));
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        assertEq(LPPositionMath.getSqrtPriceAtTick(tick), price);
        uint160 lower = TickMath.getSqrtPriceAtTick(-887272);
        uint160 upper = TickMath.getSqrtPriceAtTick(887272);
        (bool linkedOk, bytes memory linkedResult) = address(LPPositionMath)
            .staticcall(
                abi.encodeWithSelector(
                    LPPositionMath.getLiquidityForAmounts.selector, price, lower, upper, amount0, amount1
                )
            );
        (bool originalOk, bytes memory originalResult) = address(this)
            .staticcall(abi.encodeCall(this.referenceLiquidityAmounts, (price, lower, upper, amount0, amount1)));
        assertEq(linkedOk, originalOk);
        assertEq(linkedResult, originalResult);
    }

    function referenceLiquidityAmounts(uint160 price, uint160 lower, uint160 upper, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(price, lower, upper, amount0, amount1);
    }

    function _sign(bytes32 structHash) private view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", lp.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
