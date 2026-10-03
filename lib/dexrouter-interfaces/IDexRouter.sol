// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @dev Thin ABI from okxlabs/Web3-DEX-Router-EVM-V1, commit 1fc1508df3caeb18a8179dfc0ea4e956099ab481.
///      Only the DAG ERC20 routes exercised against the pinned X Layer deployment are included.
interface IDexRouter {
    struct BaseRequest {
        uint256 fromToken;
        address toToken;
        uint256 fromTokenAmount;
        uint256 minReturnAmount;
        uint256 deadLine;
    }

    struct RouterPath {
        address[] mixAdapters;
        address[] assetTo;
        uint256[] rawData;
        bytes[] extraData;
        uint256 fromToken;
    }

    function dagSwapByOrderId(uint256 orderId, BaseRequest calldata baseRequest, RouterPath[] calldata paths)
        external
        payable
        returns (uint256 returnAmount);
    function dagSwapTo(uint256 orderId, address receiver, BaseRequest calldata baseRequest, RouterPath[] calldata paths)
        external
        payable
        returns (uint256 returnAmount);
    function version() external view returns (string memory);
}

interface IDexApproveProxy {
    function tokenApprove() external view returns (address);
    function isAllowedProxy(address proxy) external view returns (bool);
}
