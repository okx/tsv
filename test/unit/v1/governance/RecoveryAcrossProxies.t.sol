// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

contract TSVRecoveryAcrossProxiesTest is SixProxyFixture {
    function testGovernorRecoveryUpdatesAllSixProxiesAndPreservesBusinessRoles() public {
        address guardian = anchor.guardian();
        address council = anchor.recoveryCouncil();
        address nextGovernor = makeAddr("next-governor");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("governor-recovery-risk"));
        vm.prank(council);
        bytes32 id =
            anchor.proposeRecovery(nextGovernor, guardian, keccak256("recovery-salt"), keccak256("recovery-evidence"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), nextGovernor);
        assertEq(anchor.epoch(), 1);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        assertEq(anchor.freezeEpoch(), 1);
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
        for (uint256 i; i < 6; ++i) {
            TSVGoverned proxy = TSVGoverned(businessProxies[i]);
            address implementation = TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation();
            assertEq(address(proxy.governanceAnchor()), address(anchor));
            assertFalse(proxy.hasRole(0, address(this)));
            assertTrue(proxy.hasRole(0, nextGovernor));
            vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
            proxy.upgradeToAndCall(implementation, "");
            vm.prank(nextGovernor);
            vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
            proxy.upgradeToAndCall(implementation, "");
        }
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(guardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        TSVRegistryV1 newImplementation = new TSVRegistryV1();
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(address(newImplementation), "");
        assertEq(TSVERC1967Proxy(payable(address(registry))).tsvImplementation(), address(newImplementation));
    }
}
