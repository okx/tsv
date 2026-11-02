// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev GovernanceFixture scenarios; inherited fixtures contain no test functions.
abstract contract GovernanceFixture is Test {
    address internal guardian;
    address internal council;

    function setUp() public virtual {
        guardian = makeAddr("guardian");
        council = makeAddr("council");
    }

    function _newRegistryProxy() internal returns (TSVERC1967Proxy) {
        return
            new TSVERC1967Proxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this))));
    }
}
