// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice ABI boundary for an independently deployed unsigned TSV DEX adapter.
/// @dev No external adapter implementation is compiled or distributed by this repository.
interface ITSVDEXAdapter {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct MoreInfo {
        PoolKey key;
        uint256 expectedMultiplier;
        uint256 amountIn;
    }

    function TSV_ROUTER() external view returns (address);
    function isDexRouter(address caller) external view returns (bool);
}

/// @notice Public TSV Router getter used to validate the adapter's settlement mapping.
interface ITSVRouterSettlement {
    function settlementCurrency(address currency) external view returns (address);
}
