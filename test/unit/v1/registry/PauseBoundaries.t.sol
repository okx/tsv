// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsPauseBoundariesTest is FoundationFixture {
    function testInvalidPauseMetadataAndTargetsDoNotAllocateIdOrChangeGates() public {
        _grantPauseRoles();
        for (uint8 fault; fault < 7; ++fault) {
            PauseScope scope = PauseScope.GLOBAL;
            bytes32 target;
            PauseMode mode = PauseMode.ALL;
            bytes32 reason = keccak256("incident");
            bytes32 source = keccak256("source");
            if (fault == 0) reason = 0;
            else if (fault == 1) source = 0;
            else if (fault == 2) target = SECURITY;
            else if (fault == 3) scope = PauseScope.SECURITY;
            else if (fault == 4) scope = PauseScope.TOKEN;
            else if (fault == 5) scope = PauseScope.POOL;
            else mode = PauseMode.NONE;
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.addEmergencyPause(scope, target, mode, reason, source);
            assertEq(registry.nextPauseId(), 1);
            assertEq(registry.activePauseCount(uint8(scope), target, uint8(mode)), 0);
            _assertOperationGates(true, true);
        }
        (bool ok,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(4),
                    bytes32(0),
                    uint8(PauseMode.ALL),
                    keccak256("incident"),
                    keccak256("source")
                )
            );
        assertFalse(ok);
        assertEq(registry.nextPauseId(), 1);
    }

    function testPauseAuditMetadataSurvivesClearAndIdsAreNeverReused() public {
        _grantPauseRoles();
        bytes32 reason = keccak256("incident");
        bytes32 source = keccak256("source");
        uint64 opened = uint64(block.timestamp);
        uint256 id = registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.LP, reason, source);
        (
            PauseScope scope,
            bytes32 target,
            PauseMode mode,
            bytes32 savedReason,
            bytes32 savedSource,
            address operator,
            uint64 timestamp,
            bool active
        ) = registry.emergencyPauses(id);
        assertEq(uint8(scope), uint8(PauseScope.SECURITY));
        assertEq(target, SECURITY);
        assertEq(uint8(mode), uint8(PauseMode.LP));
        assertEq(savedReason, reason);
        assertEq(savedSource, source);
        assertEq(operator, address(this));
        assertEq(timestamp, opened);
        assertTrue(active);
        bytes32 beforeState = _pauseState(id);
        uint256[3] memory invalid = [uint256(0), 999, id];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.clearEmergencyPause(invalid[i], i == 2 ? bytes32(0) : keccak256("clear"));
            assertEq(_pauseState(id), beforeState);
        }
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseClosed(id, keccak256("resolved"));
        registry.clearEmergencyPause(id, keccak256("resolved"));
        (,,, savedReason, savedSource, operator, timestamp, active) = registry.emergencyPauses(id);
        assertFalse(active);
        assertEq(savedReason, reason);
        assertEq(savedSource, source);
        assertEq(operator, address(this));
        assertEq(timestamp, opened);
        assertEq(_pause(PauseScope.SECURITY, SECURITY, PauseMode.LP), id + 1);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.clearEmergencyPause(id, keccak256("old-record"));
        assertEq(registry.activePauseCount(uint8(PauseScope.SECURITY), SECURITY, uint8(PauseMode.LP)), 1);
    }

    function _pauseState(uint256 id) private view returns (bytes32) {
        (
            PauseScope scope,
            bytes32 target,
            PauseMode mode,
            bytes32 reason,
            bytes32 source,
            address operator,
            uint64 timestamp,
            bool active
        ) = registry.emergencyPauses(id);
        return keccak256(
            abi.encode(
                scope,
                target,
                mode,
                reason,
                source,
                operator,
                timestamp,
                active,
                registry.nextPauseId(),
                registry.activePauseCount(uint8(scope), target, uint8(mode)),
                registry.isTradable(poolId),
                registry.isLPAllowed(poolId)
            )
        );
    }
}
