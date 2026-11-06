// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev TSVBusinessRolesTest scenarios; inherited fixtures contain no test functions.
contract TSVBusinessRolesTest is FoundationFixture {
    function testDefaultAdminTransferChangesConfigurationAuthority() public {
        address next = makeAddr("new-admin");
        registry.grantRole(bytes32(0), next);
        registry.renounceRole(bytes32(0), address(this));
        assertFalse(registry.hasRole(bytes32(0), address(this)));
        assertTrue(registry.hasRole(bytes32(0), next));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        vm.prank(next);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
    }

    function testDefaultAdminCanBeRevokedAndRenounced() public {
        registry.grantRole(bytes32(0), council);
        registry.revokeRole(bytes32(0), council);
        assertFalse(registry.hasRole(bytes32(0), council));
        registry.renounceRole(bytes32(0), address(this));
        assertFalse(registry.hasRole(bytes32(0), address(this)));
        assertFalse(registry.hasRole(bytes32(0), address(0)));
    }

    function testBusinessRolesCanBeGrantedRevokedAndRenounced() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        assertTrue(registry.hasRole(role, council));
        registry.revokeRole(role, council);
        assertFalse(registry.hasRole(role, council));
        registry.grantRole(role, council);
        vm.prank(council);
        registry.renounceRole(role, council);
        assertFalse(registry.hasRole(role, council));
    }

    function testBusinessRoleRenunciationCannotRemoveSomeoneElse() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        vm.prank(guardian);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        registry.renounceRole(role, council);
        assertTrue(registry.hasRole(role, council));
    }

    function testOnlyDefaultAdminCanGrantOrRevokeBusinessRoles() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        registry.grantRole(role, council);
        for (uint256 i; i < callers.length; ++i) {
            bytes memory errorData = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], bytes32(0)
            );
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.grantRole(role, guardian);
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.revokeRole(role, council);
        }
        assertFalse(registry.hasRole(role, guardian));
        assertTrue(registry.hasRole(role, council));
    }

    function testAdminTransferMovesRoleManagementAndConfiguration() public {
        address next = makeAddr("new-governor");
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        registry.grantRole(bytes32(0), next);
        registry.renounceRole(bytes32(0), address(this));
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0));
        vm.expectRevert(denied);
        registry.grantRole(role, guardian);
        vm.expectRevert(denied);
        registry.revokeRole(role, council);
        vm.expectRevert(denied);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        vm.startPrank(next);
        registry.grantRole(role, guardian);
        registry.revokeRole(role, council);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        vm.stopPrank();
        assertTrue(registry.hasRole(role, guardian));
        assertFalse(registry.hasRole(role, council));
        // An explicitly granted business role survives admin transfer independently.
        assertTrue(registry.hasRole(role, address(this)));
        registry.setTierPolicy(2, 1, bytes32("TEST"));
        assertEq(registry.getTierPolicy(2).maxListed, 1);
    }
}
