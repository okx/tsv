// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {SecurityPauseMode, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TSVSecurityPausesTest is FoundationFixture {
    function testIndependentBitsAccumulateAndClearWithoutChangingOtherOperation() public {
        _setSecurityMode(SecurityPauseMode.TRADE, true);
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.LP, true);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.TRADE, false);
        _assertOperationGates(true, false);
        _setSecurityMode(SecurityPauseMode.ALL, true);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.ALL, false);
        _assertOperationGates(true, true);
    }

    function testSecurityModeEventsIdentifyPreviousAndFinalModes() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(SECURITY, 0, 1);
        _setSecurityMode(SecurityPauseMode.TRADE, true);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(SECURITY, 1, 3);
        _setSecurityMode(SecurityPauseMode.LP, true);
    }

    function testZeroReasonNoopUnknownAndDelistedSecurityRejectAtomically() public {
        bytes32 beforeState = keccak256(abi.encode(registry.getSecurity(SECURITY)));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, true, 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        _setSecurityMode(SecurityPauseMode.ALL, false);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applySecurityStatus(bytes32(0), SecurityPauseMode.TRADE, true, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applySecurityStatus(keccak256("unknown-security"), SecurityPauseMode.TRADE, true, bytes32("TEST"));
        assertEq(keccak256(abi.encode(registry.getSecurity(SECURITY))), beforeState);
        _delistPrimarySecurity();
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        _setSecurityMode(SecurityPauseMode.TRADE, true);
    }

    function testHaltReporterGrantAndRevocationControlFinalModeSetter() public {
        address reporter = makeAddr("halt-reporter");
        bytes32 role = registry.HALT_REPORTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, role)
        );
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, true, bytes32("TEST"));
        registry.grantRole(role, reporter);
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, true, bytes32("TEST"));
        registry.revokeRole(role, reporter);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, role)
        );
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.ALL, false, bytes32("TEST"));
        assertEq(uint8(registry.getSecurityPauseMode(SECURITY)), 1);
    }

    function testGlobalPauseFlagIsIndependentOfSecurityModeViews() public {
        _grantPauseRoles();
        _setSecurityMode(SecurityPauseMode.TRADE, true);
        _enableEmergencyPause();
        assertTrue(registry.isPaused());
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.TRADE, false);
        _setSecurityMode(SecurityPauseMode.LP, true);
        assertTrue(registry.isPaused());
        _assertOperationGates(true, false);
        _disableEmergencyPause();
        assertFalse(registry.isPaused());
        _assertOperationGates(true, false);
    }

    function testLifecyclePauseAllowsLPAndSecurityResumeDoesNotRelistPool() public {
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE, bytes32("TEST"));
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.ALL, true);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.ALL, false);
        _assertOperationGates(false, true);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST"));
        _assertOperationGates(false, false);
    }

    /// @dev Cover every initial mask and every selector/enable combination against an
    ///      independent boolean model; also check both query surfaces and pool gates.
    function testFuzzBitUpdatesPreserveOtherOperation(uint8 initial, uint8 selector, bool enable) public {
        initial = uint8(bound(initial, 0, 3));
        selector = uint8(bound(selector, 0, 2));
        if ((initial & 1) != 0) _setSecurityMode(SecurityPauseMode.TRADE, true);
        if ((initial & 2) != 0) _setSecurityMode(SecurityPauseMode.LP, true);
        bool trade = (initial & 1) != 0;
        bool lp = (initial & 2) != 0;
        SecurityPauseMode mode = SecurityPauseMode(selector);
        if (mode != SecurityPauseMode.LP) trade = enable;
        if (mode != SecurityPauseMode.TRADE) lp = enable;
        uint8 expected = (trade ? 1 : 0) + (lp ? 2 : 0);
        if (expected == initial) vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        _setSecurityMode(mode, enable);
        assertEq(registry.getSecurityPauseMode(SECURITY), expected);
        assertEq(registry.getSecurity(SECURITY).pauseMode, expected);
        _assertOperationGates(!trade, !lp);
    }

    function testAllEnableAndDisableUpdatesBothBits() public {
        _setSecurityMode(SecurityPauseMode.ALL, true);
        assertEq(registry.getSecurity(SECURITY).pauseMode, 3);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.ALL, false);
        assertEq(registry.getSecurityPauseMode(SECURITY), 0);
        _assertOperationGates(true, true);
    }

    function testUnknownSecurityQueriesReturnUnpaused() public view {
        assertEq(registry.getSecurityPauseMode(bytes32(0)), 0);
        assertEq(registry.getSecurity(keccak256("unknown")).pauseMode, 0);
    }

}
