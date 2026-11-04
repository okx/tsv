// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PermissionedRegisterParam, SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {IERC20 as PermissionedIERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";

contract TSVAdmissionTest is FoundationFixture {
    function testAdmissionAtomicallyListsAndBindsUniqueUnderlying() public {
        bytes32 securityId = keccak256("new-security");
        PermissionedRegisterParam memory a = _newStockConfig(securityId);
        registry.registerPermissionedCurrency(a, 1, bytes32("TEST"));
        address underlying = registry.getCurrencyUnderlying(a.currency);
        assertTrue(underlying != address(0));
        assertEq(registry.getUnderlying(underlying).securityId, securityId);
        assertEq(registry.getUnderlying(underlying).rawDecimals, 18);
        assertTrue(registry.getSecurity(securityId).listed);
        assertEq(registry.getTierPolicy(1).listedCount, 2);
    }

    function testFirstAdmissionPreservesExistingPoolManagerUnderlying() public {
        bytes32 securityId = keccak256("prefunded-security");
        PermissionedRegisterParam memory a = _newStockConfig(securityId);
        V1MockIssuerWrapped u = V1MockIssuerWrapped(address(PermissionsAdapter(a.currency).PERMISSIONED_TOKEN()));
        address donor = makeAddr("admission-donor");
        u.mintTestShares(donor, 1);
        vm.prank(donor);
        u.transfer(address(manager), 1);
        registry.registerPermissionedCurrency(a, 1, bytes32("TEST"));
        assertTrue(registry.getCurrencyUnderlying(a.currency) != address(0));
        assertEq(u.balanceOf(address(manager)), 1);
        assertEq(PermissionsAdapter(a.currency).totalSupply(), 0);
        assertEq(PermissionsAdapter(a.currency).balanceOf(address(manager)), 0);
        assertEq(registry.getTierPolicy(1).listedCount, 2);
    }

    function testAdditionalWrapperPreservesExistingPoolManagerUnderlying() public {
        address donor = makeAddr("additional-wrapper-donor");
        stockToken.mintTestShares(donor, 1);
        vm.prank(donor);
        stockToken.transfer(address(manager), 1);
        PermissionedRegisterParam memory a = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(a, 1, bytes32("TEST"));
        assertTrue(registry.getCurrencyUnderlying(a.currency) != address(0));
        assertEq(stockToken.balanceOf(address(manager)), 1);
        assertEq(PermissionsAdapter(a.currency).totalSupply(), 0);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
    }

    function testFuzzAdmissionFailureRollsBackSecurityTierAndAsset(uint8 fault) public {
        fault = uint8(bound(fault, 0, 3));
        bytes32 securityId = keccak256("atomic-failure");
        PermissionedRegisterParam memory a = _newStockConfig(securityId);
        address w = a.currency;
        address u = address(PermissionsAdapter(w).PERMISSIONED_TOKEN());
        if (fault == 0) a.securityId = 0;
        else if (fault == 1) a.currency = address(stockToken);
        else if (fault == 2) a.legalShareAdapter = address(stockAdapter);
        else vm.mockCall(u, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        vm.expectRevert();
        registry.registerPermissionedCurrency(a, 1, bytes32("TEST"));
        assertEq(registry.getSecurity(securityId).securityId, 0);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        assertEq(registry.getCurrencyUnderlying(w), address(0));
        assertEq(registry.getUnderlying(u).securityId, 0);
    }

    function testSameUnderlyingManyWrappersShareCanonicalAndDoNotRequireFirstToClear() public {
        // Existing W1 may have supply and inventory; W2 itself must be pristine.
        stockToken.mintTestShares(address(stock), 100);
        vm.prank(address(permissionedRouterFixture));
        stock.wrapToPoolManager(100);
        PermissionedRegisterParam memory second = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(second, 1, bytes32("TEST"));
        assertEq(registry.getCurrencyUnderlying(second.currency), address(stockToken));
        assertEq(registry.getCurrencyUnderlying(address(stock)), address(stockToken));
        assertEq(stock.totalSupply(), 100);
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(stockAdapter));
        second.securityId = keccak256("different-security");
        second.currency = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter)).currency;
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(second, 1, bytes32("TEST"));
        assertEq(registry.getSecurity(second.securityId).securityId, 0);
    }

    function testNewWrapperUsesCurrentCanonicalAdapter() public {
        _setSecurityMode(SecurityPauseMode.ALL, true);
        ERC8056DirectLegalShareAdapter next = new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(next), bytes32("TEST"));
        PermissionedRegisterParam memory second = _prepareCurrency(address(stockToken), SECURITY, address(next));
        registry.registerPermissionedCurrency(second, 1, bytes32("TEST"));
        PermissionedRegisterParam memory wrong = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(wrong, 1, bytes32("TEST"));
    }

    function testQuoteZeroDecimalsAndTypeIsolation() public {
        V1MockToken zero = new V1MockToken("zero-quote", 0);
        registry.registerQuoteToken(address(zero), bytes32("TEST"));
        assertEq(registry.getQuoteToken(address(zero)).rawDecimals, 0);
        assertTrue(registry.getQuoteToken(address(zero)).registered);
        address[5] memory bad =
            [address(stock), address(stockToken), address(manager), address(registry), address(permissionsFactory)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnsupportedAsset.selector, bad[i]));
            registry.registerQuoteToken(bad[i], bytes32("TEST"));
        }
        // Even a created but unverified W is not a quote.
        address unverified = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(issuerChecker))
        );
        assertEq(permissionsFactory.verifiedPermissionsAdapterOf(unverified), address(0));
        vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnsupportedAsset.selector, unverified));
        registry.registerQuoteToken(unverified, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.registerQuoteToken(address(zero), bytes32("TEST"));
    }

    function testPoolOnlyAcceptsOneStockAndOneQuote() public {
        PermissionedRegisterParam memory second = _newStockConfig(SECURITY);
        registry.registerPermissionedCurrency(second, 1, bytes32("TEST"));
        V1MockToken otherQuote = new V1MockToken("Q2", 6);
        registry.registerQuoteToken(address(otherQuote), bytes32("TEST"));
        address[3] memory a = [address(stock), address(quote), address(stockToken)];
        address[3] memory b = [second.currency, address(otherQuote), address(quote)];
        for (uint256 i; i < a.length; ++i) {
            PoolKey memory bad = PoolKey(
                Currency.wrap(a[i] < b[i] ? a[i] : b[i]),
                Currency.wrap(a[i] < b[i] ? b[i] : a[i]),
                3000,
                60,
                IHooks(address(this))
            );
            vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
            registry.registerPool(bad);
        }
    }

    function testPoolRegisterDisableFlagsBlockOnlyNewPoolsAndPreserveExistingPool() public {
        assertTrue(registry.getUnderlying(address(stockToken)).registered);
        assertTrue(registry.getQuoteToken(address(quote)).registered);

        registry.disableQuoteTokenPoolRegister(address(quote), bytes32("TEST"));
        assertFalse(registry.getQuoteToken(address(quote)).registered);
        _assertOperationGates(true, true);

        PermissionedRegisterParam memory second = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(second, 1, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPool(_poolKey(second.currency, address(quote)));

        V1MockToken otherQuote = new V1MockToken("Q2", 6);
        registry.registerQuoteToken(address(otherQuote), bytes32("TEST"));
        registry.disableUnderlyingPoolRegister(address(stockToken), bytes32("TEST"));
        assertFalse(registry.getUnderlying(address(stockToken)).registered);
        _assertOperationGates(true, true);

        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPool(_poolKey(second.currency, address(otherQuote)));

        PermissionedRegisterParam memory third = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(third, 1, bytes32("TEST"));
        assertTrue(registry.getUnderlying(address(stockToken)).registered);
        bytes32 newPoolId = registry.registerPool(_poolKey(third.currency, address(otherQuote)));
        assertTrue(registry.isKnownPool(newPoolId));
    }

    function testIssuerOwnerRotationDoesNotRequireRegistryUpdate() public {
        address next = makeAddr("next-issuer-owner");
        stock.transferOwnership(address(next));
        vm.prank(next);
        stock.acceptOwnership();
        assertEq(registry.getCurrencyUnderlying(address(stock)), address(stockToken));
        _assertOperationGates(true, true);
    }

    function _poolKey(address a, address b) private view returns (PoolKey memory) {
        address currency0 = a < b ? a : b;
        address currency1 = a < b ? b : a;
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), 3000, 60, IHooks(address(this)));
    }
}
