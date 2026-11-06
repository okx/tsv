// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @dev Credential fixture distinguishes IDs; fault injection is confined to its view selectors.
contract OperationsSbt {
    mapping(address => mapping(uint256 => bool)) private credentials;
    bool public paused;
    bool public failVerify;

    function setCredential(address owner, uint256 tokenId, bool held) external {
        credentials[owner][tokenId] = held;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setFailVerify(bool value) external {
        failVerify = value;
    }

    function verify(address owner, uint256 tokenId) external view returns (bool) {
        require(!failVerify, "verify unavailable");
        return credentials[owner][tokenId];
    }
}

contract OperationsPausedOnlySbt {
    function paused() external pure returns (bool) {
        return false;
    }
}

contract OperationsVerifyOnlySbt {
    function verify(address, uint256) external pure returns (bool) {
        return true;
    }
}
