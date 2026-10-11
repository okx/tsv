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
import {PermissionedAdmission, SwapRequest, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";
import {V1TestParticipantWallet} from "../../../helpers/v1/LocalMocks.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

contract TSVWrappedSwapTest is WrappedSwapFixture {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    function testMeasuresGasForAllFourLocalSwapPaths() public {
        for (uint256 i; i < 4; ++i) {
            uint256 start = gasleft();
            _swap(i < 2, i % 2 == 0, 1e16);
            uint256 consumed = start - gasleft();
            emit log_named_uint(
                i == 0
                    ? "U->Q exactInput gas"
                    : i == 1 ? "U->Q exactOutput gas" : i == 2 ? "Q->U exactInput gas" : "Q->U exactOutput gas",
                consumed
            );
        }
    }

    function testBothDirectionsExactInputAndExactOutputConserveInventoryAndAccountOnce() public {
        for (uint256 i; i < 4; ++i) {
            bool stockInput = i < 2;
            bool exactInput = i % 2 == 0;
            uint256 uBefore = underlying.balanceOf(alice);
            uint256 qBefore = quote.balanceOf(alice);
            uint256 supplyBefore = stock.totalSupply();
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            uint256 surplus = _inventory();
            vm.recordLogs();
            (uint256 paid, uint256 received) = _swap(stockInput, exactInput, 1e16);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (exactInput) assertLe(paid, 1e16);
            else assertEq(received, 1e16);
            assertEq(underlying.balanceOf(alice), stockInput ? uBefore - paid : uBefore + received);
            assertEq(quote.balanceOf(alice), stockInput ? qBefore + received : qBefore - paid);
            assertEq(stock.totalSupply(), stockInput ? supplyBefore + paid : supplyBefore - received);
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockInput ? paid : received);
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
                    logs[j].topics[0]
                        == keccak256("SwapAccounted(bytes32,bytes32,address,address,bool,uint32,uint256,uint256)")
                ) {
                    assertEq(logs[j].emitter, address(ledger));
                    assertEq(logs[j].topics[1], PoolId.unwrap(key.toId()));
                    assertEq(logs[j].topics[2], SECURITY);
                    assertEq(address(uint160(uint256(logs[j].topics[3]))), address(stock));
                    (address recordedUnderlying, bool inputSide, uint32 day, uint256 raw, uint256 shares) =
                        abi.decode(logs[j].data, (address, bool, uint32, uint256, uint256));
                    assertEq(recordedUnderlying, address(underlying));
                    assertEq(inputSide, stockInput);
                    assertEq(day, DAY);
                    assertEq(raw, stockInput ? paid : received);
                    assertEq(shares, ledger.used(SECURITY, DAY) - usedBefore);
                    ++accounted;
                }
            }
            assertEq(accounted, 1);
        }
    }

    function testVerificationDustAndHistoricalSurplusCannotMaskShortPayment() public {
        underlying.mint(address(stock), 1e18);
        uint256 surplus = _inventory();
        _swap(true, true, 1e16);
        _swap(false, false, 1e16);
        assertEq(_inventory(), surplus);
        underlying.setTransferMode(3);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
        underlying.setTransferMode(0);
        _swap(true, true, 1e16);
        assertEq(_inventory(), surplus);
    }

    function testFuzzNonExactTransfersRollback(bool stockInput, bool faultUnderlying, uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        if (faultUnderlying) underlying.setTransferMode(mode);
        else quote.setTransferMode(mode);
        bytes32 before_ = _digest();
        if (mode == 4) {
            _swap(stockInput, true, 1e16); // No-return tokens are supported when their amounts are exact.
            assertEq(_inventory(), 17);
        } else {
            vm.expectRevert();
            _swap(stockInput, true, 1e16);
            assertEq(_digest(), before_);
            assertEq(router.msgSender(), address(0));
        }
    }

    function testFuzzExtraSenderFeesRollbackOnBothSides(bool stockInput, bool feeOnUnderlying) public {
        bool inputToken = stockInput == feeOnUnderlying;
        address sender = inputToken ? alice : feeOnUnderlying ? address(stock) : address(manager);
        if (feeOnUnderlying) underlying.setSenderFee(sender, 100);
        else quote.setSenderFee(sender, 100);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(stockInput, true, 1e16);
        assertEq(_digest(), before_);
    }

    function testUnderCollateralizedStockRejectsBeforeSwap() public {
        deal(address(underlying), address(stock), stock.totalSupply() - 1);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
    }

    function testNonzeroProtocolFeesGrossNetQuotaAndOfficialWithdrawal() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(500) | uint24(700 << 12));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        (uint256 input,) = _swap(true, true, 1e17);
        (, uint256 output) = _swap(false, true, 1e17);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, input + output);
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
        _swap(true, true, 1e17);
        uint256 feesBefore = manager.protocolFeesAccrued(Currency.wrap(address(stock)));
        underlying.setBlockedRecipient(address(recipient));
        bytes32 before_ = _digest();
        vm.expectRevert();
        manager.collectProtocolFees(address(recipient), Currency.wrap(address(stock)), 0);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(stock))), feesBefore);
        assertEq(_digest(), before_);
    }

    function testMultipleWrappersShareQuotaAndCanonicalAdapter() public {
        _swap(true, true, 1e16);
        uint256 alreadyUsed = ledger.used(SECURITY, DAY);
        PermissionsAdapter w2 = _newWrapper();
        registry.registerPermissionedCurrency(PermissionedAdmission(address(w2), SECURITY, address(legalAdapter)), 1);
        PoolKey memory second = _seedPool(w2, 500);
        w2.updateSwappingEnabled(true);
        assertEq(ledger.used(SECURITY, DAY), alreadyUsed);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        vm.prank(alice);
        (uint256 paid,) = router.swapExactInput(
            SwapRequest(
                second,
                Currency.unwrap(second.currency0) == address(w2),
                1e16,
                1,
                uint64(block.timestamp + 100),
                issuer.multiplier()
            )
        );
        assertEq(ledger.used(SECURITY, DAY), alreadyUsed + paid);
        registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.ALL, keccak256("replace"));
        BackedAutoFeeLegalShareAdapter next = new BackedAutoFeeLegalShareAdapter(address(issuer), address(underlying));
        registry.replaceUnderlyingLegalShareAdapter(address(underlying), address(next));
        registry.clearEmergencyPause(1, keccak256("done"));
        vm.expectCall(
            address(next), abi.encodeCall(BackedAutoFeeLegalShareAdapter.toLegalShares, (address(underlying), 1e16)), 2
        );
        vm.recordLogs();
        _swap(true, true, 1e16);
        vm.prank(alice);
        router.swapExactInput(
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
                    && logs[i].topics[0]
                        == keccak256("SwapAccounted(bytes32,bytes32,address,address,bool,uint32,uint256,uint256)")
            ) {
                address recordedCurrency = address(uint160(uint256(logs[i].topics[3])));
                assertEq(recordedCurrency, count == 0 ? address(stock) : address(w2));
                (address recordedUnderlying,,,,) = abi.decode(logs[i].data, (address, bool, uint32, uint256, uint256));
                assertEq(recordedUnderlying, address(underlying));
                ++count;
            }
        }
        assertEq(count, 2);
    }

    function testQuotaFailureRollsBackPoolInventoryAndEvents() public {
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                DAY,
                1,
                1,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 100),
                1,
                keccak256("quota-report")
            )
        );
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
        _swap(true, true, 1e16);
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
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), 1, true);
        quote.mint(address(wallet), 1e20);
        wallet.approveToken(address(quote), address(router));
        (, uint256 received) = wallet.swapExactInput(router, _request(false, true, 1e16));
        assertEq(underlying.balanceOf(address(wallet)), received);
        assertEq(stock.balanceOf(address(wallet)), 0);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
    }

    function testUnapprovedAdapterRejectsWithoutAnyStateChange() public {
        bytes32 before_ = _digest();
        SwapRequest memory request;
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        router.swapExactInputFromAdapter(request, alice);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        vm.prank(alice);
        router.swapExactInputFromAdapter(_request(true, true, 1e16), alice);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }
}
