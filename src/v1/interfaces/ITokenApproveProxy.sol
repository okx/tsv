// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice TokenApproveProxy ABI used by OKX DexRouter's legacy transfer mode.
/// @dev Matches Web3-DEX-EVM contracts/8/interfaces/IApproveProxy.sol.
interface ITokenApproveProxy {
    function claimTokens(address token, address who, address dest, uint256 amount) external;
    function tokenApprove() external view returns (address);
    function isAllowedProxy(address proxy) external view returns (bool);
}
