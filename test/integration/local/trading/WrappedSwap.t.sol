// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PermissionedRegisterParam, SwapRequest, SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";
import {V1TestParticipantWallet} from "../../../helpers/v1/LocalMocks.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVWrappedSwapTest is WrappedSwapFixture {
    function testVerificationDustAndDonatedSurplusRemainAfterBothDirections() public {
        underlying.mint(address(stock), 1e18);
        uint256 surplus = _inventory();
        _swap(true, 1e16);
        _swap(false, 1e16);
        assertEq(_inventory(), surplus);
    }

    function testFuzzFalseReturnTransfersRollbackAndNoReturnTransfersAreSupported(
        bool stockInput,
        bool faultUnderlying,
        bool noReturn
    ) public {
        uint128 amount = 1e16;
        SwapRequest memory request = _request(stockInput, amount);
        address payer;
        if (stockInput) {
            underlying.mint(address(stock), amount);
        } else {
            quote.mint(address(swapAdapter), amount);
            swapAdapter.approveToken(address(quote), address(router));
            payer = address(swapAdapter);
        }
        uint8 mode = noReturn ? 4 : 2;
        if (faultUnderlying) underlying.setTransferMode(mode);
        else quote.setTransferMode(mode);
        bytes32 beforeState = _digest();
        bool faultTokenIsTransferred = !faultUnderlying || !stockInput;
        if (noReturn || !faultTokenIsTransferred) {
            swapAdapter.swapExactInputDirect(router, request, payer, alice, alice);
            assertEq(_inventory(), 17);
        } else {
            vm.expectRevert();
            swapAdapter.swapExactInputDirect(router, request, payer, alice, alice);
            assertEq(_digest(), beforeState);
            assertEq(router.msgSender(), address(0));
        }
    }

    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    function testBothDirectionsExactInputConserveInventoryAndAccountOnce() public {
        for (uint256 i; i < 2; ++i) {
            bool stockInput = i == 0;
            uint256 uBefore = underlying.balanceOf(alice);
            uint256 qBefore = quote.balanceOf(alice);
            uint256 supplyBefore = stock.totalSupply();
            uint256 usedBefore = ledger.usedWad(SECURITY, DAY);
            uint256 surplus = _inventory();
            vm.recordLogs();
            (uint256 paid, uint256 received) = _swap(stockInput, 1e16);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(paid, 1e16);
            assertEq(underlying.balanceOf(alice), stockInput ? uBefore - paid : uBefore + received);
            assertEq(quote.balanceOf(alice), stockInput ? qBefore + received : qBefore - paid);
            assertEq(stock.totalSupply(), stockInput ? supplyBefore + paid : supplyBefore - received);
            assertEq(ledger.usedWad(SECURITY, DAY) - usedBefore, stockInput ? paid : received);
            assertEq(_inventory(), surplus);
            assertEq(stock.balanceOf(address(manager)), stock.totalSupply());
            assertEq(stock.balanceOf(alice), 0);
            assertEq(stock.balanceOf(address(router)), 0);
            assertEq(underlying.balanceOf(address(manager)), 0);
            assertEq(underlying.balanceOf(address(router)), 0);
            assertEq(IPoolManager(address(manager)).currencyDelta(address(router), key.currency0), 0);
            assertEq(IPoolManager(address(manager)).currencyDelta(address(router), key.currency1), 0);
            assertEq(router.msgSender(), address(0));
            uint256 accounted;
            for (uint256 j; j < logs.length; ++j) {
                if (
                    logs[j].emitter == address(ledger)
                        && logs[j].topics[0] == keccak256("VolumeUsed(bytes32,bytes32,uint256,uint256)")
                ) {
                    assertEq(logs[j].topics[1], SECURITY);
                    assertEq(logs[j].topics[2], PoolId.unwrap(key.toId()));
                    assertEq(uint256(logs[j].topics[3]), DAY);
                    assertEq(abi.decode(logs[j].data, (uint256)), stockInput ? paid : received);
                    ++accounted;
                }
            }
            assertEq(accounted, 1);
        }
    }

    function testNonzeroProtocolFeesGrossNetQuotaAndOfficialWithdrawal() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(500) | uint24(700 << 12));
        uint256 usedBefore = ledger.usedWad(SECURITY, DAY);
        (uint256 input,) = _swap(true, 1e17);
        (, uint256 output) = _swap(false, 1e17);
        assertEq(ledger.usedWad(SECURITY, DAY) - usedBefore, input + output);
        uint256 stockFees = manager.protocolFeesAccrued(Currency.wrap(address(stock)));
        assertGt(stockFees, 0);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(quote))), 0);
        V1ConfigReceiver recipient = new V1ConfigReceiver();
        uint256 surplus = _inventory();
        assertEq(manager.collectProtocolFees(address(recipient), Currency.wrap(address(stock)), 0), stockFees);
        assertEq(underlying.balanceOf(address(recipient)), stockFees);
        assertEq(stock.balanceOf(address(recipient)), 0);
        assertEq(_inventory(), surplus);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
        _swap(true, 1e17);
        uint256 feesBefore = manager.protocolFeesAccrued(Currency.wrap(address(stock)));
        underlying.setBlockedRecipient(address(recipient));
        bytes32 before_ = _digest();
        vm.expectRevert();
        manager.collectProtocolFees(address(recipient), Currency.wrap(address(stock)), 0);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(stock))), feesBefore);
        assertEq(_digest(), before_);
    }

    function testMultipleWrappersShareQuotaAndCanonicalAdapter() public {
        _swap(true, 1e16);
        uint256 alreadyUsed = ledger.usedWad(SECURITY, DAY);
        PermissionsAdapter w2 = _newWrapper();
        registry.registerPermissionedCurrency(
            PermissionedRegisterParam(address(w2), SECURITY, address(legalAdapter)), 1, bytes32("TEST")
        );
        PoolKey memory second = _seedPool(w2, 500);
        w2.updateSwappingEnabled(true);
        assertEq(ledger.usedWad(SECURITY, DAY), alreadyUsed);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        vm.prank(alice);
        (uint256 paid,) = _submitSwap(
            SwapRequest(
                second,
                Currency.unwrap(second.currency0) == address(w2),
                1e16,
                1,
                uint64(block.timestamp + 100),
                issuer.multiplier()
            )
        );
        assertEq(ledger.usedWad(SECURITY, DAY), alreadyUsed + paid);
        _setSecurityMode(SecurityPauseMode.ALL, true);
        ERC8056DirectLegalShareAdapter next = new ERC8056DirectLegalShareAdapter(address(underlying));
        registry.replaceUnderlyingLegalShareAdapter(address(underlying), address(next), bytes32("TEST"));
        _setSecurityMode(SecurityPauseMode.ALL, false);
        vm.expectCall(
            address(next), abi.encodeCall(ERC8056DirectLegalShareAdapter.toLegalShares, (address(underlying), 1e16)), 2
        );
        vm.recordLogs();
        _swap(true, 1e16);
        vm.prank(alice);
        _submitSwap(
            SwapRequest(
                second,
                Currency.unwrap(second.currency0) == address(w2),
                1e16,
                1,
                uint64(block.timestamp + 100),
                issuer.multiplier()
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(ledger)
                    && logs[i].topics[0] == keccak256("VolumeUsed(bytes32,bytes32,uint256,uint256)")
            ) {
                assertEq(logs[i].topics[1], SECURITY);
                assertEq(logs[i].topics[2], count == 0 ? PoolId.unwrap(key.toId()) : PoolId.unwrap(second.toId()));
                assertEq(abi.decode(logs[i].data, (uint256)), 1e16);
                ++count;
            }
        }
        assertEq(count, 2);
    }

    function testQuotaFailureRollsBackPoolInventoryAndEvents() public {
        _setQuota(1);
        bytes32 before_ = _digest();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        _swap(true, 1e16);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }

    function testCredentialSubjectIsUserAndContractWalletReceivesUnderlying() public {
        sbt.setHolder(alice, 1, false);
        sbt.setHolder(address(router), 1, true);
        sbt.setHolder(address(manager), 1, true);
        sbt.setHolder(address(registry), 1, true);
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(true, 1e16);
        assertEq(_digest(), before_);
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), 1, true);
        quote.mint(address(wallet), 1e20);
        (, uint256 received) = wallet.swapExactInput(router, swapAdapter, _request(false, 1e16));
        assertEq(underlying.balanceOf(address(wallet)), received);
        assertEq(stock.balanceOf(address(wallet)), 0);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
    }

    function testUnapprovedAdapterRejectsWithoutAnyStateChange() public {
        bytes32 before_ = _digest();
        SwapRequest memory request;
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        router.swapExactInputFromContractDirect(request, address(this), alice, alice);
        request = _request(true, 1e16);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        vm.prank(alice);
        router.swapExactInputFromContractDirect(request, address(0), alice, alice);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }
}
