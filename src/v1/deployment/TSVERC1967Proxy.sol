// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @notice Stable selector for implementation inspection even when logic is broken.
contract TSVERC1967Proxy is ERC1967Proxy {
    /// @dev Reverts when proxy initialization data must not be empty.
    error EmptyInitializationData();

    /// @notice Deploys an ERC-1967 proxy and requires nonempty initialization calldata.
    /// @param implementation Initial logic contract.
    /// @param data Initialization call encoded for the implementation.
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {
        if (data.length == 0) revert EmptyInitializationData();
    }

    /// @notice Returns the implementation address stored in the ERC-1967 slot.
    /// @return Current proxy logic address.
    function tsvImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
