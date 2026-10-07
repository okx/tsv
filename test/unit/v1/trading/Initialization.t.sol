// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

contract TSVRouterInitializationTest is GovernanceFixture {
    function testRouterRejectsEveryDependencyWithoutCode() public {
        for (uint256 i; i < 3; i++) {
            address[3] memory dependencies_ = [address(this), address(this), address(this)];
            dependencies_[i] = address(0);
            address implementation = address(new TSVSwapRouterV1(dependencies_[0], dependencies_[1]));
            bytes memory initialization = abi.encodeCall(
                TSVSwapRouterV1.initialize, (address(anchor), dependencies_[0], dependencies_[1], dependencies_[2])
            );
            vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
            new TSVERC1967Proxy(implementation, initialization);
        }
    }
}
