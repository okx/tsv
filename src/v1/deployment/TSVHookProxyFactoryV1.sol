// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @notice CREATE2 deployment for the V4 hook proxy permission address.
/// @notice Predicts and deploys TSV Hook proxies whose CREATE2 address has the required V4 hook flags.
contract TSVHookProxyFactoryV1 {
    /// @dev Reverts when the supplied implementation address is invalid.
    error InvalidImplementation();
    /// @dev Reverts when the Hook proxy address does not contain the required V4 permission bits.
    error InvalidHookAddress();

    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    /// @notice Emitted when a Hook proxy was deployed at the supplied CREATE2 salt.
    event HookProxyDeployed(address indexed proxy, address indexed implementation, bytes32 indexed salt);

    /// @notice Computes the CREATE2 address for the proxy deployment parameters.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization calldata embedded in the proxy constructor.
    /// @param salt CREATE2 salt used for deployment.
    /// @return Address that `deploy` will create for these parameters.
    function predict(address implementation, bytes calldata initData, bytes32 salt) public view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(TSVERC1967Proxy).creationCode, abi.encode(implementation, initData)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Deploys the Hook proxy only when its predicted address has all required permission bits.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization calldata embedded in the proxy constructor.
    /// @param salt CREATE2 salt used for deployment.
    /// @return proxy Address of the newly deployed proxy.
    function deploy(address implementation, bytes calldata initData, bytes32 salt) external returns (address proxy) {
        if (implementation.code.length == 0 || initData.length == 0) revert InvalidImplementation();
        if ((uint160(predict(implementation, initData, salt)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookAddress();
        }
        proxy = address(new TSVERC1967Proxy{salt: salt}(implementation, initData));
        emit HookProxyDeployed(proxy, implementation, salt);
    }
}
