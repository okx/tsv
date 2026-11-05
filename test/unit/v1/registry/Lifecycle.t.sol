// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    PermissionedRegisterParam,
    SecurityRecord,
    PoolRecord,
    SecurityPauseMode,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsLifecycleTest is FoundationFixture {
    using PoolIdLibrary for PoolKey;

    function testDelistingStopsAllPoolsAndRelistingKeepsSecurityPause() public {
        PermissionedRegisterParam memory secondCurrency = _newStockConfig(SECURITY);
        registry.registerPermissionedCurrency(secondCurrency, 1, bytes32("TEST"));
        PoolKey memory secondKey = key;
        address a = secondCurrency.currency < address(quote) ? secondCurrency.currency : address(quote);
        address b = secondCurrency.currency < address(quote) ? address(quote) : secondCurrency.currency;
        secondKey.currency0 = Currency.wrap(a);
        secondKey.currency1 = Currency.wrap(b);
        bytes32 secondPool = registry.registerPool(secondKey);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        assertTrue(registry.isTradable(secondPool));
        _setSecurityMode(SecurityPauseMode.TRADE, true);
        assertFalse(registry.isTradable(secondPool));
        assertTrue(registry.isLPAllowed(secondPool));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 2);
        assertTrue(registry.updatePoolTickCount(key, 1));
        assertTrue(registry.updatePoolTickCount(secondKey, 1));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST"));
        assertTrue(registry.updatePoolTickCount(key, -1));
        assertTrue(registry.updatePoolTickCount(secondKey, -1));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 2);
        bytes32[] memory poolsToDelist = new bytes32[](2);
        poolsToDelist[0] = poolId;
        poolsToDelist[1] = secondPool;
        assertEq(registry.batchUpdatePoolLifeCycle(poolsToDelist, PoolLifecycle.DELIST, bytes32("TEST")), 2);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 0);
        registry.delistSecurity(SECURITY, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 0);
        _assertOperationGates(false, false);
        assertFalse(registry.isTradable(secondPool));
        assertFalse(registry.isLPAllowed(secondPool));
        assertTrue(registry.isKnownPool(poolId));
        assertTrue(registry.isKnownPool(secondPool));
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST, bytes32("TEST")));
        assertTrue(registry.updatePoolLifeCycle(secondPool, PoolLifecycle.LIST, bytes32("TEST")));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 2);
        _assertOperationGates(false, true);
        assertFalse(registry.isTradable(secondPool));
        assertTrue(registry.isLPAllowed(secondPool));
        assertEq(keccak256(abi.encode(registry.getPool(secondPool).key)), keccak256(abi.encode(secondKey)));
        _setSecurityMode(SecurityPauseMode.ALL, false);
        assertTrue(registry.isTradable(secondPool));
        assertTrue(registry.isLPAllowed(secondPool));
    }

    function testRelistingFullTierRollsBackThenSucceedsAfterCapacityRestored() public {
        registry.setTierPolicy(1, 1, bytes32("TEST"));
        _delistPrimarySecurity();
        _admitAdditionalSecurity(keccak256("other-security"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(1, 2, bytes32("TEST"));
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 2);
    }

    function testTierMovePreservesDirectQuotaUsageAndPoolTierSnapshot() public {
        _submitQuota(1000e18);
        _charge(1e18);
        registry.setTierPolicy(2, 0, bytes32("TEST"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2, bytes32("TEST"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(2, 1, bytes32("TEST"));
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityTierChanged(SECURITY, 1, 2, bytes32("TEST"));
        registry.setSecurityTier(SECURITY, 2, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 0);
        assertEq(registry.getTierPolicy(2).listedCount, 1);
        assertEq(ledger.usedWad(SECURITY, DAY), 1e18);
        assertEq(ledger.Quota(SECURITY), 1000e18);
        assertEq(registry.getPool(poolId).tierId, 1); // Pool retains its registration-time tier.
        registry.setSecurityTier(SECURITY, 1, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        assertEq(registry.getTierPolicy(2).listedCount, 0);
        assertEq(ledger.Quota(SECURITY), 1000e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1e18);
    }

    function testLifecycleRejectsUnknownAndNoopWithoutWrites() public {
        bytes32 absent = keccak256("absent-security");
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY, bytes32("TEST")));
        calls[1] = abi.encodeCall(TSVRegistryV1.relistSecurity, (absent, bytes32("TEST")));
        calls[2] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 1, bytes32("TEST")));
        calls[3] = abi.encodeCall(TSVRegistryV1.delistSecurity, (absent, bytes32("TEST")));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            _registryCall(calls[i]);
            assertEq(_lifecycleState(), beforeState);
        }
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2, bytes32("TEST"));
        _delistPrimarySecurity();
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setSecurityTier(SECURITY, 2, bytes32("TEST"));
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.relistSecurity(SECURITY, bytes32("TEST"));
    }

    function testGlobalEmergencyPauseSurvivesPoolLifecycleChanges() public {
        _grantPauseRoles();
        _enableEmergencyPause();
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE, bytes32("TEST")));
        assertTrue(registry.isPaused());
        _assertOperationGates(false, true);
        _disableEmergencyPause();
        assertFalse(registry.isPaused());
        _assertOperationGates(false, true);
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST, bytes32("TEST")));
        _assertOperationGates(true, true);
        assertTrue(registry.isKnownPool(poolId));
    }

    function testDelistingPreservesSecurityIdentityAndAllowsDifferentSecurity() public {
        _delistPrimarySecurity();
        bytes32 otherSecurity = keccak256("other-security");
        PermissionedRegisterParam memory config = _newStockConfig(otherSecurity);
        registry.registerPermissionedCurrency(config, 1, bytes32("TEST"));
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.registerPermissionedCurrency(config, 1, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        registry.relistSecurity(SECURITY, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 2);
    }

    function testPoolLifecyclePauseAllowsLpButBlocksSwap() public {
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        _assertOperationGates(true, true);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE, bytes32("TEST")));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.PAUSE));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        _assertOperationGates(false, true);

        assertTrue(registry.updatePoolTickCount(key, 1));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST"));
        assertTrue(registry.updatePoolTickCount(key, -1));
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST")));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.DELIST));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 0);
        _assertOperationGates(false, false);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST, bytes32("TEST")));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        _assertOperationGates(true, true);
    }

    function testPoolTickCountDeltaPreservesListedPoolCount() public {
        assertEq(registry.getPoolTickCount(poolId), 0);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, 2));
        assertEq(registry.getPoolTickCount(poolId), 2);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, 1));
        assertEq(registry.getPoolTickCount(poolId), 3);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, -1));
        assertEq(registry.getPoolTickCount(poolId), 2);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, -2));
        assertEq(registry.getPoolTickCount(poolId), 0);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);

        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolTickCount(key, -1);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST")));
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolTickCount(key, 1);
    }

    function testPoolAndSecurityRecordsBackCompatibilityGetters() public {
        SecurityRecord memory security = registry.getSecurity(SECURITY);
        PoolRecord memory pool = registry.getPool(poolId);

        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        assertEq(uint8(registry.getPoolLifeCycle(key)), uint8(PoolLifecycle.LIST));
        assertEq(registry.getPoolTickCount(poolId), 0);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        assertEq(security.poolIds.length, 1);
        assertEq(security.poolIds[0], poolId);
        assertEq(security.listedPoolCount, 1);
        assertEq(pool.securityId, SECURITY);
        assertEq(pool.tierId, security.tierId);
        assertEq(uint8(pool.lifecycle), uint8(PoolLifecycle.LIST));
        assertEq(pool.tickCount, 0);
        assertEq(pool.poolSecurityIndex, 1);

        assertTrue(registry.updatePoolTickCount(key, 1));
        pool = registry.getPool(poolId);
        assertEq(registry.getPoolTickCount(poolId), 1);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 1);
        assertEq(pool.tickCount, 1);
        assertEq(uint8(pool.lifecycle), uint8(PoolLifecycle.LIST));

        assertTrue(registry.updatePoolTickCount(key, -1));
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST, bytes32("TEST")));
        security = registry.getSecurity(SECURITY);
        pool = registry.getPool(poolId);
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.DELIST));
        assertEq(registry.getPoolTickCount(poolId), 0);
        assertEq(registry.getListPoolCountBySecurity(SECURITY), 0);
        assertEq(security.listedPoolCount, 0);
        assertEq(security.poolIds[0], poolId);
        assertEq(pool.securityId, SECURITY);
        assertEq(uint8(pool.lifecycle), uint8(PoolLifecycle.DELIST));
        assertEq(pool.tickCount, 0);
        assertEq(pool.poolSecurityIndex, 1);
    }

    function _lifecycleState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.getTierPolicy(1),
                registry.getTierPolicy(2),
                registry.getPool(poolId),
                registry.getPoolLifeCycle(poolId),
                registry.getPoolTickCount(poolId),
                registry.getListPoolCountBySecurity(SECURITY),
                registry.getCurrencyUnderlying(address(stock)),
                registry.getUnderlying(registry.getCurrencyUnderlying(address(stock))),
                registry.getQuoteToken(address(quote)),
                ledger.usedWad(SECURITY, DAY)
            )
        );
    }

    function _registryCall(bytes memory payload) private {
        (bool ok, bytes memory result) = address(registry).call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
