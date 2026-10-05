// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, PoolStatus} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsLifecycleTest is OperationsFixture {
    using PoolIdLibrary for PoolKey;

    function testMultipleCurrenciesAndPoolsCountOneListedSecurity() public {
        TokenConfig memory secondCurrency = _newStockConfig(SECURITY);
        registry.registerToken(secondCurrency);
        PoolKey memory secondKey = key;
        address a = secondCurrency.poolCurrency < address(quote) ? secondCurrency.poolCurrency : address(quote);
        address b = secondCurrency.poolCurrency < address(quote) ? address(quote) : secondCurrency.poolCurrency;
        secondKey.currency0 = Currency.wrap(a);
        secondKey.currency1 = Currency.wrap(b);
        bytes32 secondPool = registry.registerPendingPool(secondKey);
        registry.markPoolActive(secondPool, uint160(1 << 96), address(this));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY);
        registry.disablePool(poolId);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY);
        registry.disablePool(secondPool);
        registry.delistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 0);
        registry.relistSecurity(SECURITY);
        registry.enablePool(poolId);
        registry.enablePool(secondPool);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        assertEq(keccak256(abi.encode(registry.getPool(secondPool).key)), keccak256(abi.encode(secondKey)));
    }

    function testRelistingFullTierRollsBackThenSucceedsAfterCapacityRestored() public {
        registry.setTierPolicy(1, 25, 1);
        registry.disablePool(poolId);
        registry.delistSecurity(SECURITY);
        _admitAdditionalSecurity(keccak256("other-security"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.relistSecurity(SECURITY);
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(1, 25, 2);
        registry.relistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 2);
        assertEq(registry.getSecurity(SECURITY).version, 3);
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
        assertEq(registry.getSecurity(SECURITY).version, 2);
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
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY));
        calls[1] = abi.encodeCall(TSVRegistryV1.relistSecurity, (absent));
        calls[2] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 1));
        calls[3] = abi.encodeCall(TSVRegistryV1.delistSecurity, (absent));
        calls[4] = abi.encodeCall(TSVRegistryV1.delistSecurity, (SECURITY));
        calls[5] = abi.encodeCall(TSVRegistryV1.disablePool, (bytes32(0)));
        calls[6] = abi.encodeCall(TSVRegistryV1.enablePool, (poolId));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            _registryCall(calls[i]);
            assertEq(_lifecycleState(), beforeState);
        }
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2);
        registry.disablePool(poolId);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.disablePool(poolId);
        registry.delistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setSecurityTier(SECURITY, 2);
        registry.relistSecurity(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.relistSecurity(SECURITY);
    }

    function testPoolEnableRechecksEachCurrencyAndDoesNotChangeCountsOnFailure() public {
        registry.disablePool(poolId);
        address[2] memory currencies = [address(stock), address(quote)];
        for (uint256 i; i < currencies.length; ++i) {
            registry.setTokenStatus(currencies[i], TokenStatus.DISABLED);
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId);
            assertEq(_lifecycleState(), beforeState);
            registry.setTokenStatus(currencies[i], TokenStatus.APPROVED);
        }
        registry.enablePool(poolId);
        assertEq(registry.getPool(poolId).version, 4);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
    }

    function testDelistingPreservesSecurityIdentityAndAllowsDifferentSecurity() public {
        registry.disablePool(poolId);
        registry.delistSecurity(SECURITY);
        bytes32 otherSecurity = keccak256("other-security");
        TokenConfig memory config = _newStockConfig(otherSecurity);
        registry.admitSecurity(otherSecurity, 1, config);
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(SECURITY, 1, config);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        registry.relistSecurity(SECURITY);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function _lifecycleState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.tierPolicy(1),
                registry.tierPolicy(2),
                registry.getPool(poolId),
                registry.getToken(address(stock)),
                registry.getToken(address(quote)),
                registry.activePoolCountByCurrency(address(stock)),
                registry.activePoolCountByCurrency(address(quote)),
                ledger.used(SECURITY, DAY)
            )
        );
    }

    function _registryCall(bytes memory payload) private {
        (bool ok, bytes memory result) = address(registry).call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}
