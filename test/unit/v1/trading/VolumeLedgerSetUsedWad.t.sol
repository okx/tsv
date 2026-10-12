// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VolumeLedgerFixture, TSVVolumeLedgerV1} from "../../../helpers/v1/VolumeLedgerFixture.sol";

contract TSVVolumeLedgerSetUsedWadTest is VolumeLedgerFixture {
    event UsedWadSet(bytes32 indexed securityId, uint256 indexed ESTDay, uint256 amount, bytes32 reasonCode);

    function testRejectsZeroReasonBeforeWritingUsage() public {
        ledger.setUsedWad(SECURITY, _value(DAY, 10e18), REASON);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidConfig.selector);
        ledger.setUsedWad(SECURITY, _value(DAY, 20e18), bytes32(0));
        assertEq(ledger.usedWad(SECURITY, DAY), 10e18);
    }

    function testRoleGrantAndRevocationControlCorrections() public {
        address oracle = makeAddr("oracle");
        TSVVolumeLedgerV1.DailyQuota[] memory values = _value(DAY, 300e18);
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(oracle);
        ledger.setUsedWad(SECURITY, values, REASON);

        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), oracle);
        vm.prank(oracle);
        ledger.setUsedWad(SECURITY, values, REASON);
        assertEq(ledger.usedWad(SECURITY, DAY), 300e18);

        registry.revokeRole(ledger.VOLUME_ORACLE_ROLE(), oracle);
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(oracle);
        ledger.setUsedWad(SECURITY, values, REASON);

        registry.revokeRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        ledger.setUsedWad(SECURITY, values, REASON); // DEFAULT_ADMIN_ROLE is not sufficient.
    }

    function testRejectsZeroSecurityId() public {
        TSVVolumeLedgerV1.DailyQuota[] memory values = _value(DAY, 300e18);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        ledger.setUsedWad(bytes32(0), values, REASON);
    }

    function testBatchOverwritesUsageEmitsEventsAndPreservesOtherState() public {
        ledger.setQuota(SECURITY, _value(DAY, 1000e18), REASON);
        _swap(300e18);
        ledger.setUsedWad(OTHER_SECURITY, _value(DAY, 20e18), REASON);
        ledger.setUsedWad(SECURITY, _value(DAY + 2, 40e18), REASON);
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](2);
        values[0] = TSVVolumeLedgerV1.DailyQuota(DAY, 100e18);
        values[1] = TSVVolumeLedgerV1.DailyQuota(DAY + 1, 200e18);
        vm.expectEmit(true, true, false, true, address(ledger));
        emit UsedWadSet(SECURITY, DAY, 100e18, REASON);
        vm.expectEmit(true, true, false, true, address(ledger));
        emit UsedWadSet(SECURITY, DAY + 1, 200e18, REASON);
        ledger.setUsedWad(SECURITY, values, REASON);

        assertEq(ledger.usedWad(SECURITY, DAY), 100e18);
        assertEq(ledger.usedWad(SECURITY, DAY + 1), 200e18);
        assertEq(ledger.usedWad(SECURITY, DAY + 2), 40e18);
        assertEq(ledger.usedWad(OTHER_SECURITY, DAY), 20e18);
        assertEq(ledger.Quota(SECURITY, DAY), 1000e18);
        assertEq(ledger.Quota(SECURITY, DAY + 1), 0);
    }

    function testCorrectionControlsNextSwapAndFailedSwapPreservesUsage() public {
        ledger.setQuota(SECURITY, _value(DAY, 1000e18), REASON);
        _swap(300e18);
        ledger.setUsedWad(SECURITY, _value(DAY, 900e18), REASON);
        _swap(100e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _swap(1);
        assertEq(ledger.usedWad(SECURITY, DAY), 1000e18);

        ledger.setUsedWad(SECURITY, _value(DAY, 0), REASON);
        _swap(1000e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1000e18);
    }

    function testUsageAboveQuotaBlocksSwapsUntilQuotaIncreases() public {
        ledger.setQuota(SECURITY, _value(DAY, 1000e18), REASON);
        ledger.setUsedWad(SECURITY, _value(DAY, 1200e18), REASON);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _swap(1e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1200e18);
        ledger.setQuota(SECURITY, _value(DAY, 1300e18), REASON);
        assertEq(ledger.usedWad(SECURITY, DAY), 1200e18);
        _swap(100e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1300e18);
    }

    function testDuplicateDaysUseLastValueAndEmptyBatchDoesNothing() public {
        TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](2);
        values[0] = TSVVolumeLedgerV1.DailyQuota(DAY, 300e18);
        values[1] = TSVVolumeLedgerV1.DailyQuota(DAY, 200e18);
        ledger.setUsedWad(SECURITY, values, REASON);
        assertEq(ledger.usedWad(SECURITY, DAY), 200e18);
        vm.recordLogs();
        ledger.setUsedWad(SECURITY, new TSVVolumeLedgerV1.DailyQuota[](0), REASON);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 200e18);
    }

    function testCorrectionForAnotherDayDoesNotChangeCurrentDay() public {
        ledger.setQuota(SECURITY, _value(DAY, 1000e18), REASON);
        _swap(300e18);
        ledger.setUsedWad(SECURITY, _value(DAY + 1, 900e18), REASON);
        _swap(100e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 400e18);
        vm.warp(1791867600);
        ledger.setQuota(SECURITY, _value(DAY + 1, 1000e18), REASON);
        _swap(100e18);
        assertEq(ledger.usedWad(SECURITY, DAY + 1), 1000e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 400e18);
    }

    function testMulticallUpdatesMultipleSecuritiesAndReturnsResultsInOrder() public {
        address oracle = makeAddr("batch-oracle");
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), oracle);
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(ledger.setQuota, (SECURITY, _value(DAY, 1000e18), REASON));
        calls[1] = abi.encodeCall(ledger.setUsedWad, (SECURITY, _value(DAY, 300e18), REASON));
        calls[2] = abi.encodeCall(ledger.setQuota, (OTHER_SECURITY, _value(DAY, 2000e18), REASON));
        calls[3] = abi.encodeCall(ledger.Quota, (OTHER_SECURITY, DAY));
        calls[4] = abi.encodeCall(ledger.usedWad, (SECURITY, DAY));
        vm.prank(oracle);
        bytes[] memory results = ledger.multicall(calls);

        assertEq(results.length, calls.length);
        for (uint256 i; i < 3; ++i) {
            assertEq(results[i].length, 0);
        }
        assertEq(abi.decode(results[3], (uint256)), 2000e18);
        assertEq(abi.decode(results[4], (uint256)), 300e18);
        assertEq(ledger.Quota(SECURITY, DAY), 1000e18);
        assertEq(ledger.Quota(OTHER_SECURITY, DAY), 2000e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 300e18);
        assertEq(ledger.usedWad(OTHER_SECURITY, DAY), 0);
    }

    function testMulticallRejectsUnauthorizedCallerForEachSetter() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ledger.setQuota, (SECURITY, _value(DAY, 1000e18), REASON));
        address unauthorized = makeAddr("unauthorized-batch-caller");
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(unauthorized);
        ledger.multicall(calls);

        calls[0] = abi.encodeCall(ledger.setUsedWad, (SECURITY, _value(DAY, 300e18), REASON));
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(unauthorized);
        ledger.multicall(calls);
        assertEq(ledger.Quota(SECURITY, DAY), 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testMulticallFailureRollsBackEarlierQuotaAndUsageWrites() public {
        ledger.setQuota(SECURITY, _value(DAY, 1000e18), REASON);
        ledger.setUsedWad(SECURITY, _value(DAY, 300e18), REASON);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(ledger.setQuota, (SECURITY, _value(DAY, 2000e18), REASON));
        calls[1] = abi.encodeCall(ledger.setUsedWad, (SECURITY, _value(DAY, 500e18), REASON));
        calls[2] = abi.encodeCall(ledger.setUsedWad, (bytes32(0), _value(DAY, 1), REASON));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        ledger.multicall(calls);
        assertEq(ledger.Quota(SECURITY, DAY), 1000e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 300e18);
    }

    function testMulticallDoesNotLetOracleBypassHookAuthorization() public {
        address oracle = makeAddr("non-hook-oracle");
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), oracle);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ledger.setQuota, (SECURITY, _value(DAY, 1000e18), REASON));
        calls[1] = abi.encodeCall(ledger.recordSwap, (POOL, -1, 1, 1e18, 0));
        vm.expectRevert(TSVVolumeLedgerV1.Unauthorized.selector);
        vm.prank(oracle);
        ledger.multicall(calls);
        assertEq(ledger.Quota(SECURITY, DAY), 0);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }
}
