// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VolumeLedgerFixture,
    TSVVolumeLedgerV1,
    PoolRecord,
    TSVRegistryV1
} from "../../../helpers/v1/VolumeLedgerFixture.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

contract TSVVolumeLedgerAccountingTest is VolumeLedgerFixture {
    event QuotaSet(bytes32 indexed securityId, uint256 indexed ESTDay, uint256 amount, bytes32 reasonCode);

    function testInitializerRejectsRegistryWithoutCode() public {
        address implementation = address(new TSVVolumeLedgerV1());
        address[2] memory invalid = [address(0), makeAddr("no-code-registry")];
        for (uint256 i; i < invalid.length; ++i) {
            bytes memory initialization = abi.encodeCall(TSVVolumeLedgerV1.initialize, (invalid[i]));
            vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
            new TSVERC1967Proxy(implementation, initialization);
        }
    }

    function testDirectQuotaBatchHasNoFormerReportLimitOfOneHundred() public {
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](128);
        for (uint256 i; i < values.length; ++i) {
            values[i] = TSVVolumeLedgerV1.DailyQuota(DAY + i, i + 1);
        }
        ledger.setQuota(SECURITY, values, REASON);
        for (uint256 i; i < values.length; ++i) {
            assertEq(ledger.Quota(SECURITY, DAY + i), i + 1);
        }
    }

    function testQuotaRequiresOracleRoleAndNonzeroSecurityAndReason() public {
        TSVVolumeLedgerV1.DailyQuota[] memory values = _value(DAY, 100e18);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        ledger.setQuota(bytes32(0), values, REASON);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidConfig.selector);
        ledger.setQuota(SECURITY, values, bytes32(0));
        registry.revokeRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        ledger.setQuota(SECURITY, values, REASON);
        assertEq(ledger.Quota(SECURITY, DAY), 0);
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        ledger.setQuota(SECURITY, values, REASON);
        assertEq(ledger.Quota(SECURITY, DAY), 100e18);
    }

    function testQuotaBatchPreservesUsageAndOtherSecuritiesAndDays() public {
        ledger.setUsedWad(SECURITY, _value(DAY, 50e18), REASON);
        ledger.setQuota(OTHER_SECURITY, _value(DAY, 17e18), REASON);
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](3);
        values[0] = TSVVolumeLedgerV1.DailyQuota(DAY - 1, 10e18);
        values[1] = TSVVolumeLedgerV1.DailyQuota(DAY, 100e18);
        values[2] = TSVVolumeLedgerV1.DailyQuota(DAY + 1, 200e18);
        for (uint256 i; i < values.length; ++i) {
            vm.expectEmit(true, true, false, true, address(ledger));
            emit QuotaSet(SECURITY, values[i].ESTDay, values[i].amount, REASON);
        }
        ledger.setQuota(SECURITY, values, REASON);
        assertEq(ledger.Quota(SECURITY, DAY - 1), 10e18);
        assertEq(ledger.Quota(SECURITY, DAY), 100e18);
        assertEq(ledger.Quota(SECURITY, DAY + 1), 200e18);
        assertEq(ledger.Quota(OTHER_SECURITY, DAY), 17e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 50e18);
    }

    function testQuotaAllowsEmptyBatchUnsortedDaysAndLastDuplicateWins() public {
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](3);
        values[0] = TSVVolumeLedgerV1.DailyQuota(DAY + 100, 10);
        values[1] = TSVVolumeLedgerV1.DailyQuota(0, 20);
        values[2] = TSVVolumeLedgerV1.DailyQuota(DAY + 100, 30);
        ledger.setQuota(SECURITY, values, REASON);
        assertEq(ledger.Quota(SECURITY, 0), 20);
        assertEq(ledger.Quota(SECURITY, DAY + 100), 30);
        vm.recordLogs();
        ledger.setQuota(SECURITY, new TSVVolumeLedgerV1.DailyQuota[](0), REASON);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(ledger.Quota(SECURITY, DAY + 100), 30);
    }

    function testQuotaCanBeReducedBelowUsageWithoutResettingIt() public {
        ledger.setQuota(SECURITY, _value(DAY, 100), REASON);
        _swap(50);
        ledger.setQuota(SECURITY, _value(DAY, 0), REASON);
        assertEq(ledger.usedWad(SECURITY, DAY), 50);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _swap(1);
        assertEq(ledger.usedWad(SECURITY, DAY), 50);
        ledger.setQuota(SECURITY, _value(DAY, 51), REASON);
        _swap(1);
        assertEq(ledger.usedWad(SECURITY, DAY), 51);
    }

    function testDefaultQuotaRejectsVolumeAndRollsBackUsage() public {
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _swap(1);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testRecordSwapOnlyAcceptsBoundHook() public {
        ledger.setQuota(SECURITY, _value(DAY, 100), REASON);
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(makeAddr("not-hook"));
        ledger.recordSwap(POOL, -1, 1, 10, 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testInvalidDeltasAndLegalShareLegsNeverChargeVolume() public {
        ledger.setQuota(SECURITY, _value(DAY, 100), REASON);
        int128[6] memory delta0 = [int128(0), -1, 1, -1, -1, -1];
        int128[6] memory delta1 = [int128(1), 0, 1, -1, 1, 1];
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
            ledger.recordSwap(POOL, delta0[i], delta1[i], i == 4 ? 0 : 1, i == 5 ? 1 : 0);
            assertEq(ledger.usedWad(SECURITY, DAY), 0);
        }
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        ledger.recordSwap(keccak256("unknown-pool"), -1, 1, 10, 0);
    }

    function testOppositeDirectionsAndEitherStockLegConsumeSameSecurityQuota() public {
        ledger.setQuota(SECURITY, _value(DAY, 100), REASON);
        ledger.recordSwap(POOL, type(int128).min, 1, 20, 0);
        ledger.recordSwap(POOL, 1, type(int128).min, 0, 30);
        assertEq(ledger.usedWad(SECURITY, DAY), 50);
    }

    function testMultiplePoolsShareQuotaButOtherSecuritiesAreIndependent() public {
        bytes32 secondPool = keccak256("second-pool");
        bytes32 otherPool = keccak256("other-security-pool");
        PoolRecord memory pool;
        pool.securityId = SECURITY;
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.getPool, (secondPool)), abi.encode(pool));
        pool.securityId = OTHER_SECURITY;
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.getPool, (otherPool)), abi.encode(pool));
        ledger.setQuota(SECURITY, _value(DAY, 100), REASON);
        ledger.setQuota(OTHER_SECURITY, _value(DAY, 50), REASON);
        _swap(60);
        ledger.recordSwap(secondPool, 1, -1, 0, 40);
        ledger.recordSwap(otherPool, -1, 1, 50, 0);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        ledger.recordSwap(secondPool, -1, 1, 1, 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 100);
        assertEq(ledger.usedWad(OTHER_SECURITY, DAY), 50);
    }

    function testESTMidnightStartsSeparateQuotaAtFiveUTC() public {
        uint256 boundary = (DAY + 1) * 1 days + 5 hours;
        ledger.setQuota(SECURITY, _value(DAY, 10), REASON);
        ledger.setQuota(SECURITY, _value(DAY + 1, 20), REASON);
        vm.warp(boundary - 1);
        assertEq(ledger.currentESTDay(), DAY);
        _swap(10);
        vm.warp(boundary);
        assertEq(ledger.currentESTDay(), DAY + 1);
        _swap(20);
        assertEq(ledger.usedWad(SECURITY, DAY), 10);
        assertEq(ledger.usedWad(SECURITY, DAY + 1), 20);
    }

    function testFixedESTHasNoSummerOrWinterOffsetChanges() public {
        // January and July 2026, at 04:59:59 UTC and 05:00:00 UTC.
        uint256[2] memory boundaries = [uint256(1767243600), uint256(1782882000)];
        for (uint256 i; i < boundaries.length; ++i) {
            vm.warp(boundaries[i] - 1);
            uint256 beforeDay = ledger.currentESTDay();
            vm.warp(boundaries[i]);
            assertEq(ledger.currentESTDay(), beforeDay + 1);
        }
    }

    function testFuzzESTDayMatchesFixedOffset(uint64 timestamp) public {
        timestamp = uint64(bound(timestamp, 5 hours, type(uint64).max));
        vm.warp(timestamp);
        uint256 utcDay = timestamp / 1 days;
        uint256 expected = timestamp % 1 days < 5 hours ? utcDay - 1 : utcDay;
        assertEq(ledger.currentESTDay(), expected);
    }

    function testFuzzExactQuotaBoundaryAndExcessRollback(uint128 quota, uint128 first) public {
        quota = uint128(bound(quota, 2, type(uint128).max));
        first = uint128(bound(first, 1, quota - 1));
        ledger.setQuota(SECURITY, _value(DAY, quota), REASON);
        _swap(first);
        _swap(uint256(quota) - first);
        assertEq(ledger.usedWad(SECURITY, DAY), quota);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _swap(1);
        assertEq(ledger.usedWad(SECURITY, DAY), quota);
    }

    function testMulticallZeroReasonRollsBackEarlierQuotaAndUsage() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(ledger.setQuota, (SECURITY, _value(DAY, 100), REASON));
        calls[1] = abi.encodeCall(ledger.setUsedWad, (SECURITY, _value(DAY, 20), REASON));
        calls[2] = abi.encodeCall(ledger.setUsedWad, (SECURITY, _value(DAY, 30), bytes32(0)));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidConfig.selector);
        ledger.multicall(calls);
        assertEq(ledger.Quota(SECURITY, DAY), 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }
}
