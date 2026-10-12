// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1PermissionedComponent} from "../../../helpers/v1/PermissionedMocks.sol";
import {OperationsSbt, OperationsPausedOnlySbt, OperationsVerifyOnlySbt} from "../../../helpers/v1/OperationsMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TSVPermissionedEnvironmentTest is FoundationFixture {
    function _fresh() private returns (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) {
        r = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        h = new V1PermissionedComponent(address(manager), address(r), address(permissionsFactory));
        lp = new V1PermissionedComponent(address(manager), address(r), address(permissionsFactory));
    }

    function testBindingIsAtomicAndOnlyOnceAndUsesRealFactory() public {
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) = _fresh();
        vm.expectEmit(true, true, true, true, address(r));
        emit TSVRegistryV1.ComponentsBound(
            address(h), address(lp), address(permissionsFactory), address(manager), address(identitySbt)
        );
        vm.recordLogs();
        r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(r.permissionsAdapterFactory(), address(permissionsFactory));
        assertEq(r.permissionedPoolManager(), address(manager));
        assertEq(address(r.participantSbt()), address(identitySbt));
        assertEq(r.sbtTokenIds().length, 0);
        assertTrue(address(r) != r.permissionsAdapterFactory());
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
        r.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        r.setSbtConfig(7, PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        assertEq(address(r.participantSbt()), address(identitySbt));
    }

    function testInvalidSbtLeavesAllComponentsUnbound() public {
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) = _fresh();
        OperationsSbt unavailable = new OperationsSbt();
        unavailable.setFailVerify(true);
        address[6] memory bad = [
            address(0),
            makeAddr("no-code-sbt"),
            address(quote),
            address(new OperationsPausedOnlySbt()),
            address(new OperationsVerifyOnlySbt()),
            address(unavailable)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            r.bindComponents(address(h), address(lp), address(permissionsFactory), bad[i]);
            assertEq(r.hook(), address(0));
            assertEq(r.permissionsAdapterFactory(), address(0));
            assertEq(address(r.participantSbt()), address(0));
        }
    }

    function testMalformedSbtViewsRejectBindingAndPausedSbtMayBeBound() public {
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) = _fresh();
        bytes4[2] memory selectors = [ISmartWalletSbtV1.paused.selector, ISmartWalletSbtV1.verify.selector];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(address(identitySbt), abi.encodeWithSelector(selectors[i]), hex"01");
            vm.expectRevert();
            r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
            assertEq(r.hook(), address(0));
            assertEq(r.permissionsAdapterFactory(), address(0));
            assertEq(address(r.participantSbt()), address(0));
            vm.clearMockedCalls();
        }
        identitySbt.setPaused(true);
        r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
        r.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        identitySbt.setCredential(address(this), 7, true);
        assertFalse(r.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, address(this)));
        assertTrue(r.hasCredential(address(this)));
    }

    function testFactoryPoolManagerMustHaveCodeAndFailureIsAtomic() public {
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) = _fresh();
        address[2] memory badManagers = [address(0), makeAddr("no-code-manager")];
        for (uint256 i; i < badManagers.length; ++i) {
            vm.mockCall(
                address(permissionsFactory), abi.encodeWithSignature("POOL_MANAGER()"), abi.encode(badManagers[i])
            );
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
            assertEq(r.hook(), address(0));
            assertEq(r.permissionsAdapterFactory(), address(0));
            assertEq(r.permissionedPoolManager(), address(0));
            assertEq(address(r.participantSbt()), address(0));
            vm.clearMockedCalls();
        }
    }

    function testGovernorOnlyEnvironmentSettings() public {
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp) = _fresh();
        address stranger = makeAddr("not-governor");
        bytes memory errorData =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0));
        vm.expectRevert(errorData);
        vm.prank(stranger);
        r.bindComponents(address(h), address(lp), address(permissionsFactory), address(identitySbt));
        vm.expectRevert(errorData);
        vm.prank(stranger);
        registry.setTierPolicy(2, 1, bytes32("TEST"));
    }
}
