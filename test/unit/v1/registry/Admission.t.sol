// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    PermissionedAdmission,
    PermissionedCurrencyConfig,
    AssetStatus,
    PauseScope,
    PauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {IERC20 as PermissionedIERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";

contract TSVAdmissionTest is FoundationFixture {
    function testAdmissionAtomicallyListsAndBindsUniqueUnderlying() public {
        bytes32 securityId = keccak256("new-security");
        PermissionedAdmission memory a = _newStockConfig(securityId);
        registry.admitPermissionedSecurity(1, a);
        PermissionedCurrencyConfig memory c = registry.getCurrency(a.currency);
        assertEq(uint8(c.status), uint8(AssetStatus.APPROVED));
        assertEq(c.configVersion, 1);
        assertEq(c.expectedOwner, address(this));
        assertEq(registry.getUnderlying(c.underlying).securityId, securityId);
        assertEq(registry.getUnderlying(c.underlying).legalAdapterVersion, 1);
        assertEq(registry.getUnderlying(c.underlying).rawDecimals, 18);
        assertTrue(registry.getSecurity(securityId).listed);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testFuzzAdmissionFailureRollsBackSecurityTierAndAsset(uint8 fault) public {
        fault = uint8(bound(fault, 0, 8));
        bytes32 securityId = keccak256("atomic-failure");
        PermissionedAdmission memory a = _newStockConfig(securityId);
        address w = a.currency;
        address u = address(PermissionsAdapter(w).PERMISSIONED_TOKEN());
        if (fault == 0) a.securityId = 0;
        else if (fault == 1) a.currency = address(stockToken);
        else if (fault == 2) a.legalShareAdapter = address(stockAdapter);
        else if (fault == 3) a.expectedOwner = address(exitReceiver);
        else if (fault == 4) PermissionsAdapter(w).updateAllowedWrapper(address(permissionedRouterFixture), false);
        else if (fault == 5) PermissionsAdapter(w).updateAllowedHook(IHooks(address(this)), false);
        else if (fault == 6) registry.setPermissionedOwnerApproval(address(this), false);
        else if (fault == 7) vm.mockCall(u, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        else vm.mockCall(w, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1)));
        vm.expectRevert();
        registry.admitPermissionedSecurity(1, a);
        assertEq(registry.getSecurity(securityId).securityId, 0);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getCurrency(w).underlying, address(0));
        assertEq(registry.getUnderlying(u).securityId, 0);
        assertEq(registry.exitAdminOf(w), address(exitReceiver));
    }

    function testSameUnderlyingManyWrappersShareCanonicalAndDoNotRequireFirstToClear() public {
        // Existing W1 may have supply and inventory; W2 itself must be pristine.
        stockToken.mintTestShares(address(stock), 100);
        vm.prank(address(permissionedRouterFixture));
        stock.wrapToPoolManager(100);
        PermissionedAdmission memory second = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(second);
        assertEq(registry.getCurrency(second.currency).underlying, address(stockToken));
        assertEq(registry.getCurrency(address(stock)).underlying, address(stockToken));
        assertEq(stock.totalSupply(), 100);
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(stockAdapter));
        second.securityId = keccak256("different-security");
        second.currency = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter)).currency;
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.admitPermissionedSecurity(1, second);
        assertEq(registry.getSecurity(second.securityId).securityId, 0);
    }

    function testNewWrapperUsesCurrentCanonicalVersion() public {
        _grantPauseRoles();
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter next =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken), 2);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(next));
        PermissionedAdmission memory second = _prepareCurrency(address(stockToken), SECURITY, address(next));
        registry.registerPermissionedCurrency(second);
        assertEq(registry.getUnderlying(registry.getCurrency(second.currency).underlying).legalAdapterVersion, 2);
        PermissionedAdmission memory wrong = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(wrong);
    }

    function testQuoteZeroDecimalsAndTypeIsolation() public {
        V1MockToken zero = new V1MockToken("zero-quote", 0);
        registry.registerQuoteToken(address(zero));
        assertEq(registry.getQuoteToken(address(zero)).rawDecimals, 0);
        assertEq(uint8(registry.getQuoteToken(address(zero)).status), uint8(AssetStatus.APPROVED));
        address[5] memory bad =
            [address(stock), address(stockToken), address(manager), address(registry), address(permissionsFactory)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnsupportedAsset.selector, bad[i]));
            registry.registerQuoteToken(bad[i]);
        }
        // Even a created but unverified W is not a quote.
        address unverified = registry.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(registry))
        );
        assertEq(registry.verifiedPermissionsAdapterOf(unverified), address(0));
        vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnsupportedAsset.selector, unverified));
        registry.registerQuoteToken(unverified);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.registerQuoteToken(address(zero));
    }

    function testPoolOnlyAcceptsOneStockAndOneQuote() public {
        PermissionedAdmission memory second = _newStockConfig(SECURITY);
        registry.registerPermissionedCurrency(second);
        V1MockToken otherQuote = new V1MockToken("Q2", 6);
        registry.registerQuoteToken(address(otherQuote));
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
            registry.registerPendingPool(bad);
        }
    }

    function testStatusVersionsPreserveIdentityAndRestoreWithSupplyAndFees() public {
        stockToken.mintTestShares(address(stock), 100);
        vm.prank(address(permissionedRouterFixture));
        stock.wrapToPoolManager(100);
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
        assertEq(registry.getCurrency(address(stock)).configVersion, 2);
        vm.mockCall(
            address(manager),
            abi.encodeWithSignature("protocolFeesAccrued(address)", address(stock)),
            abi.encode(uint256(10))
        );
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.APPROVED);
        assertEq(registry.getCurrency(address(stock)).configVersion, 3);
        assertEq(registry.getCurrency(address(stock)).underlying, address(stockToken));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.ABSENT);
        registry.setQuoteTokenStatus(address(quote), AssetStatus.DISABLED);
        registry.setQuoteTokenStatus(address(quote), AssetStatus.APPROVED);
        assertEq(registry.getQuoteToken(address(quote)).configVersion, 3);
    }

    function testOwnerRotationAndExitAdminHaveIndependentVersions() public {
        V1ConfigReceiver next = new V1ConfigReceiver();
        registry.setPermissionedOwnerApproval(address(next), true);
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
        stock.transferOwnership(address(next));
        next.execute(address(stock), abi.encodeWithSignature("acceptOwnership()"));
        registry.updatePermissionedExpectedOwner(address(stock), address(next));
        assertEq(registry.getCurrency(address(stock)).configVersion, 3);
        assertEq(registry.exitAdminVersion(address(stock)), 1);
        assertEq(registry.getUnderlying(address(stockToken)).legalAdapterVersion, 1);
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.APPROVED);
        assertEq(registry.getCurrency(address(stock)).configVersion, 4);
        V1ConfigReceiver receiver = new V1ConfigReceiver();
        registry.setExitAdmin(address(stock), address(receiver));
        assertEq(registry.exitAdminVersion(address(stock)), 2);
        assertEq(registry.getCurrency(address(stock)).configVersion, 4);
        vm.expectRevert(TSVRegistryV1.PermissionedPolicyMismatch.selector);
        registry.setExitAdmin(address(stock), address(next));
    }

    function testRestoringQuotesRejectsChangedPrecisionWithoutChangingVersion() public {
        registry.setQuoteTokenStatus(address(quote), AssetStatus.DISABLED);
        vm.mockCall(address(quote), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(TSVRegistryV1.PermissionedMetadataMismatch.selector);
        registry.setQuoteTokenStatus(address(quote), AssetStatus.APPROVED);
        assertEq(registry.getQuoteToken(address(quote)).configVersion, 2);
    }
}
