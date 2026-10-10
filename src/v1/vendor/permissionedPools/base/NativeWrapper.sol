// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Vendored from the pinned v4-periphery dependency (src/base/NativeWrapper.sol).
// Public entry points remain callable through super and are virtual for TSV policy overrides.

import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {ActionConstants} from "v4-periphery/libraries/ActionConstants.sol";
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";

/// @title Native Wrapper
/// @notice Used for wrapping and unwrapping native
abstract contract NativeWrapper is ImmutableState {
    /// @notice The address for WETH9
    IWETH9 public immutable WETH9;

    /// @notice Thrown when an unexpected address sends ETH to this contract
    error InvalidEthSender();

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    /// @dev The amount should already be <= the current balance in this contract.
    function _wrap(uint256 amount) internal {
        if (amount > 0) WETH9.deposit{value: amount}();
    }

    /// @dev The amount should already be <= the current balance in this contract.
    function _unwrap(uint256 amount) internal {
        if (amount > 0) WETH9.withdraw(amount);
    }

    receive() external payable virtual {
        _receiveNative();
    }

    /// @dev Receive functions cannot be called through super; share the sender validation with overrides.
    function _receiveNative() internal {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }
}
