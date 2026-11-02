// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITSVHookFactoryForBootstrap {
    function predict(address implementation, bytes calldata initData, bytes32 salt) external view returns (address);
    function deploy(address implementation, bytes calldata initData, bytes32 salt) external returns (address);
}

/// @notice Constructor-only orchestration for MCP systems that support EOA CREATE only.
/// @dev No admin, execution, upgrade, or asset-transfer methods. Never bound into TSV business configuration.
contract TSVHookProxyMcpBootstrap {
    error InvalidDeploymentInputs();
    error UnexpectedHookProxy();

    address public immutable factory;
    address public immutable hookProxy;

    constructor(address factory_, address implementation, bytes memory initData, bytes32 salt, address expectedProxy) {
        if (factory_.code.length == 0 || implementation.code.length == 0 || initData.length == 0
            || expectedProxy.code.length != 0 || uint160(expectedProxy) & 0x3FFF != 0x3FFF) {
            revert InvalidDeploymentInputs();
        }
        ITSVHookFactoryForBootstrap target = ITSVHookFactoryForBootstrap(factory_);
        if (target.predict(implementation, initData, salt) != expectedProxy) revert UnexpectedHookProxy();
        address deployed = target.deploy(implementation, initData, salt);
        if (deployed != expectedProxy || deployed.code.length == 0) revert UnexpectedHookProxy();
        factory = factory_;
        hookProxy = deployed;
    }
}
