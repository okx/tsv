// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TSVAdapter} from "dex-adapters/adapters/uniswap-v4/TSVAdapter.sol";
import {ITSVSwapRouter} from "dex-adapters/interfaces/ITSVSwapRouter.sol";
import {DEX_ROUTER_CALLER_MARKER, ORIGIN_PAYER} from "dex-adapters/libraries/Constants.sol";

/// @dev Uses the pinned upstream Adapter unchanged. The fixed key below is test-only.
abstract contract TSVAdapterFixture is Test {
    uint256 internal constant TEST_AUTH_KEY = 0xA11CE;
    uint256 internal authNonce;

    function _adapterRoute(TSVAdapter adapter, address trustedCaller, PoolKey memory poolKey)
        internal
        returns (bytes memory)
    {
        ITSVSwapRouter.PoolKey memory externalKey = ITSVSwapRouter.PoolKey(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            poolKey.fee,
            poolKey.tickSpacing,
            address(poolKey.hooks)
        );
        uint64 expiry = uint64(block.timestamp + 100);
        address[] memory allowed = new address[](1);
        allowed[0] = trustedCaller;
        uint256 nonce = authNonce++;
        bytes32 payloadHash = keccak256(abi.encode(externalKey, expiry));
        bytes32 inner = keccak256(abi.encode(address(adapter), payloadHash, allowed, nonce, block.chainid));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(TEST_AUTH_KEY, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        return abi.encode(TSVAdapter.MoreInfo(externalKey, expiry, allowed, nonce, abi.encodePacked(r, vs)));
    }

    /// @dev Observe the real TSV event rather than adding getters to the upstream Adapter.
    function _assertSwapParticipant(address tsvRouter, address participant) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("SwapExecuted(bytes32,address,bool,int128,int128,uint32)");
        uint256 swaps;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == tsvRouter && logs[i].topics.length == 3 && logs[i].topics[0] == signature) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), participant);
                swaps++;
            }
        }
        assertGt(swaps, 0, "no TSV swap event");
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
