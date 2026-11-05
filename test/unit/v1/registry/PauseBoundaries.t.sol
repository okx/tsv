// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsPauseBoundariesTest is FoundationFixture {
    function testInvalidEmergencyPauseMetadataAndNoopDoNotChangeGates() public {
        _grantPauseRoles();
        bytes32 beforeState = _pauseState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setEmergencyPauseEnable(true, 0);
        assertEq(_pauseState(), beforeState);

        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setEmergencyPauseEnable(false, keccak256("already-disabled"));
        assertEq(_pauseState(), beforeState);

        _enableEmergencyPause();
        beforeState = _pauseState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setEmergencyPauseEnable(false, 0);
        assertEq(_pauseState(), beforeState);

        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setEmergencyPauseEnable(true, keccak256("already-enabled"));
        assertEq(_pauseState(), beforeState);
    }

    function testEmergencyPauseRoleBoundaries() public {
        address pauser = makeAddr("pause-only");
        address resumer = makeAddr("resume-only");
        bytes32 pauseRole = registry.EMERGENCY_PAUSER_ROLE();
        bytes32 resumeRole = registry.EMERGENCY_RESUMER_ROLE();
        registry.grantRole(pauseRole, pauser);
        registry.grantRole(resumeRole, resumer);

        vm.expectRevert(_denied(resumer, pauseRole));
        vm.prank(resumer);
        registry.setEmergencyPauseEnable(true, keccak256("incident"));

        vm.prank(pauser);
        registry.setEmergencyPauseEnable(true, keccak256("incident"));
        assertTrue(registry.emergencyPauseEnable());
        assertTrue(registry.isPaused());
        _assertOperationGates(true, true);

        vm.expectRevert(_denied(pauser, resumeRole));
        vm.prank(pauser);
        registry.setEmergencyPauseEnable(false, keccak256("resume"));

        vm.prank(resumer);
        registry.setEmergencyPauseEnable(false, keccak256("resume"));
        assertFalse(registry.emergencyPauseEnable());
        _assertOperationGates(true, true);
    }

    function testEmergencyPauseEventsCarryOperatorAndReason() public {
        _grantPauseRoles();
        bytes32 pauseReason = keccak256("incident");
        bytes32 resumeReason = keccak256("resolved");

        vm.expectEmit(false, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseChanged(true, address(this), pauseReason);
        registry.setEmergencyPauseEnable(true, pauseReason);

        vm.expectEmit(false, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseChanged(false, address(this), resumeReason);
        registry.setEmergencyPauseEnable(false, resumeReason);
    }

    function _pauseState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.emergencyPauseEnable(),
                registry.isPaused(),
                registry.isTradable(poolId),
                registry.isLPAllowed(poolId)
            )
        );
    }

    function _denied(address caller, bytes32 role) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }
}
