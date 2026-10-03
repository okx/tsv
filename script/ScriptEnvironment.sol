// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

/// @dev Environment readers can be overridden with isolated inputs in script tests.
abstract contract ScriptEnvironment is Script {
    function _envAddress(string memory name) internal view virtual returns (address) {
        return vm.envAddress(name);
    }

    function _envBytes32(string memory name) internal view virtual returns (bytes32) {
        return vm.envBytes32(name);
    }

    function _envUint(string memory name) internal view virtual returns (uint256) {
        return vm.envUint(name);
    }
}
