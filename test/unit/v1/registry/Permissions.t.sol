// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TokenConfig, TokenStatus, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";
import {OperationsSbt} from "../../../helpers/v1/OperationsMocks.sol";

contract TSVOperationsPermissionsTest is OperationsFixture {
    function testEverySymbolAdminEntryRejectsUnassignedAndRevokedRoleIncludingGovernor() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        address operator = makeAddr("symbol-operator");
        TokenConfig memory config = _newStockConfig(keccak256("new-security"));
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(TSVRegistryV1.admitSecurity, (config.securityId, 1, config));
        calls[1] = abi.encodeCall(TSVRegistryV1.registerToken, (config));
        calls[2] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY));
        calls[3] = abi.encodeCall(TSVRegistryV1.delistSecurity, (SECURITY));
        calls[4] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 2));
        calls[5] = abi.encodeCall(TSVRegistryV1.setTokenStatus, (address(stock), TokenStatus.DISABLED));
        calls[6] = abi.encodeCall(TSVRegistryV1.replaceLegalShareAdapter, (address(stock), address(stockAdapter)));
        calls[7] = abi.encodeCall(TSVRegistryV1.disablePool, (poolId));
        calls[8] = abi.encodeCall(TSVRegistryV1.enablePool, (poolId));
        bytes32 beforeState = _state();
        _denyCalls(calls, operator, role);
        registry.grantRole(role, operator);
        vm.prank(operator);
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED);
        vm.prank(operator);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED);
        registry.revokeRole(role, operator);
        _denyCalls(calls, operator, role);
        registry.revokeRole(role, address(this));
        _denyCalls(calls, address(this), role);
        assertEq(_state(), beforeState);
    }

    function testPauserAndResumerCannotActForEachOtherAndRevocationTakesEffect() public {
        address pauser = makeAddr("pause-only");
        address resumer = makeAddr("resume-only");
        bytes32 pauseRole = registry.EMERGENCY_PAUSER_ROLE();
        bytes32 resumeRole = registry.EMERGENCY_RESUMER_ROLE();
        registry.grantRole(pauseRole, pauser);
        registry.grantRole(resumeRole, resumer);
        vm.expectRevert(_denied(resumer, pauseRole));
        vm.prank(resumer);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"));
        vm.prank(pauser);
        uint256 id = registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"));
        vm.expectRevert(_denied(pauser, resumeRole));
        vm.prank(pauser);
        registry.clearEmergencyPause(id, keccak256("resume"));
        registry.revokeRole(resumeRole, resumer);
        vm.expectRevert(_denied(resumer, resumeRole));
        vm.prank(resumer);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(false, false);
        registry.grantRole(resumeRole, resumer);
        vm.prank(resumer);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        registry.revokeRole(pauseRole, pauser);
        vm.expectRevert(_denied(pauser, pauseRole));
        vm.prank(pauser);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"));
        assertEq(registry.nextPauseId(), 2);
    }

    function testBusinessOperatorsCannotChangeGovernorConfigurationOrDaySchedule() public {
        address operator = makeAddr("business-only");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), operator);
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), operator);
        OperationsSbt sbt = new OperationsSbt();
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        registry.setTierPolicy(2, 10, 1);
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        registry.setSbtConfig(address(sbt), 1);
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        ledger.scheduleDayStart(18000, 20261004);
        ledger.scheduleDayStart(18000, 20261004);
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        ledger.cancelPendingDayStart();
        assertEq(ledger.dayStartCheckpointCount(), 1);
        assertEq(registry.tierPolicy(2).tierBps, 0);
        assertEq(address(registry.participantSbt()), address(0));
    }

    function testPoolIntercontractEntriesRequireBoundLpManager() public {
        bytes32 beforeState = _state();
        address stranger = makeAddr("not-lp-manager");
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        vm.prank(stranger);
        registry.registerPendingPool(key);
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        vm.prank(stranger);
        registry.markPoolActive(poolId, uint160(1 << 96), stranger);
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        vm.prank(stranger);
        _charge(1e18);
        assertEq(_state(), beforeState);
    }

    function _denyCalls(bytes[] memory calls, address caller, bytes32 role) private {
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(_denied(caller, role));
            vm.prank(caller);
            (bool ok, bytes memory result) = address(registry).call(calls[i]);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _denied(address caller, bytes32 role) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.getToken(address(stock)),
                registry.getPool(poolId),
                registry.tierPolicy(1),
                ledger.used(SECURITY, DAY),
                registry.nextPauseId()
            )
        );
    }
}
