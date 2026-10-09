// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Vendored from Uniswap v4-periphery 9969eec44cfdf07e24b41de47f40276a58401976 (src/base/PoolInitializer_v4.sol).
// Makes initializePool virtual so TSV can register pools and propagate initialization failures.
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer_v4} from "v4-periphery/interfaces/IPoolInitializer_v4.sol";

abstract contract PoolInitializer_v4 is ImmutableState, IPoolInitializer_v4 {
    /// @inheritdoc IPoolInitializer_v4
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable virtual returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
