// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {V1RegistryUpgradeMock} from "../../../helpers/v1/DirectUpgradeMock.sol";

/// @dev TSVFreezeTest scenarios; inherited fixtures contain no test functions.
contract TSVFreezeTest is GovernanceFixture {
    function testGuardianFreezeBlocksUpgradeBeforeProxyBindingAndUnfreezeRestoresIt() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        address oldImplementation = proxy.tsvImplementation();
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        vm.prank(guardian);
        bytes32 id = anchor.freezeUpgrades(keccak256("governor-compromised"));
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), id);
        assertEq(anchor.freezeEpoch(), 1);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, false)));
        assertEq(proxy.tsvImplementation(), oldImplementation);
        assertEq(registry.nextPauseId(), 1);
        assertFalse(anchor.proxiesBound());
        vm.prank(guardian);
        anchor.unfreezeUpgrades(id, keccak256("risk-resolved"));
        assertFalse(anchor.upgradesFrozen());
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (99, false)));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 99);
    }

    function testOnlyCurrentGuardianCanFreezeAndUnfreeze() public {
        address[3] memory callers = [address(this), council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.freezeUpgrades(keccak256("reason"));
        }
        vm.prank(guardian);
        bytes32 id = anchor.freezeUpgrades(keccak256("reason"));
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.unfreezeUpgrades(id, keccak256("evidence"));
            assertTrue(anchor.upgradesFrozen());
        }
    }

    function testFreezeTransitionsRequireEvidenceAndCurrentIncident() public {
        vm.startPrank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.freezeUpgrades(0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(0, keccak256("evidence"));
        bytes32 first = anchor.freezeUpgrades(keccak256("same-reason"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.freezeUpgrades(keccak256("other-reason"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(first, 0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(keccak256("wrong-id"), keccak256("evidence"));
        anchor.unfreezeUpgrades(first, keccak256("evidence"));
        bytes32 second = anchor.freezeUpgrades(keccak256("same-reason"));
        assertNotEq(first, second);
        assertEq(anchor.freezeEpoch(), 2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(first, keccak256("evidence"));
        assertTrue(anchor.upgradesFrozen());
        anchor.unfreezeUpgrades(second, keccak256("evidence"));
        vm.stopPrank();
    }
}
