// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";

contract TSVRouterInitializationTest is GovernanceFixture {
    function testRouterRejectsEveryDependencyWithoutCode() public {
        address factory = address(new PermissionsAdapterFactory(address(this)));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        new TSVSwapRouterV1(address(0), factory);
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        new TSVSwapRouterV1(address(this), address(0));
        address implementation = address(new TSVSwapRouterV1(address(this), factory));
        for (uint256 i; i < 2; i++) {
            address[2] memory dependencies_ = [address(this), address(this)];
            dependencies_[i] = address(0);
            bytes memory initialization =
                abi.encodeCall(TSVSwapRouterV1.initialize, (dependencies_[0], dependencies_[1]));
            vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
            new TSVERC1967Proxy(implementation, initialization);
        }
    }
}
