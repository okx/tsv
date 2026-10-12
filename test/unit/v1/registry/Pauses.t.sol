// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PermissionedRegisterParam,
    UnderlyingRecord,
    SecurityOperationStatus,
    SecurityOperationType,
    SecurityPauseMode,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVPausesTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesTest is FoundationFixture {
    function testMarketReportRejectsOutOfRangeActionBeforeStateChanges() public {
        vm.prank(address(inbox));
        (bool ok,) = address(registry).call(
            abi.encodeWithSelector(
                TSVRegistryV1.applySecurityStatus.selector,
                SECURITY,
                uint8(2),
                SecurityPauseMode.ALL,
                bytes32(0)
            )
        );
        assertFalse(ok);
        assertEq(uint8(registry.getSecurityPauseMode(SECURITY)), uint8(SecurityPauseMode.NONE));
        _assertOperationGates(true, true);
    }

    function testRelistingRetainsSecurityPauseState() public {
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.ALL, 1);
        _delistPrimarySecurity();
        _assertOperationGates(false, false);
        PermissionedRegisterParam memory another = _newStockConfig(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(another, 1, bytes32("TEST"));
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST, bytes32("TEST"));
        assertEq(uint8(registry.getSecurityStatus(SECURITY)), uint8(SecurityOperationStatus.HALTED));
        assertEq(uint8(registry.getSecurityPauseMode(SECURITY)), uint8(SecurityPauseMode.ALL));
        _assertOperationGates(false, false);
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.ALL, 2);
        _assertOperationGates(true, true);
    }

    function testLegalAdapterReplacementDoesNotRequirePause() public {
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
        UnderlyingRecord memory config = registry.getUnderlying(address(stockToken));
        assertEq(config.legalShareAdapter, address(replacement));
    }

    function testLegalAdapterReplacementAllowedByGlobalEmergencyPause() public {
        _grantPauseRoles();
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        _enableEmergencyPause();
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement), bytes32("TEST"));
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(replacement));
        _disableEmergencyPause();
    }

    function testEmergencyPauseBlocksBothOperationsAndCanResume() public {
        _grantPauseRoles();
        vm.expectEmit(false, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseChanged(true, address(this), keccak256("pause"));
        _enableEmergencyPause();
        assertTrue(registry.isPaused());
        _assertOperationGates(false, false);

        vm.expectEmit(false, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseChanged(false, address(this), keccak256("resume"));
        _disableEmergencyPause();
        assertFalse(registry.isPaused());
        _assertOperationGates(true, true);
    }

    function testEmergencyPauseRejectsInvalidNoopAndUnauthorizedCallers() public {
        bytes32 pauseRole = registry.EMERGENCY_PAUSER_ROLE();
        bytes32 resumeRole = registry.EMERGENCY_RESUMER_ROLE();
        address stranger = makeAddr("pause-stranger");
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setEmergencyPauseEnable(true, 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setEmergencyPauseEnable(false, keccak256("already-disabled"));

        vm.expectRevert(_denied(stranger, pauseRole));
        vm.prank(stranger);
        registry.setEmergencyPauseEnable(true, keccak256("pause"));
        registry.grantRole(pauseRole, address(this));
        registry.setEmergencyPauseEnable(true, keccak256("pause"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setEmergencyPauseEnable(true, keccak256("again"));
        vm.expectRevert(_denied(address(this), resumeRole));
        registry.setEmergencyPauseEnable(false, keccak256("resume"));
        registry.grantRole(resumeRole, address(this));
        registry.setEmergencyPauseEnable(false, keccak256("resume"));
    }

    function testPauseEventsExposeEmergencyModeAndSecurityMaskChanges() public {
        _grantPauseRoles();
        vm.expectEmit(false, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseChanged(true, address(this), keccak256("pause"));
        _enableEmergencyPause();

        bytes32 reportId =
            keccak256(abi.encode("market-mode", SecurityOperationType.HALT, SecurityPauseMode.TRADE, uint64(2)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(
            SECURITY,
            uint8(SecurityOperationStatus.OPEN),
            uint8(SecurityOperationStatus.HALTED),
            uint8(SecurityPauseMode.NONE),
            uint8(SecurityPauseMode.TRADE),
            reportId
        );
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.TRADE, 2);
        reportId = keccak256(abi.encode("market-mode", SecurityOperationType.HALT, SecurityPauseMode.LP, uint64(3)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SecurityStatusChanged(
            SECURITY,
            uint8(SecurityOperationStatus.HALTED),
            uint8(SecurityOperationStatus.HALTED),
            uint8(SecurityPauseMode.TRADE),
            uint8(SecurityPauseMode.ALL),
            reportId
        );
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.LP, 3);
    }

    function testSecurityPauseModesAccumulateAndResumeIndependently() public {
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.TRADE, 1);
        _assertMarketPause(SecurityPauseMode.TRADE, false, true);
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.ALL, 2);
        _assertMarketPause(SecurityPauseMode.ALL, false, false);
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.TRADE, 3);
        _assertMarketPause(SecurityPauseMode.LP, true, false);
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.ALL, 4);
        _assertMarketPause(SecurityPauseMode.NONE, true, true);
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.LP, 5);
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.TRADE, 6);
        _assertMarketPause(SecurityPauseMode.ALL, false, false);
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.LP, 7);
        _assertMarketPause(SecurityPauseMode.TRADE, false, true);
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.TRADE, 8);
        _assertMarketPause(SecurityPauseMode.NONE, true, true);
    }

    function testSecurityFirstLPPauseAllowsTrading() public {
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.LP, 1);
        _assertMarketPause(SecurityPauseMode.LP, true, false);
    }

    function testSecurityFirstAllPauseBlocksBoth() public {
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.ALL, 1);
        _assertMarketPause(SecurityPauseMode.ALL, false, false);
    }

    function testEmergencyAndSecurityPauseRecoveriesAreIndependent() public {
        _grantPauseRoles();
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.LP, 2);
        _enableEmergencyPause();
        _assertOperationGates(false, false);
        _disableEmergencyPause();
        _assertOperationGates(true, false);
        _enableEmergencyPause();
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.LP, 3);
        _assertOperationGates(false, false);
        _disableEmergencyPause();
        _assertOperationGates(true, true);
    }

    function testUnknownPoolRemainsDisallowed() public {
        assertFalse(registry.isTradable(keccak256("absent-pool")));
        assertFalse(registry.isLPAllowed(keccak256("absent-pool")));
    }

    function _denied(address caller, bytes32 role) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }
}
