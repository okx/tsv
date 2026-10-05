// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {GovernanceHandler} from "../../../helpers/v1/GovernanceHandler.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";

/// @dev Random interleavings of recovery, freezes and upgrades must agree with the independent model.
contract TSVStatefulGovernanceTest is SixProxyFixture {
    GovernanceHandler internal handler;

    function setUp() public override {
        super.setUp();
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        address[6] memory originals;
        for (uint256 i; i < 6; ++i) {
            originals[i] = _implementation(businessProxies[i]);
        }
        handler = new GovernanceHandler(anchor, businessProxies, originals, UpgradeDeployment.deployV2());
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = GovernanceHandler.propose.selector;
        selectors[1] = GovernanceHandler.approve.selector;
        selectors[2] = GovernanceHandler.revoke.selector;
        selectors[3] = GovernanceHandler.cancel.selector;
        selectors[4] = GovernanceHandler.recover.selector;
        selectors[5] = GovernanceHandler.freeze.selector;
        selectors[6] = GovernanceHandler.unfreeze.selector;
        selectors[7] = GovernanceHandler.upgradeSingle.selector;
        selectors[8] = GovernanceHandler.upgradeBatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantIdentitiesAndEpochsMatchApprovedRecoveries() public view {
        assertEq(anchor.governor(), handler.modelGovernor());
        assertEq(anchor.guardian(), handler.modelGuardian());
        assertEq(anchor.recoveryCouncil(), council);
        assertEq(anchor.epoch(), handler.modelEpoch());
        assertEq(anchor.guardianEpoch(), handler.modelGuardianEpoch());
    }

    function invariantFreezeOnlyChangesThroughCurrentGuardianTransitions() public view {
        assertEq(anchor.upgradesFrozen(), handler.modelFrozen());
        assertEq(anchor.freezeId(), handler.modelFreezeId());
        assertEq(anchor.freezeEpoch(), handler.modelFreezeEpoch());
    }

    function invariantImplementationsOnlyChangeThroughAuthorizedUnfrozenUpgrades() public view {
        for (uint256 i; i < 6; ++i) {
            assertEq(_implementation(businessProxies[i]), handler.expectedImplementations(i));
        }
        assertFalse(anchor.upgradeContextActive());
    }

    function invariantBindingsAndBusinessRolesSurviveAllGovernanceSequences() public view {
        assertTrue(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), businessProxies[i]);
            assertEq(address(TSVGoverned(businessProxies[i]).governanceAnchor()), address(anchor));
            assertTrue(TSVGoverned(businessProxies[i]).hasRole(bytes32(0), handler.modelGovernor()));
            assertFalse(TSVGoverned(businessProxies[i]).hasRole(bytes32(0), council));
        }
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
    }

    /// @dev Guarantees the model exercises successful recovery, stale approval rejection and freeze paths.
    function testModelTraversesRecoveryAndRejectsStaleApprovalWhileFrozen() public {
        handler.propose(2, false);
        handler.propose(2, true);
        handler.approve(1, 0);
        handler.approve(1, 1);
        handler.freeze(1);
        handler.recover(3, 0);
        handler.recover(3, 1);
        handler.upgradeSingle(0, 0);
        handler.upgradeBatch(0, 5);
        assertEq(handler.successfulRecoveries(), 1);
        assertEq(handler.successfulUpgrades(), 0);
        handler.unfreeze(0, false);
        handler.unfreeze(1, true);
        handler.unfreeze(1, false);
        handler.upgradeBatch(0, 5);
        assertEq(handler.successfulUpgrades(), 6);
        invariantIdentitiesAndEpochsMatchApprovedRecoveries();
        invariantFreezeOnlyChangesThroughCurrentGuardianTransitions();
        invariantImplementationsOnlyChangeThroughAuthorizedUnfrozenUpgrades();
        invariantBindingsAndBusinessRolesSurviveAllGovernanceSequences();
    }
}
