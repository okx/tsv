// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {SecurityPauseMode, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TSVSecurityPausesTest is FoundationFixture {
    function testModesSetFinalGatesWithoutAccumulatingPreviousMask() public {
        _setSecurityMode(SecurityPauseMode.TRADE);
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.LP);
        _assertOperationGates(true, false);
        _setSecurityMode(SecurityPauseMode.ALL);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.NONE);
        _assertOperationGates(true, true);
    }

    function testSecurityModeEventsIdentifyPreviousAndFinalModes() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(SECURITY, SecurityPauseMode.NONE, SecurityPauseMode.TRADE);
        _setSecurityMode(SecurityPauseMode.TRADE);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(SECURITY, SecurityPauseMode.TRADE, SecurityPauseMode.LP);
        _setSecurityMode(SecurityPauseMode.LP);
    }

    function testZeroReasonNoopUnknownAndDelistedSecurityRejectAtomically() public {
        bytes32 beforeState = keccak256(abi.encode(registry.getSecurity(SECURITY)));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        _setSecurityMode(SecurityPauseMode.NONE);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applySecurityStatus(bytes32(0), SecurityPauseMode.TRADE, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applySecurityStatus(keccak256("unknown-security"), SecurityPauseMode.TRADE, bytes32("TEST"));
        assertEq(keccak256(abi.encode(registry.getSecurity(SECURITY))), beforeState);
        _delistPrimarySecurity();
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        _setSecurityMode(SecurityPauseMode.TRADE);
    }

    function testHaltReporterGrantAndRevocationControlFinalModeSetter() public {
        address reporter = makeAddr("halt-reporter");
        bytes32 role = registry.HALT_REPORTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, role)
        );
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, bytes32("TEST"));
        registry.grantRole(role, reporter);
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.TRADE, bytes32("TEST"));
        registry.revokeRole(role, reporter);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, role)
        );
        vm.prank(reporter);
        registry.applySecurityStatus(SECURITY, SecurityPauseMode.NONE, bytes32("TEST"));
        assertEq(uint8(registry.getSecurityPauseMode(SECURITY)), uint8(SecurityPauseMode.TRADE));
    }

    function testGlobalPauseFlagIsIndependentOfSecurityModeViews() public {
        _grantPauseRoles();
        _setSecurityMode(SecurityPauseMode.TRADE);
        _enableEmergencyPause();
        assertTrue(registry.isPaused());
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.LP);
        assertTrue(registry.isPaused());
        _assertOperationGates(true, false);
        _disableEmergencyPause();
        assertFalse(registry.isPaused());
        _assertOperationGates(true, false);
    }

    function testLifecyclePauseAllowsLPAndSecurityResumeDoesNotRelistPool() public {
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE, bytes32("TEST"));
        _assertOperationGates(false, true);
        _setSecurityMode(SecurityPauseMode.ALL);
        _assertOperationGates(false, false);
        _setSecurityMode(SecurityPauseMode.NONE);
        _assertOperationGates(false, true);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST"));
        _assertOperationGates(false, false);
    }
}
