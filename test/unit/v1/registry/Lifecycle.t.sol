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
        registry.registerToken(secondCurrency, keccak256("second-currency"));
        PoolKey memory secondKey = key;
        address a = secondCurrency.poolCurrency < address(quote) ? secondCurrency.poolCurrency : address(quote);
        address b = secondCurrency.poolCurrency < address(quote) ? address(quote) : secondCurrency.poolCurrency;
        secondKey.currency0 = Currency.wrap(a);
        secondKey.currency1 = Currency.wrap(b);
        bytes32 secondPool = registry.registerPendingPool(secondKey);
        registry.markPoolActive(secondPool, uint160(1 << 96), address(this), keccak256("price"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("active-pools"));
        registry.disablePool(poolId, keccak256("disable-first"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("one-active-pool"));
        registry.disablePool(secondPool, keccak256("disable-second"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 0);
        registry.relistSecurity(SECURITY, keccak256("relist"));
        registry.enablePool(poolId, keccak256("enable-first"));
        registry.enablePool(secondPool, keccak256("enable-second"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        assertEq(keccak256(abi.encode(registry.getPool(secondPool).key)), keccak256(abi.encode(secondKey)));
    }

    function testRelistingFullTierRollsBackThenSucceedsAfterCapacityRestored() public {
        registry.setTierPolicy(1, 25, 1, keccak256("capacity-one"));
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        _admitAdditionalSecurity(keccak256("other-security"), keccak256("OTHER"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.relistSecurity(SECURITY, keccak256("full"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(1, 25, 2, keccak256("capacity-two"));
        registry.relistSecurity(SECURITY, keccak256("retry"));
        assertEq(registry.tierPolicy(1).listedCount, 2);
        assertEq(registry.getSecurity(SECURITY).version, 3);
    }

    function testTierMoveReleasesOldSlotAndFailedMoveLeavesCountsAndCap() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        registry.setTierPolicy(2, 10, 0, keccak256("full-tier"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2, keccak256("full"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(2, 10, 1, keccak256("capacity"));
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityTierChanged(SECURITY, 1, 2, keccak256("move"));
        registry.setSecurityTier(SECURITY, 2, keccak256("move"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.tierPolicy(2).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).version, 2);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        registry.setSecurityTier(SECURITY, 1, keccak256("move-back"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.tierPolicy(2).listedCount, 0);
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1.5e18);
    }

    function testLifecycleRejectsUnknownNoopAndMissingEvidenceWithoutWrites() public {
        bytes32 absent = keccak256("absent-security");
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY, keccak256("already-listed")));
        calls[1] = abi.encodeCall(TSVRegistryV1.relistSecurity, (absent, keccak256("unknown")));
        calls[2] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 1, keccak256("same-tier")));
        calls[3] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 2, bytes32(0)));
        calls[4] = abi.encodeCall(TSVRegistryV1.delistSecurity, (absent, keccak256("unknown")));
        calls[5] = abi.encodeCall(TSVRegistryV1.delistSecurity, (SECURITY, bytes32(0)));
        calls[6] = abi.encodeCall(TSVRegistryV1.disablePool, (poolId, bytes32(0)));
        calls[7] = abi.encodeCall(TSVRegistryV1.disablePool, (bytes32(0), keccak256("unknown")));
        calls[8] = abi.encodeCall(TSVRegistryV1.enablePool, (poolId, keccak256("already-active")));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            _registryCall(calls[i]);
            assertEq(_lifecycleState(), beforeState);
        }
        registry.disablePool(poolId, keccak256("disable"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.disablePool(poolId, keccak256("twice"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("twice"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.relistSecurity(SECURITY, 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setSecurityTier(SECURITY, 2, keccak256("delisted"));
    }

    function testPoolEnableRechecksEachCurrencyAndDoesNotChangeCountsOnFailure() public {
        registry.disablePool(poolId, keccak256("disable"));
        address[2] memory currencies = [address(stock), address(quote)];
        for (uint256 i; i < currencies.length; ++i) {
            registry.setTokenStatus(currencies[i], TokenStatus.DISABLED, keccak256("disable-currency"));
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId, keccak256("blocked"));
            assertEq(_lifecycleState(), beforeState);
            registry.setTokenStatus(currencies[i], TokenStatus.APPROVED, keccak256("reenable-currency"));
        }
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, 0);
        registry.enablePool(poolId, keccak256("enable"));
        assertEq(registry.getPool(poolId).version, 4);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
    }

    function testDelistingDoesNotReleaseSymbolIdentity() public {
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        bytes32 otherSecurity = keccak256("other-security");
        TokenConfig memory config = _newStockConfig(otherSecurity);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(otherSecurity, keccak256("STDx"), 1, config, keccak256("reused-symbol"));
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(SECURITY, keccak256("new-symbol"), 1, config, keccak256("reused-id"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        registry.relistSecurity(SECURITY, keccak256("relist"));
        assertEq(registry.getSecurity(SECURITY).symbolHash, keccak256("STDx"));
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
