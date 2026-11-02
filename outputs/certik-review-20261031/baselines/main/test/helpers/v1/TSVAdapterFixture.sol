// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TSVAdapter} from "dex-adapters/adapters/uniswap-v4/TSVAdapter.sol";
import {ITSVSwapRouter} from "dex-adapters/interfaces/ITSVSwapRouter.sol";
import {DEX_ROUTER_CALLER_MARKER, ORIGIN_PAYER} from "dex-adapters/libraries/Constants.sol";

/// @dev Uses the upstream Adapter with W-to-U settlement currency resolution. No backend signing material is required.
abstract contract TSVAdapterFixture is Test {
    function _adapterRoute(
        TSVAdapter adapter,
        PoolKey memory poolKey,
        uint256 expectedMultiplier,
        uint256 amountIn,
        bool zeroForOne
    ) internal returns (bytes memory) {
        ITSVSwapRouter.PoolKey memory externalKey = ITSVSwapRouter.PoolKey(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            poolKey.fee,
            poolKey.tickSpacing,
            address(poolKey.hooks)
        );
        address inputCurrency = Currency.unwrap(zeroForOne ? poolKey.currency0 : poolKey.currency1);
        bool isBuy = ITSVSwapRouter(adapter.TSV_ROUTER()).settlementCurrency(inputCurrency) == inputCurrency;
        return abi.encode(TSVAdapter.MoreInfo(externalKey, expectedMultiplier, isBuy ? 0 : amountIn));
    }

    function _adapterPayload(
        bool direction,
        address recipient,
        address pool,
        bytes memory route,
        address participant,
        address refundTo
    ) internal pure returns (bytes memory) {
        bytes memory data = direction
            ? abi.encodeCall(TSVAdapter.sellBase, (recipient, pool, route))
            : abi.encodeCall(TSVAdapter.sellQuote, (recipient, pool, route));
        return abi.encodePacked(
            data, DEX_ROUTER_CALLER_MARKER | uint256(uint160(participant)), ORIGIN_PAYER | uint256(uint160(refundTo))
        );
    }
}

/// @dev A contract participant makes the DEX call itself; the controlling EOA is not the trader.
contract DexRouterTestWallet {
    address public immutable admin;

    constructor(address owner) {
        admin = owner;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == admin);
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(returned, 32), mload(returned)) }
        return returned;
    }
}
