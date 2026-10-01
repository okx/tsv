// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

contract TSVHookFactoryTest is Test {
    struct Base {
        TSVBusinessAuthority authority;
        TSVUpgradeTimelock timelock;
        TSVEmergencyUpgradeController controller;
        TSVGovernanceAnchor anchor;
        TSVRegistryV1 registry;
        TSVVolumeLedgerV1 ledger;
        TSVDataInboxV1 inbox;
        address routerImpl;
        address lpImpl;
        address hookImpl;
        TSVHookProxyFactoryV1 factory;
        TSVSwapRouterV1 router;
        TSVLPManagerV1 lp;
        TSVHookV1 hook;
    }

    function testProxyRejectsEmptyInitializationData() public {
        TSVHookV1 implementation = new TSVHookV1();

        vm.expectRevert(TSVERC1967Proxy.EmptyInitializationData.selector);
        new TSVERC1967Proxy(address(implementation), "");
    }

    function testMinedProxyHasV4PermissionsAndStableImplementationGetter() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        Base memory d = _makeGovernance();
        vm.etch(address(0xBEEF), hex"00");
        vm.etch(address(0xF00D), hex"00");
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(d.anchor),
                address(d.timelock),
                address(d.controller),
                address(this),
                address(this),
                address(this),
                address(0xBEEF),
                address(0xF00D)
            )
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(address(implementation), initData, salt);
            if ((uint160(predicted) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predicted) & 0x3FFF, 0x3FFF);
        address proxy = factory.deploy(address(implementation), initData, salt);
        assertEq(proxy, predicted);
        assertEq(TSVERC1967Proxy(payable(proxy)).tsvImplementation(), address(implementation));
        assertEq(address(TSVHookV1(proxy).businessAuthority()), address(d.authority));
        vm.expectRevert();
        factory.deploy(address(implementation), initData, salt);
    }

    function testWrongPermissionSaltReverts() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (address(1), address(2), address(3), address(4), address(5), address(6), address(7), address(8))
        );
        bytes32 salt;
        while ((uint160(factory.predict(address(implementation), initData, salt)) & 0x3FFF) == 0x3FFF) {
            salt = bytes32(uint256(salt) + 1);
        }
        vm.expectRevert(TSVHookProxyFactoryV1.InvalidHookAddress.selector);
        factory.deploy(address(implementation), initData, salt);
    }

    function testSixProxyDeploymentUsesActualPredictedAddresses() public {
        vm.warp(1_800_000_000);
        Base memory d = _deployBase();
        uint64 nextNonce = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), nextNonce);
        address predictedLp = vm.computeCreateAddress(address(this), uint256(nextNonce) + 1);
        bytes memory hookInit = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(d.anchor),
                address(d.timelock),
                address(d.controller),
                address(this),
                address(d.registry),
                address(d.ledger),
                predictedRouter,
                predictedLp
            )
        );
        bytes32 salt;
        address predictedHook;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predictedHook = d.factory.predict(d.hookImpl, hookInit, salt);
            if ((uint160(predictedHook) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predictedHook) & 0x3FFF, 0x3FFF);

        TSVSwapRouterV1 router = _deployRouter(d);
        TSVLPManagerV1 lp = _deployLp(d);
        TSVHookV1 hook = TSVHookV1(d.factory.deploy(d.hookImpl, hookInit, salt));

        assertEq(address(router), predictedRouter);
        assertEq(address(lp), predictedLp);
        assertEq(address(hook), predictedHook);
        assertEq(hook.router(), address(router));
        assertEq(hook.lpManager(), address(lp));
        d.registry.bindComponents(address(hook), address(lp), address(d.inbox));
        d.ledger.bindWriters(address(hook), address(d.inbox));
        assertEq(d.registry.hook(), address(hook));
        assertEq(d.ledger.hook(), address(hook));
        address[6] memory addresses =
            [address(d.registry), address(d.ledger), address(d.inbox), address(hook), address(router), address(lp)];
        address[6] memory wrongAddresses;
        for (uint256 i; i < 6; ++i) {
            wrongAddresses[i] = addresses[i];
        }
        wrongAddresses[5] = address(router);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        d.anchor.bindProxies(wrongAddresses);
        d.anchor.bindProxies(addresses);
        assertTrue(d.anchor.proxiesBound());
        d.router = router;
        d.lp = lp;
        d.hook = hook;
        _testRootMigration(d, addresses);
    }

    function _deployBase() private returns (Base memory d) {
        d = _makeGovernance();
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()),
                    abi.encodeCall(
                        TSVRegistryV1.initialize, (address(d.anchor), address(d.timelock), address(d.controller))
                    )
                )
            )
        );
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize,
                        (address(d.anchor), address(d.timelock), address(d.controller), address(d.registry), uint32(0))
                    )
                )
            )
        );
        d.inbox = TSVDataInboxV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(
                        TSVDataInboxV1.initialize,
                        (
                            address(d.anchor),
                            address(d.timelock),
                            address(d.controller),
                            address(d.registry),
                            address(d.ledger)
                        )
                    )
                )
            )
        );
        d.routerImpl = address(new TSVSwapRouterV1());
        d.lpImpl = address(new TSVLPManagerV1());
        d.hookImpl = address(new TSVHookV1());
        d.factory = new TSVHookProxyFactoryV1();
    }

    function _deployRouter(Base memory d) private returns (TSVSwapRouterV1) {
        return TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    d.routerImpl,
                    abi.encodeCall(
                        TSVSwapRouterV1.initialize,
                        (
                            address(d.anchor),
                            address(d.timelock),
                            address(d.controller),
                            address(this),
                            address(d.registry),
                            address(d.ledger)
                        )
                    )
                )
            )
        );
    }

    function _deployLp(Base memory d) private returns (TSVLPManagerV1) {
        return TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.lpImpl,
                    abi.encodeCall(
                        TSVLPManagerV1.initialize,
                        (
                            address(d.anchor),
                            address(d.timelock),
                            address(d.controller),
                            address(this),
                            address(d.registry)
                        )
                    )
                )
            )
        );
    }

    function _makeGovernance() private returns (Base memory d) {
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        address guardian = makeAddr("guardian");
        d.timelock = new TSVUpgradeTimelock(address(this), guardian, makeAddr("council"), executors);
        d.authority = new TSVBusinessAuthority(address(this), address(d.timelock));
        d.controller = new TSVEmergencyUpgradeController(address(this), guardian, address(d.timelock));
        d.anchor = new TSVGovernanceAnchor(address(d.timelock), address(d.authority), address(d.controller));
    }

    function _testRootMigration(Base memory d, address[6] memory addresses) private {
        _executeCandidate(
            d.timelock,
            address(d.timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindBusinessAuthority, (address(d.authority))),
            keccak256("old-authority")
        );
        _executeCandidate(
            d.timelock,
            address(d.timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindEmergencyController, (address(d.controller))),
            keccak256("old-controller")
        );
        _executeCandidate(
            d.timelock,
            address(d.timelock),
            abi.encodeCall(TSVUpgradeTimelock.bindGovernanceAnchor, (address(d.anchor))),
            keccak256("old-anchor")
        );
        address guardian = d.timelock.guardian();
        address council = d.timelock.recoveryCouncil();
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TSVUpgradeTimelock nextTimelock = new TSVUpgradeTimelock(address(this), guardian, council, executors);
        TSVBusinessAuthority nextAuthority = new TSVBusinessAuthority(address(this), address(nextTimelock));
        TSVEmergencyUpgradeController nextController =
            new TSVEmergencyUpgradeController(address(this), guardian, address(nextTimelock));
        _executeCandidate(
            nextTimelock,
            address(nextTimelock),
            abi.encodeCall(TSVUpgradeTimelock.bindBusinessAuthority, (address(nextAuthority))),
            keccak256("authority")
        );
        _executeCandidate(
            nextTimelock,
            address(nextTimelock),
            abi.encodeCall(TSVUpgradeTimelock.bindEmergencyController, (address(nextController))),
            keccak256("controller")
        );
        _executeCandidate(
            nextTimelock,
            address(nextTimelock),
            abi.encodeCall(TSVUpgradeTimelock.nominateGovernanceAnchor, (address(d.anchor))),
            keccak256("anchor")
        );
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        d.anchor
            .proposeRoot(
                address(nextTimelock),
                address(nextAuthority),
                address(nextController),
                keccak256("migration-salt"),
                keccak256("migration-evidence")
            );
        for (uint256 i; i < 6; ++i) {
            _executeCandidate(
                nextTimelock,
                address(nextController),
                abi.encodeCall(TSVEmergencyUpgradeController.setUpgradeTarget, (addresses[i], true)),
                keccak256(abi.encode("target", i))
            );
        }
        vm.prank(council);
        bytes32 id = d.anchor
            .proposeRoot(
                address(nextTimelock),
                address(nextAuthority),
                address(nextController),
                keccak256("migration-salt"),
                keccak256("migration-evidence")
            );
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        d.anchor.executeRoot(id);
        vm.prank(guardian);
        d.anchor.approveRoot(id);
        vm.prank(guardian);
        d.anchor.revokeRootApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        d.anchor.executeRoot(id);
        vm.prank(guardian);
        d.anchor.approveRoot(id);
        _assertGuardianRotationInvalidatesProposal(d, id, council, guardian);
        d.anchor.executeRoot(id);
        assertEq(address(d.anchor.timelock()), address(nextTimelock));
        assertEq(address(nextTimelock.governanceAnchor()), address(d.anchor));
        assertEq(d.registry.upgradeTimelock(), address(nextTimelock));
        assertEq(d.router.upgradeTimelock(), address(nextTimelock));
        assertEq(d.lp.upgradeTimelock(), address(nextTimelock));
        assertEq(d.anchor.epoch(), 1);
        TSVRegistryV1 newImplementation = new TSVRegistryV1();
        vm.prank(address(d.timelock));
        vm.expectRevert();
        d.registry.upgradeToAndCall(address(newImplementation), "");
        _executeCandidate(
            nextTimelock,
            address(d.registry),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImplementation), bytes("")),
            keccak256("new-root-upgrade")
        );
        assertEq(TSVERC1967Proxy(payable(address(d.registry))).tsvImplementation(), address(newImplementation));
    }

    function _assertGuardianRotationInvalidatesProposal(
        Base memory d,
        bytes32 proposalId,
        address council,
        address guardian
    ) private {
        uint256 checkpoint = vm.snapshotState();
        bytes memory payload = abi.encodeCall(
            TSVUpgradeTimelock.recoverAuthorities,
            (address(this), makeAddr("rotated-guardian"), keccak256("rotation-evidence"))
        );
        bytes32 salt = keccak256("rotation-salt");
        vm.prank(council);
        d.timelock.schedule(address(d.timelock), 0, payload, 0, salt, 0);
        bytes32 operationId = d.timelock.hashOperation(address(d.timelock), 0, payload, 0, salt);
        vm.prank(guardian);
        d.timelock.approveRecovery(operationId);
        d.timelock.execute(address(d.timelock), 0, payload, 0, salt);
        assertEq(d.anchor.guardianEpoch(), 1);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        d.anchor.executeRoot(proposalId);
        assertTrue(vm.revertToState(checkpoint));
    }

    function _executeCandidate(TSVUpgradeTimelock tl, address target, bytes memory payload, bytes32 salt) private {
        tl.schedule(target, 0, payload, 0, salt, 0);
        tl.execute(target, 0, payload, 0, salt);
    }
}
