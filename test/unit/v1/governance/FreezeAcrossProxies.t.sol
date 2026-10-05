// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

contract TSVFreezeAcrossProxiesTest is SixProxyFixture {
    function testGuardianFreezeCoversAllSixProxiesAndBatch() public {
        address[] memory targets = new address[](6);
        address[] memory implementations = new address[](6);
        bytes[] memory initData = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            targets[i] = businessProxies[i];
            implementations[i] = TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation();
        }
        vm.prank(anchor.guardian());
        bytes32 id = anchor.freezeUpgrades();
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
            TSVGoverned(businessProxies[i]).upgradeToAndCall(implementations[i], "");
            assertEq(TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation(), implementations[i]);
        }
        vm.expectRevert(TSVGovernanceAnchor.UpgradeFrozen.selector);
        anchor.upgradeBatch(targets, implementations, initData);
        assertFalse(anchor.upgradeContextActive());
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(id);
        vm.prank(anchor.guardian());
        anchor.unfreezeUpgrades(id);
        // Reopening the global switch restores the complete six-proxy batch entry point.
        anchor.upgradeBatch(targets, implementations, initData);
        assertFalse(anchor.upgradesFrozen());
    }
}
