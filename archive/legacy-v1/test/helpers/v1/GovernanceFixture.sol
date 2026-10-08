// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev GovernanceFixture scenarios; inherited fixtures contain no test functions.
abstract contract GovernanceFixture is Test {
    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;

    function setUp() public virtual {
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        anchor = new TSVGovernanceAnchor(address(this), guardian, council);
    }

    function _proposeRecovery(address governor_, address guardian_, string memory salt) internal returns (bytes32) {
        vm.prank(council);
        return anchor.proposeRecovery(governor_, guardian_, keccak256(bytes(salt)));
    }

    function _newRegistryProxy() internal returns (TSVERC1967Proxy) {
        return
            new TSVERC1967Proxy(
                address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
            );
    }
}
