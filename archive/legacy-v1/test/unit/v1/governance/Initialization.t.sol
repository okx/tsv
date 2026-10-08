// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev TSVGovernanceInitializationTest scenarios; inherited fixtures contain no test functions.
contract TSVGovernanceInitializationTest is GovernanceFixture {
    function testGovernanceIdentitiesAreStoredDirectlyInAnchor() public view {
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.recoveryCouncil(), council);
        assertFalse(anchor.upgradesFrozen());
        assertEq(anchor.freezeEpoch(), 0);
    }

    function testProxyInitializationRejectsMissingOrConflictingAnchorGovernor() public {
        address[3] memory governors = [address(0), guardian, council];
        for (uint256 i; i < governors.length; ++i) {
            vm.mockCall(address(anchor), abi.encodeWithSignature("governor()"), abi.encode(governors[i]));
            // Deploy the implementation before setting the expected proxy initialization revert.
            TSVRegistryV1 implementation = new TSVRegistryV1();
            vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
            new TSVERC1967Proxy(address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor))));
            vm.clearMockedCalls();
        }
    }

    function testAnchorConstructorRejectsEveryZeroIdentity() public {
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(0), guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), address(0), council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), guardian, address(0));
    }

    function testAnchorConstructorRejectsEveryPairOfOverlappingIdentities() public {
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(guardian, guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(council, guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), council, council);
    }

    function testProxyInitializationRejectsAnchorWithoutCode() public {
        TSVRegistryV1 implementation = new TSVRegistryV1();
        vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
        new TSVERC1967Proxy(
            address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (makeAddr("missing-anchor")))
        );
    }

    function testProxyInitializationRejectsInvalidGuardianAndCouncil() public {
        bytes4[2] memory getters = [bytes4(keccak256("guardian()")), bytes4(keccak256("recoveryCouncil()"))];
        address[3] memory invalid = [address(0), address(this), council];
        TSVRegistryV1 implementation = new TSVRegistryV1();
        for (uint256 field; field < getters.length; ++field) {
            for (uint256 i; i < invalid.length; ++i) {
                address value = field == 1 && i == 2 ? guardian : invalid[i];
                vm.mockCall(address(anchor), abi.encodeWithSelector(getters[field]), abi.encode(value));
                vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
                new TSVERC1967Proxy(
                    address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                );
                vm.clearMockedCalls();
            }
        }
    }
}
