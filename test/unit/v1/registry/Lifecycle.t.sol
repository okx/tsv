// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PermissionedAdmission, PauseScope, PauseMode, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsLifecycleTest is OperationsFixture {
    using PoolIdLibrary for PoolKey;

    function testDelistingStopsAllPoolsAndRelistingKeepsIndependentPauses() public {
        PermissionedAdmission memory secondCurrency = _newStockConfig(SECURITY);
        registry.registerPermissionedCurrency(secondCurrency, 1);
        PoolKey memory secondKey = key;
        address a = secondCurrency.currency < address(quote) ? secondCurrency.currency : address(quote);
        address b = secondCurrency.currency < address(quote) ? address(quote) : secondCurrency.currency;
        secondKey.currency0 = Currency.wrap(a);
        secondKey.currency1 = Currency.wrap(b);
        bytes32 secondPool = registry.registerPool(secondKey);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertTrue(registry.isTradable(secondPool));
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);
        assertTrue(registry.updatePoolTickCount(key, 1));
        assertTrue(registry.updatePoolTickCount(secondKey, 1));
        assertEq(registry.activePoolCountBySecurity(SECURITY), 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST);
        assertTrue(registry.updatePoolTickCount(key, -1));
        assertTrue(registry.updatePoolTickCount(secondKey, -1));
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);
        bytes32[] memory poolsToDelist = new bytes32[](2);
        poolsToDelist[0] = poolId;
        poolsToDelist[1] = secondPool;
        assertEq(registry.batchUpdatePoolLifeCycle(poolsToDelist, PoolLifecycle.DELIST), 2);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);
        registry.delistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 0);
        _assertOperationGates(false, false);
        assertFalse(registry.isTradable(secondPool));
        assertFalse(registry.isLPAllowed(secondPool));
        assertTrue(registry.isKnownPool(poolId));
        assertTrue(registry.isKnownPool(secondPool));
        _grantPauseRoles();
        uint256 pause = _pause(PauseScope.POOL, secondPool, PauseMode.ALL);
        registry.relistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST));
        assertTrue(registry.updatePoolLifeCycle(secondPool, PoolLifecycle.LIST));
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);
        _assertOperationGates(true, true);
        assertFalse(registry.isTradable(secondPool));
        assertEq(keccak256(abi.encode(registry.getPool(secondPool).key)), keccak256(abi.encode(secondKey)));
        registry.clearEmergencyPause(pause, keccak256("resume"));
        assertTrue(registry.isTradable(secondPool));
        assertTrue(registry.isLPAllowed(secondPool));
    }

    function testRelistingFullTierRollsBackThenSucceedsAfterCapacityRestored() public {
        registry.setTierPolicy(1, 25, 1);
        _delistPrimarySecurity();
        _admitAdditionalSecurity(keccak256("other-security"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.relistSecurity(SECURITY);
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(1, 25, 2);
        registry.relistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testTierMoveReleasesOldSlotAndFailedMoveLeavesCountsAndCap() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        registry.setTierPolicy(2, 10, 0);
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2);
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(2, 10, 1);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityTierChanged(SECURITY, 1, 2);
        registry.setSecurityTier(SECURITY, 2);
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.tierPolicy(2).listedCount, 1);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        registry.setSecurityTier(SECURITY, 1);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.tierPolicy(2).listedCount, 0);
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1.5e18);
    }

    function testLifecycleRejectsUnknownAndNoopWithoutWrites() public {
        bytes32 absent = keccak256("absent-security");
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY));
        calls[1] = abi.encodeCall(TSVRegistryV1.relistSecurity, (absent));
        calls[2] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 1));
        calls[3] = abi.encodeCall(TSVRegistryV1.delistSecurity, (absent));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            _registryCall(calls[i]);
            assertEq(_lifecycleState(), beforeState);
        }
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2);
        _delistPrimarySecurity();
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setSecurityTier(SECURITY, 2);
        registry.relistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.relistSecurity(SECURITY);
    }

    function testPoolRecoveryKeepsIndependentTokenPauses() public {
        _grantPauseRoles();
        uint256 poolPause = _pause(PauseScope.POOL, poolId, PauseMode.ALL);
        uint256 stockPause = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        uint256 quotePause = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.ALL);
        registry.clearEmergencyPause(poolPause, keccak256("resume-pool"));
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(stockPause, keccak256("resume-stock"));
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(quotePause, keccak256("resume-quote"));
        _assertOperationGates(true, true);
        assertTrue(registry.isKnownPool(poolId));
    }

    function testDelistingPreservesSecurityIdentityAndAllowsDifferentSecurity() public {
        _delistPrimarySecurity();
        bytes32 otherSecurity = keccak256("other-security");
        PermissionedAdmission memory config = _newStockConfig(otherSecurity);
        registry.registerPermissionedCurrency(config, 1);
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.registerPermissionedCurrency(config, 1);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        registry.relistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testPoolLifecyclePauseAllowsLpButBlocksSwap() public {
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        _assertOperationGates(true, true);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.PAUSE));
        _assertOperationGates(false, true);

        assertTrue(registry.updatePoolTickCount(key, 1));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST);
        assertTrue(registry.updatePoolTickCount(key, -1));
        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.DELIST));
        _assertOperationGates(false, false);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST));
        assertEq(uint8(registry.getPoolLifeCycle(poolId)), uint8(PoolLifecycle.LIST));
        _assertOperationGates(true, true);
    }

    function testPoolTickCountDeltaMaintainsActivePoolCount() public {
        assertEq(registry.poolTickCount(poolId), 0);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);

        assertTrue(registry.updatePoolTickCount(key, 2));
        assertEq(registry.poolTickCount(poolId), 2);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, 1));
        assertEq(registry.poolTickCount(poolId), 3);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, -1));
        assertEq(registry.poolTickCount(poolId), 2);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 1);

        assertTrue(registry.updatePoolTickCount(key, -2));
        assertEq(registry.poolTickCount(poolId), 0);
        assertEq(registry.activePoolCountBySecurity(SECURITY), 0);

        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolTickCount(key, -1);

        assertTrue(registry.updatePoolLifeCycle(poolId, PoolLifecycle.DELIST));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePoolTickCount(key, 1);
    }

    function _lifecycleState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.tierPolicy(1),
                registry.tierPolicy(2),
                registry.getPool(poolId),
                registry.getPoolLifeCycle(poolId),
                registry.poolTickCount(poolId),
                registry.activePoolCountBySecurity(SECURITY),
                registry.getCurrency(address(stock)),
                registry.getQuoteToken(address(quote)),
                ledger.used(SECURITY, DAY)
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
