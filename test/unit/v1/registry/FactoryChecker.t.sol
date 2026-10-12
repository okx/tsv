// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC20 as PermissionedIERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {OperationsSbt} from "../../../helpers/v1/OperationsMocks.sol";
import {V1IssuerAllowlistChecker} from "../../../helpers/v1/PermissionedMocks.sol";

/// @dev Real issuer Factory/W remain independent of Registry's TSV identity policy.
contract TSVFactoryCheckerTest is FoundationFixture {
    function testRegistryDoesNotImplementIssuerCheckerOrFactory() public view {
        assertFalse(registry.supportsInterface(type(IAllowlistChecker).interfaceId));
        assertFalse(registry.supportsInterface(type(IPermissionsAdapterFactory).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(registry.supportsInterface(0x01ffc9a7));
        (bool checker,) = address(registry)
            .staticcall(abi.encodeWithSignature("checkAllowlist(address,address)", address(this), address(stockToken)));
        (bool factory,) = address(registry).staticcall(abi.encodeWithSignature("POOL_MANAGER()"));
        assertFalse(checker);
        assertFalse(factory);
    }

    function testUnboundEnvironmentRejectsAssetAdmission() public {
        TSVRegistryV1 empty = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        assertEq(empty.permissionsAdapterFactory(), address(0));
        empty.grantRole(empty.SYMBOL_ADMIN_ROLE(), address(this));
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.registerQuoteToken(address(quote), bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.registerPermissionedCurrency(_config(address(stock), SECURITY, address(stockAdapter)), 1, bytes32("TEST"));
    }

    function testRealFactoryCreationAndVerificationDoNotGrantTSVAdmission() public {
        V1IssuerAllowlistChecker checker = new V1IssuerAllowlistChecker();
        address caller = makeAddr("issuer-factory-caller");
        vm.prank(caller);
        address w = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), checker
        );
        assertEq(address(PermissionsAdapter(w).allowListChecker()), address(checker));
        assertEq(permissionsFactory.permissionsAdapterOf(w), address(stockToken));
        assertEq(permissionsFactory.verifiedPermissionsAdapterOf(w), address(0));
        stockToken.mintTestShares(w, 1);
        vm.prank(caller);
        permissionsFactory.verifyPermissionsAdapter(w);
        assertEq(permissionsFactory.verifiedPermissionsAdapterOf(w), address(stockToken));
        assertEq(registry.getCurrencyUnderlying(w), address(0));
        PermissionsAdapter(w).updateAllowedWrapper(address(permissionedRouterFixture), true);
        PermissionsAdapter(w).updateAllowedHook(key.hooks, true);
        registry.registerPermissionedCurrency(_config(w, SECURITY, address(stockAdapter)), 1, bytes32("TEST"));
        assertEq(registry.getCurrencyUnderlying(w), address(stockToken));
    }

    function testForeignFactoryAdapterIsNotAdmitted() public {
        PermissionsAdapterFactory foreign = new PermissionsAdapterFactory(address(manager));
        address w =
            foreign.createPermissionsAdapter(PermissionedIERC20(address(stockToken)), address(this), issuerChecker);
        stockToken.mintTestShares(w, 1);
        foreign.verifyPermissionsAdapter(w);
        vm.expectRevert(abi.encodeWithSelector(TSVRegistryV1.UnverifiedPermissionedAdapter.selector, w));
        registry.registerPermissionedCurrency(_config(w, SECURITY, address(stockAdapter)), 1, bytes32("TEST"));
    }

    function testIssuerPolicyDoesNotReadTSVSbtOrPause() public {
        address user = makeAddr("identity-user");
        assertTrue(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, user));
        credential.setCredential(user, 7, true);
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, user));
        issuerChecker.setPermissions(user, address(stockToken), PermissionFlags.LIQUIDITY_ALLOWED);
        assertFalse(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, user));
        assertEq(PermissionFlag.unwrap(registry.permissionsOf(user)), bytes2(uint16(3)));
        issuerChecker.setPermissions(user, address(stockToken), PermissionFlags.SWAP_ALLOWED);
        credential.setPaused(true);
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, user));
        assertTrue(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        credential.setFailVerify(true);
        assertTrue(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
    }

    function testIssuerOwnerCanReplaceItsCheckerWithoutChangingTSVSbt() public {
        address user = makeAddr("issuer-user");
        V1IssuerAllowlistChecker next = new V1IssuerAllowlistChecker();
        next.setPermissions(user, address(stockToken), PermissionFlags.NONE);
        stock.updateAllowListChecker(next);
        assertEq(address(stock.allowListChecker()), address(next));
        assertFalse(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        assertEq(address(registry.participantSbt()), address(identitySbt));
        assertEq(registry.getCurrencyUnderlying(address(stock)), address(stockToken));
        vm.expectRevert();
        stock.updateAllowListChecker(IAllowlistChecker(address(registry)));
    }

    function testIdentityGateRejectsInvalidFlagsAndDoesNotReadIssuerChecker() public {
        uint16[4] memory invalidFlags = [uint16(0), 3, 4, type(uint16).max];
        for (uint256 i; i < invalidFlags.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.isSbtAllowed(PermissionFlag.wrap(bytes2(invalidFlags[i])), address(this));
        }
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        credential.setCredential(address(this), 7, true);
        issuerChecker.setFailReads(true);
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, address(this)));
        vm.expectRevert("issuer checker unavailable");
        stock.isAllowed(address(this), PermissionFlags.SWAP_ALLOWED);
        credential.setCredential(address(this), 7, false);
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, address(this)));
    }

    function testFuzzIssuerAndTSVPermissionsAreIndependent(uint8 issuerMask, uint8 tsvMask, bool held, bool paused)
        public
    {
        issuerMask &= 3;
        tsvMask &= 3;
        address user = makeAddr("permission-user");
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlag.wrap(bytes2(uint16(tsvMask))), bytes32("TEST"));
        credential.setCredential(user, 7, held);
        credential.setPaused(paused);
        issuerChecker.setPermissions(user, address(stockToken), PermissionFlag.wrap(bytes2(uint16(issuerMask))));
        assertEq(uint16(PermissionFlag.unwrap(registry.permissionsOf(user))), held && !paused ? tsvMask : 0);
        assertEq(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED), issuerMask & 1 != 0);
        assertEq(stock.isAllowed(user, PermissionFlags.LIQUIDITY_ALLOWED), issuerMask & 2 != 0);
        assertEq(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, user), held && !paused && tsvMask & 1 != 0);
        assertEq(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, user), held && !paused && tsvMask & 2 != 0);
    }
}
