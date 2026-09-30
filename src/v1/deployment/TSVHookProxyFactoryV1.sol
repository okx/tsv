// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @notice CREATE2 deployment for the V4 hook proxy permission address.
contract TSVHookProxyFactoryV1 {
    error InvalidImplementation();
    error InvalidHookAddress();

    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    event HookProxyDeployed(address indexed proxy, address indexed implementation, bytes32 indexed salt);

    function predict(address implementation, bytes calldata initData, bytes32 salt) public view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(TSVERC1967Proxy).creationCode, abi.encode(implementation, initData)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function deploy(address implementation, bytes calldata initData, bytes32 salt) external returns (address proxy) {
        if (implementation.code.length == 0 || initData.length == 0) revert InvalidImplementation();
        if ((uint160(predict(implementation, initData, salt)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookAddress();
        }
        proxy = address(new TSVERC1967Proxy{salt: salt}(implementation, initData));
        emit HookProxyDeployed(proxy, implementation, salt);
    }
}
