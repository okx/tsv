// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PermissionedAdmission, PermissionedCurrencyConfig, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {IERC20 as PermissionedIERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";

contract TSVAdmissionTest is FoundationFixture {
    function testAdmissionAtomicallyListsAndBindsUniqueUnderlying() public {
        bytes32 securityId = keccak256("new-security");
        PermissionedAdmission memory a = _newStockConfig(securityId);
        registry.admitPermissionedSecurity(1, a);
        PermissionedCurrencyConfig memory c = registry.getCurrency(a.currency);
        assertTrue(c.underlying != address(0));
        assertEq(c.expectedOwner, address(this));
        assertEq(registry.getUnderlying(c.underlying).securityId, securityId);
        assertEq(registry.getUnderlying(c.underlying).rawDecimals, 18);
        assertTrue(registry.getSecurity(securityId).listed);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testFirstAdmissionPreservesExistingPoolManagerUnderlying() public {
        bytes32 securityId = keccak256("prefunded-security");
        PermissionedAdmission memory a = _newStockConfig(securityId);
        V1MockIssuerWrapped u = V1MockIssuerWrapped(address(PermissionsAdapter(a.currency).PERMISSIONED_TOKEN()));
        address donor = makeAddr("admission-donor");
        u.mintTestShares(donor, 1);
        vm.prank(donor);
        u.transfer(address(manager), 1);
        registry.admitPermissionedSecurity(1, a);
        assertTrue(registry.getCurrency(a.currency).underlying != address(0));
        assertEq(u.balanceOf(address(manager)), 1);
        assertEq(PermissionsAdapter(a.currency).totalSupply(), 0);
        assertEq(PermissionsAdapter(a.currency).balanceOf(address(manager)), 0);
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testAdditionalWrapperPreservesExistingPoolManagerUnderlying() public {
        address donor = makeAddr("additional-wrapper-donor");
        stockToken.mintTestShares(donor, 1);
        vm.prank(donor);
        stockToken.transfer(address(manager), 1);
        PermissionedAdmission memory a = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(a);
        assertTrue(registry.getCurrency(a.currency).underlying != address(0));
        assertEq(stockToken.balanceOf(address(manager)), 1);
        assertEq(PermissionsAdapter(a.currency).totalSupply(), 0);
        assertEq(registry.tierPolicy(1).listedCount, 1);
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
        assertEq(registry.exitAdminOf(u), address(exitReceiver));
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

    function testNewWrapperUsesCurrentCanonicalAdapter() public {
        _grantPauseRoles();
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter next =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(next));
        PermissionedAdmission memory second = _prepareCurrency(address(stockToken), SECURITY, address(next));
        registry.registerPermissionedCurrency(second);
        PermissionedAdmission memory wrong = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(wrong);
    }

    function testQuoteZeroDecimalsAndTypeIsolation() public {
        V1MockToken zero = new V1MockToken("zero-quote", 0);
        registry.registerQuoteToken(address(zero));
        assertEq(registry.getQuoteToken(address(zero)).rawDecimals, 0);
        assertTrue(registry.getQuoteToken(address(zero)).registered);
        address[5] memory bad =
            [address(stock), address(stockToken), address(manager), address(registry), address(permissionsFactory)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnsupportedAsset.selector, bad[i]));
            registry.registerQuoteToken(bad[i]);
        }
        // Even a created but unverified W is not a quote.
        address unverified = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(issuerChecker))
        );
        assertEq(permissionsFactory.verifiedPermissionsAdapterOf(unverified), address(0));
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
            registry.registerPool(bad);
        }
    }

    function testTokenRecoveryPreservesIdentityWithSupplyAndFees() public {
        stockToken.mintTestShares(address(stock), 100);
        vm.prank(address(permissionedRouterFixture));
        stock.wrapToPoolManager(100);
        _grantPauseRoles();
        uint256 id = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        _assertOperationGates(false, false);
        vm.mockCall(
            address(manager),
            abi.encodeWithSignature("protocolFeesAccrued(address)", address(stock)),
            abi.encode(uint256(10))
        );
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        assertEq(registry.getCurrency(address(stock)).underlying, address(stockToken));
        assertEq(stock.totalSupply(), 100);
        id = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.ALL);
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertTrue(registry.getQuoteToken(address(quote)).registered);
        _assertOperationGates(true, true);
    }

    function testOwnerRotationRequiresFullPauseAndPreservesExitAdmin() public {
        V1ConfigReceiver next = new V1ConfigReceiver();
        registry.setPermissionedOwnerApproval(address(next), true);
        stock.transferOwnership(address(next));
        next.execute(address(stock), abi.encodeWithSignature("acceptOwnership()"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePermissionedExpectedOwner(address(stock), address(next));
        _grantPauseRoles();
        uint256 trade = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.TRADE);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.updatePermissionedExpectedOwner(address(stock), address(next));
        uint256 lp = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.LP);
        registry.updatePermissionedExpectedOwner(address(stock), address(next));
        assertEq(registry.getCurrency(address(stock)).expectedOwner, address(next));
        assertEq(registry.exitAdminOf(address(stockToken)), address(exitReceiver));
        registry.clearEmergencyPause(trade, keccak256("resume"));
        registry.clearEmergencyPause(lp, keccak256("resume"));
        _assertOperationGates(true, true);
        V1ConfigReceiver receiver = new V1ConfigReceiver();
        registry.setExitAdmin(address(stockToken), address(receiver));
        vm.expectRevert(TSVRegistryV1.PermissionedPolicyMismatch.selector);
        registry.setExitAdmin(address(stockToken), address(next));
    }

    function testExitAdminIsSharedByUnderlyingAndInheritedByNewWrappers() public {
        PermissionedAdmission memory second = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(second);
        assertEq(registry.exitAdminOf(second.currency), address(0));
        V1ConfigReceiver next = new V1ConfigReceiver();
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.ExitAdminUpdated(address(stockToken), address(exitReceiver), address(next));
        registry.setExitAdmin(address(stockToken), address(next));
        PermissionedAdmission memory third = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(third);
        assertEq(registry.exitAdminOf(address(stockToken)), address(next));
        _grantPauseRoles();
        uint256 id = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        registry.clearEmergencyPause(id, keccak256("resume"));
        id = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(second.currency))), PauseMode.ALL);
        registry.clearEmergencyPause(id, keccak256("resume"));
        PermissionedAdmission memory other = _newStockConfig(keccak256("independent-exit-underlying"));
        registry.admitPermissionedSecurity(1, other);
        address otherU = registry.getCurrency(other.currency).underlying;
        assertEq(registry.exitAdminOf(otherU), address(exitReceiver));
    }

    function testSharedExitAdminRejectsEverySiblingOwnerAndInvalidUnderlying() public {
        PermissionedAdmission memory second = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter));
        registry.registerPermissionedCurrency(second);
        V1ConfigReceiver siblingOwner = new V1ConfigReceiver();
        registry.setPermissionedOwnerApproval(address(siblingOwner), true);
        _grantPauseRoles();
        _pause(PauseScope.TOKEN, bytes32(uint256(uint160(second.currency))), PauseMode.ALL);
        PermissionsAdapter(second.currency).transferOwnership(address(siblingOwner));
        siblingOwner.execute(second.currency, abi.encodeWithSignature("acceptOwnership()"));
        // Current issuer owner must be excluded even before the Registry's expected owner is updated.
        vm.expectRevert(TSVRegistryV1.PermissionedPolicyMismatch.selector);
        registry.setExitAdmin(address(stockToken), address(siblingOwner));
        registry.updatePermissionedExpectedOwner(second.currency, address(siblingOwner));
        vm.expectRevert(TSVRegistryV1.PermissionedPolicyMismatch.selector);
        registry.setExitAdmin(address(stockToken), address(siblingOwner));
        address[4] memory invalidU = [address(stock), address(quote), address(registry), address(0)];
        for (uint256 i; i < invalidU.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
            registry.setExitAdmin(invalidU[i], address(exitReceiver));
        }
        assertEq(registry.exitAdminOf(address(stockToken)), address(exitReceiver));
    }

    function testQuoteRecoveryRejectsChangedPrecisionAndKeepsPauseUntilFixed() public {
        _grantPauseRoles();
        bytes32 target = bytes32(uint256(uint160(address(quote))));
        uint256 id = _pause(PauseScope.TOKEN, target, PauseMode.ALL);
        vm.mockCall(address(quote), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(TSVRegistryV1.PermissionedMetadataMismatch.selector);
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.activePauseCount(uint8(PauseScope.TOKEN), target, uint8(PauseMode.ALL)), 1);
        _assertOperationGates(false, false);
        vm.clearMockedCalls();
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.getQuoteToken(address(quote)).rawDecimals, 6);
        assertTrue(registry.getQuoteToken(address(quote)).registered);
        _assertOperationGates(true, true);
    }

    function testFuzzStockRecoveryRejectsInvalidPolicyAndKeepsPause(uint8 fault) public {
        fault = uint8(bound(fault, 0, 5));
        _grantPauseRoles();
        bytes32 target = _pauseTarget(PauseScope.TOKEN);
        uint256 id = _pause(PauseScope.TOKEN, target, PauseMode.ALL);
        if (fault == 0) {
            registry.setPermissionedOwnerApproval(address(this), false);
        } else if (fault == 1) {
            stock.updateAllowedWrapper(address(permissionedRouterFixture), false);
        } else if (fault == 2) {
            stock.updateAllowedHook(IHooks(address(this)), false);
        } else if (fault == 3) {
            vm.mockCall(address(stock), abi.encodeWithSignature("PERMISSIONED_TOKEN()"), abi.encode(address(quote)));
        } else if (fault == 4) {
            vm.mockCall(address(stockToken), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        } else {
            vm.mockCall(address(stockAdapter), abi.encodeWithSignature("poolCurrency()"), abi.encode(address(quote)));
        }
        vm.expectRevert();
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.activePauseCount(uint8(PauseScope.TOKEN), target, uint8(PauseMode.ALL)), 1);
        assertEq(registry.getCurrency(address(stock)).underlying, address(stockToken));
        _assertOperationGates(false, false);
        vm.clearMockedCalls();
        if (fault == 0) registry.setPermissionedOwnerApproval(address(this), true);
        else if (fault == 1) stock.updateAllowedWrapper(address(permissionedRouterFixture), true);
        else if (fault == 2) stock.updateAllowedHook(IHooks(address(this)), true);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
    }
}
