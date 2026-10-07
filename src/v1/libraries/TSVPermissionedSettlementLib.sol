// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Internal-only exact transfer and inventory checks. Never syncs or settles PoolManager debt.
library TSVPermissionedSettlementLib {
    using SafeERC20 for IERC20;

    error SettlementMismatch();

    struct StockInventory {
        uint256 collateral;
        uint256 supply;
        uint256 pmBalance;
        uint256 pmUnderlyingBalance;
        uint256 routerUnderlyingBalance;
    }

    function stockInventory(address w, address u, address pm, address participant)
        internal
        view
        returns (StockInventory memory s)
    {
        s.collateral = IERC20(u).balanceOf(w);
        s.supply = IERC20(w).totalSupply();
        s.pmBalance = IERC20(w).balanceOf(pm);
        s.pmUnderlyingBalance = IERC20(u).balanceOf(pm);
        s.routerUnderlyingBalance = IERC20(u).balanceOf(address(this));
        if (
            s.collateral < s.supply || s.pmBalance != s.supply || IERC20(w).balanceOf(address(this)) != 0
                || IERC20(w).balanceOf(participant) != 0
        ) revert SettlementMismatch();
    }

    /// @dev Unsolicited U and balances owned by other PM pools cannot fund this operation.
    function assertUnderlyingUnchanged(StockInventory memory before_, StockInventory memory after_) internal pure {
        if (
            before_.pmUnderlyingBalance != after_.pmUnderlyingBalance
                || before_.routerUnderlyingBalance != after_.routerUnderlyingBalance
        ) revert SettlementMismatch();
    }

    function transferExact(address token, address payer, address recipient, uint256 amount) internal {
        uint256 payerBefore = IERC20(token).balanceOf(payer);
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransferFrom(payer, recipient, amount);
        assertDecrease(payerBefore, IERC20(token).balanceOf(payer), amount);
        assertIncrease(recipientBefore, IERC20(token).balanceOf(recipient), amount);
    }

    function payStock(address w, address u, address pm, address payer, uint256 amount) internal {
        StockInventory memory before_ = stockInventory(w, u, pm, payer);
        transferExact(u, payer, w, amount);
        IPermissionsAdapter(w).wrapToPoolManager(amount);
        StockInventory memory after_ = stockInventory(w, u, pm, payer);
        assertUnderlyingUnchanged(before_, after_);
        assertIncrease(before_.collateral, after_.collateral, amount);
        assertIncrease(before_.supply, after_.supply, amount);
        assertIncrease(before_.pmBalance, after_.pmBalance, amount);
        if (before_.collateral - before_.supply != after_.collateral - after_.supply) revert SettlementMismatch();
    }

    function assertStockTake(
        StockInventory memory before_,
        uint256 recipientBefore,
        address w,
        address u,
        address pm,
        address recipient,
        uint256 amount
    ) internal view {
        StockInventory memory after_ = stockInventory(w, u, pm, recipient);
        assertUnderlyingUnchanged(before_, after_);
        assertDecrease(before_.collateral, after_.collateral, amount);
        assertDecrease(before_.supply, after_.supply, amount);
        assertDecrease(before_.pmBalance, after_.pmBalance, amount);
        assertIncrease(recipientBefore, IERC20(u).balanceOf(recipient), amount);
        if (before_.collateral - before_.supply != after_.collateral - after_.supply) revert SettlementMismatch();
    }

    function assertIncrease(uint256 before_, uint256 after_, uint256 amount) internal pure {
        if (after_ < before_ || after_ - before_ != amount) revert SettlementMismatch();
    }

    function assertDecrease(uint256 before_, uint256 after_, uint256 amount) internal pure {
        if (after_ > before_ || before_ - after_ != amount) revert SettlementMismatch();
    }
}
