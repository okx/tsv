// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVOperationsPoolCreationLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testInvalidPoolKeysPricesAndEvidenceRollBackRegistryAndV4() public {
        for (uint8 fault; fault < 13; ++fault) {
            PoolKey memory candidate = key;
            candidate.fee = 500;
            uint160 price = uint160(1 << 96);
            bytes32 evidence = keccak256("price-basis");
            if (fault == 0) {
                candidate.hooks = IHooks(address(this));
            } else if (fault == 1) {
                candidate.fee = 0x800000;
            } else if (fault == 2) {
                candidate.fee = 1000000;
            } else if (fault == 3) {
                candidate.tickSpacing = 0;
            } else if (fault == 4) {
                candidate.tickSpacing = 32768;
            } else if (fault == 5) {
                Currency tmp = candidate.currency0;
                candidate.currency0 = candidate.currency1;
                candidate.currency1 = tmp;
            } else if (fault == 6) {
                candidate.currency0 = candidate.currency1;
            } else if (fault == 7) {
                candidate.currency0 = Currency.wrap(address(0));
            } else if (fault == 8) {
                price = 0;
            } else if (fault == 9) {
                price = TickMath.MIN_SQRT_PRICE - 1;
            } else if (fault == 10) {
                price = TickMath.MAX_SQRT_PRICE;
            } else if (fault == 11) {
                evidence = 0;
            } else {
                candidate = key; // Duplicate initialization of the original funded pool.
            }
            bytes32 beforeState = _poolState(candidate);
            vm.expectRevert();
            lpManager.initializePool(candidate, price, evidence);
            assertEq(_poolState(candidate), beforeState);
        }
        PoolKey memory corrected = key;
        corrected.fee = 500;
        lpManager.initializePool(corrected, uint160(1 << 96), keccak256("corrected"));
        assertTrue(registry.isKnownPool(PoolId.unwrap(corrected.toId())));
    }

    function testValidFeeTickAndPriceBoundariesInitializeRealV4Pools() public {
        PoolKey memory low = key;
        low.fee = 0;
        low.tickSpacing = 1;
        lpManager.initializePool(low, TickMath.MIN_SQRT_PRICE, keccak256("minimum"));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, low.toId());
        assertEq(price, TickMath.MIN_SQRT_PRICE);
        PoolKey memory high = key;
        high.fee = 999999;
        high.tickSpacing = 32767;
        lpManager.initializePool(high, TickMath.MAX_SQRT_PRICE - 1, keccak256("maximum"));
        (price,,,) = StateLibrary.getSlot0(manager, high.toId());
        assertEq(price, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 3);
    }

    function _poolState(PoolKey memory candidate) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, candidate.toId());
        return keccak256(
            abi.encode(
                registry.getPool(PoolId.unwrap(candidate.toId())),
                registry.getSecurity(SECURITY),
                registry.activePoolCountByCurrency(address(stock)),
                registry.activePoolCountByCurrency(address(quote)),
                price,
                tick,
                protocolFee,
                lpFee,
                _swapStateDigest(DAY)
            )
        );
    }
}
