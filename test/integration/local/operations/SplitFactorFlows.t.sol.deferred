// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {LedgerV2, InboxV2, GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";

/// @dev Real V4 swaps/positions demonstrate that day-start activation governs the actual quota check.
contract TSVSplitFactorFlowsLocalTest is ProtocolFixture {
    function testAdjustedCapAllowsAdditionalRealTradeOnlyOnTheNewDayAndFailureIsAtomic() public {
        _basis(202609, 40e18); // Tier 25 bps: 0.1 shares/day.
        _trade(8e16);
        _scheduleFactor(20261002, 202609, 2, 1);
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        _rejectTrade(3e16, DAY);
        assertEq(ledger.used(SECURITY, DAY), 8e16);

        vm.warp(start);
        _trade(15e16); // Greater than the old full-day cap of 0.1, below the new cap of 0.2.
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _rejectTrade(6e16, 20261002);
        assertEq(ledger.used(SECURITY, DAY), 8e16);
        assertEq(ledger.adtvOf(SECURITY, 202609).value, 40e18);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertTrue(lpManager.getPosition(positionId).active);
    }

    function testReverseSplitRestrictsRealSwapWhileLPAndOwnerExitRemainAvailable() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 1, 5);
        vm.warp(ledger.dayStartUTC(20261002));
        _rejectTrade(3e16, 20261002);
        _trade(2e16); // Exact adjusted cap.
        _rejectTrade(1, 20261002);
        vm.startPrank(alice);
        lpManager.increaseLiquidity(positionId, 1e16, _pauseTestBounds());
        lpManager.closePosition(positionId, _pauseTestBounds());
        vm.stopPrank();
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(ledger.used(SECURITY, 20261002), 2e16);
    }

    function testTokenMultiplierUpdatesBeforeOrAfterDayStartDoNotSelectTheCapActivationTime() public {
        for (uint8 variant; variant < 2; ++variant) {
            uint256 snapshot = vm.snapshotState();
            _basis(202609, 40e18);
            _scheduleFactor(20261002, 202609, 2, 1);
            uint256 start = ledger.dayStartUTC(20261002);
            if (variant == 0) stockUnderlying.setMultiplier(2e18, 1);
            vm.warp(start - 1);
            (, uint256 left) = ledger.remaining(SECURITY, DAY);
            assertEq(left, 1e17); // A Token update cannot start the cap factor early.
            vm.warp(start);
            (, left) = ledger.remaining(SECURITY, 20261002);
            assertEq(left, 2e17); // A late Token update cannot delay the cap factor.
            if (variant == 1) stockUnderlying.setMultiplier(2e18, 1);
            _trade(3e16);
            assertEq(ledger.used(SECURITY, 20261002), 6e16); // Existing live Adapter accounting is retained.
            (, left) = ledger.remaining(SECURITY, 20261002);
            assertEq(left, 14e16);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testAbsoluteQuotaOverrideAndClearWorkAgainstTheAdjustedCapInRealV4() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 2, 1);
        _quota(20261002, 1, 12e16, 1);
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(1e17);
        _rejectTrade(3e16, 20261002);
        _quota(20261002, 2, 0, 2);
        _trade(5e16);
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _rejectTrade(6e16, 20261002);
    }

    function testPendingFactorAndExistingFundsReportsQuotaRolesSurviveLedgerAndInboxUpgrades() public {
        _basis(202609, 40e18);
        _trade(8e16);
        _scheduleFactor(20261002, 202609, 2, 1);
        _quota(20261002, 1, 18e16, 1);
        bytes32 positionBefore = keccak256(abi.encode(lpManager.getPosition(positionId)));
        bytes32 factorBefore = keccak256(abi.encode(ledger.splitFactorCheckpoint(SECURITY, 202609, 0)));
        ledger.upgradeToAndCall(address(new LedgerV2()), abi.encodeCall(GovernanceMigrationV2.initializeV2, (7, false)));
        inbox.upgradeToAndCall(address(new InboxV2()), abi.encodeCall(GovernanceMigrationV2.initializeV2, (8, false)));
        assertEq(ledger.used(SECURITY, DAY), 8e16);
        assertEq(ledger.adtvOf(SECURITY, 202609).value, 40e18);
        assertEq(ledger.quotaOf(SECURITY, 20261002).quotaWad, 18e16);
        assertEq(keccak256(abi.encode(ledger.splitFactorCheckpoint(SECURITY, 202609, 0))), factorBefore);
        assertEq(keccak256(abi.encode(lpManager.getPosition(positionId))), positionBefore);
        assertTrue(inbox.hasRole(inbox.VOLUME_ORACLE_ROLE(), address(this)));
        assertEq(inbox.lastSequence(3, SECURITY), 1);
        assertEq(ledger.splitFactorVersion(SECURITY, 202609), 1);
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(15e16);
        _rejectTrade(4e16, 20261002);
        _scheduleFactor(20261003, 202609, 3, 1); // Both upgraded components still accept fresh reports.
    }

    function testUpgradeFreezeDoesNotPreventScheduledFactorActivationOrBusinessReporting() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 2, 1);
        address guardian = anchor.guardian();
        vm.prank(guardian);
        anchor.freezeUpgrades();
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(15e16);
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _scheduleFactor(20261003, 202609, 3, 1);
        assertTrue(anchor.upgradesFrozen());
    }

    function _basis(uint32 month, uint256 amount) private {
        registry.setTierPolicy(1, 25, 10);
        uint64 version = ledger.adtvOf(SECURITY, month).version + 1;
        uint64 sequence = inbox.lastSequence(1, SECURITY) + 1;
        inbox.submitAdtv(
            AdtvReport(
                SECURITY,
                month,
                amount,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("factor-basis", month, version))
            )
        );
    }

    function _scheduleFactor(uint32 day, uint32 month, uint128 numerator, uint128 denominator) private {
        uint64 version = ledger.splitFactorVersion(SECURITY, month) + 1;
        uint64 sequence = inbox.lastSequence(3, SECURITY) + 1;
        inbox.submitSplitFactor(
            SplitFactorReport(
                SECURITY,
                month,
                day,
                1,
                numerator,
                denominator,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("local-factor", day, sequence))
            )
        );
    }

    function _quota(uint32 day, uint8 action, uint256 amount, uint64 version) private {
        uint64 sequence = inbox.lastSequence(2, SECURITY) + 1;
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                day,
                action,
                amount,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("factor-quota", day, sequence))
            )
        );
    }

    function _trade(uint128 amount) private {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, amount);
        request.deadline = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        (uint256 actualIn,) = router.swapExactInput(request);
        assertEq(actualIn, amount);
    }

    function _rejectTrade(uint128 amount, uint32 day) private {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), amount);
        request.deadline = uint64(vm.getBlockTimestamp() + 100);
        bytes32 beforeState = _swapStateDigest(day);
        vm.expectRevert(); // V4 wraps the Hook error; unit cases check the exact Ledger error.
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
    }
}
