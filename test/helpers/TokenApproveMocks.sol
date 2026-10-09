// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenApproveProxy} from "tsv-v1/interfaces/ITokenApproveProxy.sol";

/// @dev Test stand-ins preserve the two authorization gates of DexRouter's approval chain.
contract TestTokenApprove {
    address public immutable proxy;

    constructor() {
        proxy = msg.sender;
    }

    function claimTokens(address token, address who, address dest, uint256 amount) external {
        require(msg.sender == proxy, "TokenApprove: Access restricted");
        if (amount > 0) SafeERC20.safeTransferFrom(IERC20(token), who, dest, amount);
    }
}

contract TestTokenApproveProxy is ITokenApproveProxy {
    address public immutable tokenApprove;
    mapping(address => bool) public isAllowedProxy;

    constructor() {
        tokenApprove = address(new TestTokenApprove());
    }

    function setAllowed(address proxy, bool allowed) external {
        isAllowedProxy[proxy] = allowed;
    }

    function claimTokens(address token, address who, address dest, uint256 amount) external {
        require(isAllowedProxy[msg.sender], "ApproveProxy: Access restricted");
        TestTokenApprove(tokenApprove).claimTokens(token, who, dest, amount);
    }
}
