// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Exact ERC-20 settlement helpers for TSV's direct-currency paths.
library TSVDirectSettlementLib {
    using SafeERC20 for IERC20;

    error SettlementMismatch();

    function settleFrom(IPoolManager poolManager, Currency currency, address token, address payer, uint256 amount)
        internal
    {
        poolManager.sync(currency);
        uint256 payerBefore = IERC20(token).balanceOf(payer);
        uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
        IERC20(token).safeTransferFrom(payer, address(poolManager), amount);
        uint256 payerAfter = IERC20(token).balanceOf(payer);
        uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
        if (
            payerAfter > payerBefore || payerBefore - payerAfter != amount || poolAfter < poolBefore
                || poolAfter - poolBefore != amount || poolManager.settle() != amount
        ) revert SettlementMismatch();
    }

    function takeTo(IPoolManager poolManager, Currency currency, address token, address recipient, uint256 amount)
        internal
    {
        uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        poolManager.take(currency, recipient, amount);
        uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
        uint256 recipientAfter = IERC20(token).balanceOf(recipient);
        if (
            poolAfter > poolBefore || poolBefore - poolAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert SettlementMismatch();
    }
}
