// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1PermissionedComponent, V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TSVPermissionedEnvironmentTest is FoundationFixture {
    function _fresh()
        private
        returns (
            TSVRegistryV1 r,
            V1PermissionedComponent h,
            V1PermissionedComponent lp,
            V1PermissionedComponent router_
        )
    {
        r = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        h = new V1PermissionedComponent(address(manager), address(r));
        lp = new V1PermissionedComponent(address(manager), address(r));
        router_ = new V1PermissionedComponent(address(manager), address(r));
        h.setLinks(address(router_), address(lp), address(ledger));
        r.bindComponents(address(h), address(lp), address(inbox));
    }

    function testBindingIsAtomicAndOnlyOnceAndDistinguishesRealFactoryFromInterface() public {
        (TSVRegistryV1 r,,, V1PermissionedComponent router_) = _fresh();
        vm.expectEmit(true, true, true, true, address(r));
        emit TSVRegistryV1.PermissionedComponentsBound(address(permissionsFactory), address(manager), address(router_));
        r.bindPermissionedComponents(address(permissionsFactory), address(router_));
        assertEq(r.permissionsAdapterFactory(), address(permissionsFactory));
        assertEq(r.POOL_MANAGER(), address(manager));
        assertEq(r.permissionedRouter(), address(router_));
        assertEq(router_.PERMISSIONS_ADAPTER_FACTORY(), address(r));
        assertTrue(address(r) != r.permissionsAdapterFactory());
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        r.bindPermissionedComponents(address(permissionsFactory), address(router_));
    }

    function testFuzzMismatchedComponentsLeaveEnvironmentUnbound(uint8 fault) public {
        fault = uint8(bound(fault, 0, 11));
        (TSVRegistryV1 r, V1PermissionedComponent h, V1PermissionedComponent lp, V1PermissionedComponent router_) =
            _fresh();
        address factory = address(permissionsFactory);
        if (fault == 0) {
            factory = address(0);
        } else if (fault == 1) {
            factory = address(r);
        } else if (fault == 2) {
            factory = address(new PermissionsAdapterFactory(address(0)));
        } else if (fault == 3) {
            vm.mockCall(address(router_), abi.encodeWithSignature("poolManager()"), abi.encode(address(stock)));
        } else if (fault == 4) {
            vm.mockCall(address(router_), abi.encodeWithSignature("registry()"), abi.encode(address(registry)));
        } else if (fault == 5) {
            vm.mockCall(address(h), abi.encodeWithSignature("poolManager()"), abi.encode(address(stock)));
        } else if (fault == 6) {
            vm.mockCall(address(lp), abi.encodeWithSignature("poolManager()"), abi.encode(address(stock)));
        } else if (fault == 7) {
            vm.mockCall(address(h), abi.encodeWithSignature("registry()"), abi.encode(address(registry)));
        } else if (fault == 8) {
            vm.mockCall(address(lp), abi.encodeWithSignature("registry()"), abi.encode(address(registry)));
        } else if (fault == 9) {
            vm.mockCall(address(router_), abi.encodeWithSignature("PERMISSIONS_ADAPTER_FACTORY()"), abi.encode(factory));
        } else if (fault == 10) {
            h.setLinks(address(stock), address(lp), address(ledger));
        } else {
            h.setLinks(address(router_), address(stock), address(ledger));
        }
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        r.bindPermissionedComponents(factory, address(router_));
        assertEq(r.permissionsAdapterFactory(), address(0));
        assertEq(r.permissionedPoolManager(), address(0));
        assertEq(r.permissionedRouter(), address(0));
    }

    function testGovernorOnlyEnvironmentOwnerAndExitAdminSettings() public {
        (TSVRegistryV1 r,,, V1PermissionedComponent router_) = _fresh();
        address stranger = makeAddr("not-governor");
        bytes memory errorData =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0));
        vm.expectRevert(errorData);
        vm.prank(stranger);
        r.bindPermissionedComponents(address(permissionsFactory), address(router_));
        vm.expectRevert(errorData);
        vm.prank(stranger);
        registry.setPermissionedOwnerApproval(address(this), false);
        V1ConfigReceiver receiver = new V1ConfigReceiver();
        vm.expectRevert(errorData);
        vm.prank(stranger);
        registry.setExitAdmin(address(stock), address(receiver));
    }

    function testCandidateExitAdminIsSeparateFromAdmissionAndForbiddenAssets() public {
        address w = _newStockConfig(SECURITY).currency;
        assertEq(registry.getCurrency(w).underlying, address(0));
        assertEq(registry.exitAdminVersion(w), 1);
        address[6] memory bad =
            [address(stockToken), address(stock), address(manager), address(registry), address(this), address(quote)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(TSVRegistryV1.PermissionedPolicyMismatch.selector);
            registry.setExitAdmin(w, bad[i]);
        }
        assertEq(registry.exitAdminVersion(w), 1);
        assertEq(registry.exitAdminOf(w), address(exitReceiver));
    }
}
