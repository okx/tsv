// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

contract V1Counter {
    uint256 public count;

    function increment() external {
        count++;
    }
}

contract TSVGovernanceTest is Test {
    TSVUpgradeTimelock internal timelock;
    TSVBusinessAuthority internal authority;
    TSVEmergencyUpgradeController internal controller;
    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;

    function setUp() public {
        vm.warp(1_800_000_000);
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelock = new TSVUpgradeTimelock(address(this), guardian, council, executors);
        authority = new TSVBusinessAuthority(address(this), address(timelock));
        controller = new TSVEmergencyUpgradeController(address(this), guardian, address(timelock));
        _execute(
            address(timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindBusinessAuthority, (address(authority))),
            keccak256("bind-authority"),
            0
        );
        _execute(
            address(timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindEmergencyController, (address(controller))),
            keccak256("bind-controller"),
            0
        );
        anchor = new TSVGovernanceAnchor(address(timelock), address(authority), address(controller));
        _execute(
            address(timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindGovernanceAnchor, (address(anchor))),
            keccak256("bind-anchor"),
            0
        );
    }

    function testPerOperationDelayAndGuardianCancel() public {
        V1Counter counter = new V1Counter();
        bytes memory callData = abi.encodeCall(V1Counter.increment, ());
        bytes32 salt = keccak256("delay");
        timelock.schedule(address(counter), 0, callData, 0, salt, 2 days);
        vm.expectRevert();
        timelock.execute(address(counter), 0, callData, 0, salt);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(counter), 0, callData, 0, salt);
        assertEq(counter.count(), 1);

        bytes32 cancelSalt = keccak256("cancel");
        timelock.schedule(address(counter), 0, callData, 0, cancelSalt, 0);
        bytes32 id = timelock.hashOperation(address(counter), 0, callData, 0, cancelSalt);
        vm.prank(guardian);
        timelock.cancel(id);
        vm.expectRevert();
        timelock.execute(address(counter), 0, callData, 0, cancelSalt);
        assertEq(counter.count(), 1);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.updateDelay(1);
    }

    function testImmediateUpgradeCanFreezeWhileNormalUpgradeStillWorks() public {
        TSVRegistryV1 first = new TSVRegistryV1();
        TSVERC1967Proxy proxy = new TSVERC1967Proxy(
            address(first),
            abi.encodeCall(TSVRegistryV1.initialize, (address(anchor), address(timelock), address(controller)))
        );
        _execute(
            address(controller),
            abi.encodeCall(TSVEmergencyUpgradeController.setUpgradeTarget, (address(proxy), true)),
            keccak256("target"),
            0
        );
        _execute(
            address(controller),
            abi.encodeCall(
                TSVEmergencyUpgradeController.unfreezeEmergencyUpgrades, (bytes32(0), keccak256("unfreeze"))
            ),
            keccak256("unfreeze-op"),
            0
        );
        TSVRegistryV1 second = new TSVRegistryV1();
        controller.executeEmergencyUpgrade(
            address(proxy),
            address(second),
            "",
            keccak256("incident"),
            keccak256("action-1"),
            keccak256("reason"),
            keccak256("evidence")
        );
        assertEq(proxy.tsvImplementation(), address(second));
        vm.prank(guardian);
        controller.freezeEmergencyUpgrades(keccak256("incident"), keccak256("freeze"), keccak256("salt"));
        TSVRegistryV1 third = new TSVRegistryV1();
        vm.expectRevert(TSVEmergencyUpgradeController.UpgradeFrozen.selector);
        controller.executeEmergencyUpgrade(
            address(proxy),
            address(third),
            "",
            keccak256("incident"),
            keccak256("action-2"),
            keccak256("reason"),
            keccak256("evidence")
        );
        _execute(
            address(proxy),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(third), bytes("")),
            keccak256("normal-upgrade"),
            0
        );
        assertEq(proxy.tsvImplementation(), address(third));
        assertTrue(controller.frozen());
    }

    function testProtectedRecoveryChangesRootAndCannotBeCancelled() public {
        address newGovernor = makeAddr("new-governor");
        address newGuardian = makeAddr("new-guardian");
        bytes memory payload = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities, (newGovernor, newGuardian, keccak256("recovery-evidence"))
        );
        bytes32 salt = keccak256("recovery-salt");
        vm.prank(council);
        timelock.schedule(address(timelock), 0, payload, 0, salt, 0);
        bytes32 id = timelock.hashOperation(address(timelock), 0, payload, 0, salt);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(TSVUpgradeTimelock.ProtectedOperation.selector, id));
        timelock.cancel(id);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.execute(address(timelock), 0, payload, 0, salt);
        vm.prank(guardian);
        timelock.approveRecovery(id);
        vm.prank(guardian);
        timelock.revokeRecoveryApproval(id);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.execute(address(timelock), 0, payload, 0, salt);
        vm.prank(guardian);
        timelock.approveRecovery(id);
        timelock.execute(address(timelock), 0, payload, 0, salt);
        assertEq(authority.governor(), newGovernor);
        assertEq(controller.governor(), newGovernor);
        assertEq(controller.guardian(), newGuardian);
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), newGovernor));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), newGuardian));
        assertEq(anchor.guardian(), newGuardian);
        assertEq(anchor.guardianEpoch(), 1);
    }

    function testCouncilCannotScheduleUpgradeAndGovernorCannotChangeProtectedRoles() public {
        V1Counter counter = new V1Counter();
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), council));
        vm.prank(council);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.schedule(address(counter), 0, abi.encodeCall(V1Counter.increment, ()), 0, keccak256("bad"), 0);

        bytes memory grant =
            abi.encodeCall(TSVUpgradeTimelock.grantRole, (timelock.PROPOSER_ROLE(), makeAddr("attacker")));
        bytes32 salt = keccak256("grant");
        timelock.schedule(address(timelock), 0, grant, 0, salt, 0);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.execute(address(timelock), 0, grant, 0, salt);

        bytes memory revokeExecutor = abi.encodeCall(TSVUpgradeTimelock.revokeRole, (timelock.EXECUTOR_ROLE(), council));
        bytes32 executorSalt = keccak256("revoke-recovery-executor");
        timelock.schedule(address(timelock), 0, revokeExecutor, 0, executorSalt, 0);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.execute(address(timelock), 0, revokeExecutor, 0, executorSalt);
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), council));
    }

    function testRecoveryRejectsCouncilOrCrossedRootIdentities() public {
        bytes memory councilAsGovernor = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities, (council, makeAddr("other-guardian"), keccak256("evidence"))
        );
        vm.prank(council);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.schedule(address(timelock), 0, councilAsGovernor, 0, keccak256("council-as-governor"), 0);

        bytes memory guardianAsGovernor = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities, (guardian, makeAddr("other-guardian"), keccak256("evidence"))
        );
        vm.prank(council);
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.schedule(address(timelock), 0, guardianAsGovernor, 0, keccak256("guardian-as-governor"), 0);
    }

    function testOldGuardianApprovalExpiresAfterGuardianRotation() public {
        address firstGuardian = makeAddr("first-new-guardian");
        bytes memory first = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities, (address(this), firstGuardian, keccak256("first-evidence"))
        );
        bytes memory second = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities,
            (makeAddr("second-governor"), makeAddr("second-guardian"), keccak256("second-evidence"))
        );
        bytes32 firstSalt = keccak256("first-recovery");
        bytes32 secondSalt = keccak256("second-recovery");
        vm.prank(council);
        timelock.schedule(address(timelock), 0, first, 0, firstSalt, 0);
        vm.prank(council);
        timelock.schedule(address(timelock), 0, second, 0, secondSalt, 0);
        bytes32 firstId = timelock.hashOperation(address(timelock), 0, first, 0, firstSalt);
        bytes32 secondId = timelock.hashOperation(address(timelock), 0, second, 0, secondSalt);
        vm.startPrank(guardian);
        timelock.approveRecovery(firstId);
        timelock.approveRecovery(secondId);
        vm.stopPrank();

        timelock.execute(address(timelock), 0, first, 0, firstSalt);
        assertEq(anchor.guardian(), firstGuardian);
        assertTrue(timelock.guardianApprovedRecovery(secondId));
        vm.expectRevert(TSVUpgradeTimelock.InvalidRecovery.selector);
        timelock.execute(address(timelock), 0, second, 0, secondSalt);
        vm.prank(firstGuardian);
        timelock.approveRecovery(secondId);
        timelock.execute(address(timelock), 0, second, 0, secondSalt);
        assertEq(timelock.guardian(), makeAddr("second-guardian"));
    }

    function _execute(address target, bytes memory data, bytes32 salt, uint256 delay) private {
        timelock.schedule(target, 0, data, 0, salt, delay);
        if (delay != 0) vm.warp(block.timestamp + delay);
        timelock.execute(target, 0, data, 0, salt);
    }
}
