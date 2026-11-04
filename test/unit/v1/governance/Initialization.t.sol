// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract TSVGovernanceInitializationTest is GovernanceFixture {
    function testInitialAdminReceivesAdminAndUpgradeRoles() public {
        TSVRegistryV1 registry = TSVRegistryV1(address(_newRegistryProxy()));
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(registry.hasRole(registry.UPGRADE_ADMIN_ROLE(), address(this)));
        assertFalse(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), address(this)));
    }

    function testZeroAdminRejected() public {
        TSVRegistryV1 implementation = new TSVRegistryV1();
        vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
        new TSVERC1967Proxy(address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (address(0))));
    }

    function testAdminMayBeAnEOA() public {
        address admin = makeAddr("admin");
        TSVRegistryV1 registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (admin)))
            )
        );
        assertTrue(registry.hasRole(bytes32(0), admin));
        assertTrue(registry.hasRole(registry.UPGRADE_ADMIN_ROLE(), admin));
        assertFalse(registry.hasRole(bytes32(0), address(this)));
    }

    function testImplementationAndProxyCannotBeReinitialized() public {
        TSVRegistryV1 implementation = new TSVRegistryV1();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(this));
        TSVRegistryV1 registry = TSVRegistryV1(address(_newRegistryProxy()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(makeAddr("other"));
    }
}
