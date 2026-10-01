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

contract V1GovernanceProxyLinksMock {
    address public immutable governanceAnchor;
    address public registry;
    address public ledger;
    address public dataInbox;
    address public hook;
    address public router;
    address public lpManager;
    address public poolManager;

    constructor(address anchor_) {
        governanceAnchor = anchor_;
    }

    function setLinks(
        address registry_,
        address ledger_,
        address dataInbox_,
        address hook_,
        address router_,
        address lpManager_,
        address poolManager_
    ) external {
        registry = registry_;
        ledger = ledger_;
        dataInbox = dataInbox_;
        hook = hook_;
        router = router_;
        lpManager = lpManager_;
        poolManager = poolManager_;
    }
}

contract V1FakeGovernanceAnchorMock {
    address public immutable timelock;
    bool public constant proxiesBound = true;
    mapping(uint256 => address) public proxies;

    constructor(address timelock_, address claimedProxy) {
        timelock = timelock_;
        proxies[0] = claimedProxy;
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
        _bindRegistryProxy(proxy);
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

    function testEmergencyUpgradeTargetMustBeOneOfTheSixBoundProxies() public {
        TSVRegistryV1 implementation = new TSVRegistryV1();
        TSVERC1967Proxy proxy = new TSVERC1967Proxy(
            address(implementation),
            abi.encodeCall(TSVRegistryV1.initialize, (address(anchor), address(timelock), address(controller)))
        );
        _bindRegistryProxy(proxy);

        TSVERC1967Proxy unboundProxy = new TSVERC1967Proxy(
            address(implementation),
            abi.encodeCall(TSVRegistryV1.initialize, (address(anchor), address(timelock), address(controller)))
        );
        bytes memory unboundTargetCall =
            abi.encodeCall(TSVEmergencyUpgradeController.setUpgradeTarget, (address(unboundProxy), true));
        bytes32 unboundTargetSalt = keccak256("unbound-target");
        timelock.schedule(address(controller), 0, unboundTargetCall, 0, unboundTargetSalt, 0);
        vm.expectRevert(TSVEmergencyUpgradeController.InvalidOperation.selector);
        timelock.execute(address(controller), 0, unboundTargetCall, 0, unboundTargetSalt);

        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TSVUpgradeTimelock candidateTimelock = new TSVUpgradeTimelock(
            address(this), makeAddr("candidate-guardian"), makeAddr("candidate-council"), executors
        );
        TSVBusinessAuthority candidateAuthority = new TSVBusinessAuthority(address(this), address(candidateTimelock));
        TSVEmergencyUpgradeController candidateController =
            new TSVEmergencyUpgradeController(address(this), candidateTimelock.guardian(), address(candidateTimelock));
        _executeOn(
            candidateTimelock,
            address(candidateTimelock),
            abi.encodeCall(TSVUpgradeTimelock.bindBusinessAuthority, (address(candidateAuthority))),
            keccak256("candidate-authority"),
            0
        );
        _executeOn(
            candidateTimelock,
            address(candidateTimelock),
            abi.encodeCall(TSVUpgradeTimelock.bindEmergencyController, (address(candidateController))),
            keccak256("candidate-controller"),
            0
        );
        V1FakeGovernanceAnchorMock fakeAnchor = new V1FakeGovernanceAnchorMock(address(timelock), address(unboundProxy));
        _executeOn(
            candidateTimelock,
            address(candidateTimelock),
            abi.encodeCall(TSVUpgradeTimelock.nominateGovernanceAnchor, (address(fakeAnchor))),
            keccak256("candidate-fake-anchor"),
            0
        );
        bytes memory fakeAnchorTargetCall =
            abi.encodeCall(TSVEmergencyUpgradeController.setUpgradeTarget, (address(unboundProxy), true));
        bytes32 fakeAnchorTargetSalt = keccak256("fake-anchor-target");
        candidateTimelock.schedule(address(candidateController), 0, fakeAnchorTargetCall, 0, fakeAnchorTargetSalt, 0);
        vm.expectRevert(TSVEmergencyUpgradeController.InvalidOperation.selector);
        candidateTimelock.execute(address(candidateController), 0, fakeAnchorTargetCall, 0, fakeAnchorTargetSalt);

        _execute(
            address(controller),
            abi.encodeCall(TSVEmergencyUpgradeController.setUpgradeTarget, (address(proxy), true)),
            keccak256("bound-target"),
            0
        );
        assertTrue(controller.upgradeTargetAllowed(address(proxy)));
        assertFalse(controller.upgradeTargetAllowed(address(unboundProxy)));
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
        _executeOn(timelock, target, data, salt, delay);
    }

    function _executeOn(
        TSVUpgradeTimelock targetTimelock,
        address target,
        bytes memory data,
        bytes32 salt,
        uint256 delay
    ) private {
        targetTimelock.schedule(target, 0, data, 0, salt, delay);
        if (delay != 0) vm.warp(block.timestamp + delay);
        targetTimelock.execute(target, 0, data, 0, salt);
    }

    function _bindRegistryProxy(TSVERC1967Proxy registryProxy) private {
        V1GovernanceProxyLinksMock ledger = new V1GovernanceProxyLinksMock(address(anchor));
        V1GovernanceProxyLinksMock inbox = new V1GovernanceProxyLinksMock(address(anchor));
        V1GovernanceProxyLinksMock hook = new V1GovernanceProxyLinksMock(address(anchor));
        V1GovernanceProxyLinksMock router = new V1GovernanceProxyLinksMock(address(anchor));
        V1GovernanceProxyLinksMock lpManager = new V1GovernanceProxyLinksMock(address(anchor));
        address poolManager = makeAddr("proxy-list-pool-manager");

        ledger.setLinks(
            address(registryProxy),
            address(ledger),
            address(inbox),
            address(hook),
            address(router),
            address(lpManager),
            poolManager
        );
        inbox.setLinks(
            address(registryProxy),
            address(ledger),
            address(inbox),
            address(hook),
            address(router),
            address(lpManager),
            poolManager
        );
        hook.setLinks(
            address(registryProxy),
            address(ledger),
            address(inbox),
            address(hook),
            address(router),
            address(lpManager),
            poolManager
        );
        router.setLinks(
            address(registryProxy),
            address(ledger),
            address(inbox),
            address(hook),
            address(router),
            address(lpManager),
            poolManager
        );
        lpManager.setLinks(
            address(registryProxy),
            address(ledger),
            address(inbox),
            address(hook),
            address(router),
            address(lpManager),
            poolManager
        );

        TSVRegistryV1(address(registryProxy)).bindComponents(address(hook), address(lpManager), address(inbox));
        address[6] memory proxies = [
            address(registryProxy), address(ledger), address(inbox), address(hook), address(router), address(lpManager)
        ];
        anchor.bindProxies(proxies);
    }
}
