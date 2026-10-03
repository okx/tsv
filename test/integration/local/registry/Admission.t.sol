// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TokenStatus, PoolStatus, MarketStatus} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVAdmissionLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVAdmissionLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testAdmissionOpensRealV4PoolWithoutMarketReport() public view {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint8(registry.getToken(address(stock)).status), uint8(TokenStatus.APPROVED));
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.OPEN));
        assertEq(registry.marketSequence(SECURITY), 0);
        assertEq(inbox.lastSequence(0, SECURITY), 0);
        assertTrue(registry.isTradable(poolId));
        assertTrue(registry.isLPAllowed(poolId));
        assertGt(lpManager.getPosition(positionId).liquidity, 0);
    }

    function testPoolInitializationFailureLeavesNoPendingRecordOrCounts() public {
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        uint32 stockCount = registry.activePoolCountByCurrency(address(stock));
        uint32 quoteCount = registry.activePoolCountByCurrency(address(quote));
        vm.expectRevert();
        lpManager.initializePool(otherPool, 0, keccak256("bad-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ABSENT));
        assertFalse(registry.isKnownPool(otherPoolId));
        assertEq(registry.activePoolCountByCurrency(address(stock)), stockCount);
        assertEq(registry.activePoolCountByCurrency(address(quote)), quoteCount);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(otherPoolId));
        assertEq(price, 0);
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("correct-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ACTIVE));
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
    }
}
