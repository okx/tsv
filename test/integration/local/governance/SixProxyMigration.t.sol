// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";

/// @dev Six compatible V2 migrations against funded positions and a real local V4 PoolManager.
contract TSVSixProxyMigrationLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        anchor.bindProxies(_addresses());
    }

    function testSixProxyMigrationPreservesBusinessStateAndTradingAndLiquidityStillWork() public {
        uint256 pauseId = _seedBusinessState();
        bytes32 beforeMigration = _businessStateDigest();
        _upgradeSix(false);
        assertEq(_businessStateDigest(), beforeMigration, "V2 migration changed existing business data");
        registry.clearEmergencyPause(pauseId, keccak256("resume"));
        _assertDirectLpLifecycle();
    }

    function testSixProxyMigrationPreservesPositionsForForcedExit() public {
        _seedPauseTestFees();
        bytes32 beforeMigration = _businessStateDigest();
        _upgradeSix(false);
        assertEq(_businessStateDigest(), beforeMigration);
        sbt.setHolder(alice, false);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(quote.balanceOf(alice), quoteBefore);
    }

    function testLastMigrationFailurePreservesFundedV4StateAndEntireBusinessSnapshot() public {
        _seedBusinessState();
        bytes32 beforeMigration = _businessStateDigest();
        address[6] memory targets = _addresses();
        address[6] memory old;
        for (uint256 i; i < 6; ++i) {
            old[i] = TSVERC1967Proxy(payable(targets[i])).tsvImplementation();
        }
        _upgradeSix(true);
        assertEq(_businessStateDigest(), beforeMigration);
        for (uint256 i; i < 6; ++i) {
            assertEq(TSVERC1967Proxy(payable(targets[i])).tsvImplementation(), old[i]);
        }
        assertFalse(anchor.upgradeContextActive());
    }

    function testFrozenRecoveryPreservesFundedPositionsAndBothUpgradeEntrypointsStayClosed() public {
        address oldGuardian = anchor.guardian();
        vm.prank(oldGuardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("governor-risk"));
        bytes32 beforeRecovery = _businessStateDigest();
        address nextGovernor = makeAddr("recovered-governor");
        address nextGuardian = makeAddr("recovered-guardian");
        vm.prank(anchor.recoveryCouncil());
        bytes32 id =
            anchor.proposeRecovery(nextGovernor, nextGuardian, keccak256("frozen-recovery"), keccak256("evidence"));
        vm.prank(oldGuardian);
        anchor.approveRecovery(id);
        vm.prank(makeAddr("executor"));
        anchor.executeRecovery(id);
        assertEq(_businessStateDigest(), beforeRecovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        address[] memory targets = new address[](1);
        targets[0] = address(registry);
        address[] memory implementations = new address[](1);
        implementations[0] = address(new TSVRegistryV1());
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.UpgradeFrozen.selector);
        anchor.upgradeBatch(targets, implementations, new bytes[](1));
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        registry.upgradeToAndCall(implementations[0], "");
        vm.prank(oldGuardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("resolved"));
        vm.prank(nextGuardian);
        anchor.unfreezeUpgrades(freeze, keccak256("resolved"));
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(implementations[0], "");
        _assertDirectLpLifecycle();
    }

    function testUpgradeFreezeAllowsReportsConfigurationPauseAndForcedExit() public {
        vm.prank(anchor.guardian());
        bytes32 freeze = anchor.freezeUpgrades(keccak256("upgrade-risk"));
        uint256 pauseId = _seedBusinessState();
        assertTrue(inbox.reportIdUsed(keccak256("migration-quota")));
        registry.setTierPolicy(2, 25, 2, keccak256("new-tier"));
        registry.clearEmergencyPause(pauseId, keccak256("resume"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }

    function _seedBusinessState() private returns (uint256 pauseId) {
        _seedPauseTestFees();
        uint64 now_ = uint64(block.timestamp);
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                DAY,
                1,
                1e22,
                now_ - 1,
                now_ + 100,
                1,
                1,
                keccak256("migration-quota"),
                keccak256("quota-source")
            )
        );
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        pauseId = registry.addEmergencyPause(
            PauseScope.POOL,
            PoolId.unwrap(key.toId()),
            PauseMode.ALL,
            keccak256("migration-pause"),
            keccak256("pause-source")
        );
    }

    function _businessStateDigest() private view returns (bytes32) {
        bytes32 registryState = keccak256(
            abi.encode(
                keccak256(abi.encode(registry.getSecurity(SECURITY), registry.tierPolicy(1))),
                keccak256(abi.encode(registry.getToken(address(stock)))),
                keccak256(abi.encode(registry.getToken(address(quote)))),
                keccak256(abi.encode(registry.getPool(PoolId.unwrap(key.toId())))),
                registry.nextPauseId(),
                _pauseStateDigest(),
                registry.marketPauseMode(SECURITY),
                registry.marketSequence(SECURITY),
                registry.activePoolCountByCurrency(address(stock)),
                registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), address(this))
            )
        );
        bytes32 reportsState = keccak256(
            abi.encode(
                ledger.adtvOf(SECURITY, 202609),
                ledger.quotaOf(SECURITY, DAY),
                ledger.dayStartCheckpointCount(),
                ledger.initialDayStartOffsetSeconds(),
                inbox.reportIdUsed(keccak256("adtv")),
                inbox.reportIdUsed(keccak256("migration-quota")),
                inbox.lastSequence(1, SECURITY),
                inbox.lastSequence(2, SECURITY),
                inbox.lastSourceTimestamp(1, SECURITY),
                inbox.lastSourceTimestamp(2, SECURITY)
            )
        );
        bytes32 links = keccak256(
            abi.encode(
                keccak256(abi.encode(registry.hook(), registry.lpManager(), registry.dataInbox())),
                keccak256(
                    abi.encode(ledger.registry(), ledger.hook(), ledger.dataInbox(), inbox.registry(), inbox.ledger())
                ),
                keccak256(
                    abi.encode(hook.poolManager(), hook.registry(), hook.ledger(), hook.router(), hook.lpManager())
                ),
                router.poolManager(),
                router.registry(),
                router.ledger(),
                lpManager.poolManager(),
                lpManager.registry(),
                registry.participantSbt(),
                registry.sbtTokenId()
            )
        );
        return keccak256(
            abi.encode(
                registryState,
                reportsState,
                links,
                _swapStateDigest(DAY),
                lpManager.nextPositionId(),
                lpManager.hasRole(lpManager.POOL_CREATOR_ROLE(), address(this)),
                inbox.hasRole(inbox.VOLUME_ORACLE_ROLE(), address(this))
            )
        );
    }

    function _addresses() private view returns (address[6] memory) {
        return [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lpManager)];
    }

    function _pauseStateDigest() private view returns (bytes32) {
        (bool ok, bytes memory result) =
            address(registry).staticcall(abi.encodeWithSignature("emergencyPauses(uint256)", 1));
        assertTrue(ok);
        return keccak256(result);
    }

    function _upgradeSix(bool failLast) private {
        address[6] memory proxies = _addresses();
        address[6] memory replacements = UpgradeDeployment.deployV2();
        address[] memory targets = new address[](6);
        address[] memory implementations = new address[](6);
        bytes[] memory calls = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            targets[i] = proxies[i];
            implementations[i] = replacements[i];
            calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, failLast && i == 5));
        }
        if (failLast) vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        anchor.upgradeBatch(targets, implementations, calls);
        if (!failLast) {
            for (uint256 i; i < 6; ++i) {
                assertEq(TSVERC1967Proxy(payable(proxies[i])).tsvImplementation(), replacements[i]);
                assertEq(GovernanceMigrationV2(proxies[i]).migrationMarker(), 42);
                assertEq(GovernanceMigrationV2(proxies[i]).migrationCaller(), address(anchor));
            }
        }
    }
}
