// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";

/// @notice Registry call boundary for the LP periphery's pinned PoolKey type.
/// @dev Its tuple ABI matches ITSVPermissionedRegistry. The pinned periphery and
///      venue core use distinct Solidity source types with the same wire encoding.
interface ITSVLPRegistry {
    function registerPool(PoolKey calldata key) external returns (bytes32 poolId);
    function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool);
}
