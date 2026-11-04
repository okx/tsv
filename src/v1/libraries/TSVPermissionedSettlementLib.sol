// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermissionsAdapter} from "../vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Internal safe-transfer helpers. Never syncs or settles PoolManager debt.
/// @dev Token exact-transfer behavior is enforced at admission; these helpers do not recheck token balances.
library TSVPermissionedSettlementLib {
    using SafeERC20 for IERC20;

    function transferFromPayer(address token, address payer, address recipient, uint256 amount) internal {
        IERC20(token).safeTransferFrom(payer, recipient, amount);
    }

    function transferFromSelf(address token, address recipient, uint256 amount) internal {
        IERC20(token).safeTransfer(recipient, amount);
    }

    function payStock(address w, address u, address payer, uint256 amount) internal {
        transferFromPayer(u, payer, w, amount);
        IPermissionsAdapter(w).wrapToPoolManager(amount);
    }
}
