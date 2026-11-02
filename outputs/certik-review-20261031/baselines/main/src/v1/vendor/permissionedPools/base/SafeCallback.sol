// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Vendored from the pinned v4-periphery dependency (src/base/SafeCallback.sol).
// Public entry points remain callable through super and are virtual for TSV policy overrides.

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";

/// @title Safe Callback
/// @notice A contract that only allows the Uniswap v4 PoolManager to call the unlockCallback
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @inheritdoc IUnlockCallback
    /// @dev We force the onlyPoolManager modifier by exposing a virtual function after the onlyPoolManager check.
    function unlockCallback(bytes calldata data) public virtual onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev to be implemented by the child contract, to safely guarantee the logic is only executed by the PoolManager
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
