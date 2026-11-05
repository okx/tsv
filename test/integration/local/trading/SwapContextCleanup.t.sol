// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";
import {V1SwapToken} from "../../../helpers/v1/WrappedSwapMocks.sol";

contract TSVSwapContextCleanupTest is WrappedSwapFixture {
    function testAllEntriesAndDirectionsPreserveReturnsAndClearContext() public {
        for (uint8 entry; entry < 3; ++entry) {
            _executeEntry(entry, true);
            _executeEntry(entry, false);
        }
    }

    function testConsecutiveParticipantsUseTheirOwnContext() public {
        _executeEntry(0, true);
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        address bob = makeAddr("second-swap-participant");
        sbt.setHolder(bob, 1, true);
        uint128 amount = 2e16;
        quote.mint(bob, amount);
        vm.prank(bob);
        quote.approve(address(router), amount);
        uint256 bobBefore = underlying.balanceOf(bob);
        SwapRequest memory request = _request(false, amount);
        vm.prank(bob);
        (uint256 paid, uint256 received) = router.swapExactInput(request);
        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(underlying.balanceOf(bob), bobBefore + received);
        assertEq(underlying.balanceOf(alice), aliceUnderlyingBefore);
        assertEq(quote.balanceOf(bob), 0);
        _assertContextCleared();
    }

    function testRevertedSwapAfterSuccessRestoresClearedContextAndBalances() public {
        _executeEntry(0, true);
        _setQuota(0);
        bytes32 beforeState = _digest();
        SwapRequest memory request = _request(false, 1e16);
        uint256 day = ledger.currentESTDay();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, day),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_digest(), beforeState);
        _assertContextCleared();
    }

    function testSettlementCallbackSeesLiveContextAndRejectsReentry() public {
        quote.setCallback(address(this), abi.encodeCall(this.assertLiveContextAndLock, ()));
        _executeEntry(0, false);
    }

    function assertLiveContextAndLock() external {
        require(msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        assertEq(vm.load(address(router), bytes32(uint256(2))), bytes32(uint256(uint160(alice))));
        assertGt(uint256(vm.load(address(router), bytes32(uint256(3)))), 0);
        assertEq(vm.load(address(router), bytes32(uint256(5))), bytes32(uint256(uint160(alice))));
        assertEq(vm.load(address(router), bytes32(uint256(6))), bytes32(uint256(uint160(address(quote)))));
        assertEq(vm.load(address(router), bytes32(uint256(7))), bytes32(uint256(uint160(alice))));
        SwapRequest memory request = _request(false, 1e16);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInput(request);
    }

    function _executeEntry(uint8 entry, bool stockInput) private {
        uint128 amount = 1e16 + uint128(entry) * 1e12;
        SwapRequest memory request = _request(stockInput, amount);
        V1SwapToken input = stockInput ? underlying : quote;
        V1SwapToken output = stockInput ? quote : underlying;
        address payer = entry == 1 ? address(swapAdapter) : alice;
        address recipient = entry == 1 ? address(swapAdapter) : alice;
        if (entry == 1) {
            input.mint(payer, amount);
            swapAdapter.approveToken(address(input), address(router));
        }
        uint256 payerBefore = input.balanceOf(payer);
        uint256 recipientBefore = output.balanceOf(recipient);
        uint256 paid;
        uint256 received;
        if (entry == 0) {
            vm.prank(alice);
            (paid, received) = router.swapExactInput(request);
        } else if (entry == 1) {
            vm.prank(address(swapAdapter));
            (paid, received) = router.swapExactInputFromContract(request, alice);
        } else {
            (paid, received) = _submitSwap(request);
        }
        assertEq(paid, amount);
        assertGt(received, 0);
        assertEq(input.balanceOf(payer), payerBefore - paid);
        assertEq(output.balanceOf(recipient), recipientBefore + received);
        _assertContextCleared();
    }

    function _assertContextCleared() private view {
        // Storage layout: Registry=0, adapter allowlist=1, and six private context fields=2..7.
        // Read proxy storage without adding production getters or changing the Router layout.
        for (uint256 slot = 2; slot <= 7; ++slot) {
            assertEq(vm.load(address(router), bytes32(slot)), bytes32(0));
        }
        assertEq(router.msgSender(), address(0));
    }
}
