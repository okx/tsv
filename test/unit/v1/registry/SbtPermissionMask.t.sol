// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PermissionFlag, PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev Models an already registered identity containing a mask accepted by the old implementation.
contract LegacySbtMaskRegistryHarness is TSVRegistryV1 {
    function seedLegacyMask(uint256 tokenId, PermissionFlag permissions) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(sbtIdentityConfig[tokenId].registered);
        sbtIdentityConfig[tokenId].permissions = permissions;
    }
}

contract TSVSbtPermissionMaskTest is FoundationFixture {
    function testAllSupportedMasksCanBeConfiguredAndRemoved() public {
        address holder = makeAddr("mask-holder");
        identitySbt.setCredential(holder, 7, true);
        for (uint16 raw; raw <= 3; ++raw) {
            PermissionFlag mask = PermissionFlag.wrap(bytes2(raw));
            vm.expectEmit(true, true, false, true, address(registry));
            emit TSVRegistryV1.SbtConfigChanged(address(identitySbt), 7, mask, bytes32("TEST"));
            registry.setSbtConfig(7, mask, bytes32("TEST"));
            (bool registered, PermissionFlag stored) = registry.sbtIdentityConfig(7);
            assertEq(registered, raw != 0);
            assertEq(PermissionFlag.unwrap(stored), bytes2(raw));
            assertEq(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, holder), (raw & 1) != 0);
            assertEq(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, holder), (raw & 2) != 0);
        }
        registry.setSbtConfig(7, PermissionFlags.NONE, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, 0);
        assertFalse(registry.hasCredential(holder));
    }

    function testEveryUnsupportedBitIsRejectedEvenAlongsideSupportedPermissions() public {
        for (uint16 bit = 2; bit < 16; ++bit) {
            PermissionFlag mask = PermissionFlag.wrap(bytes2(uint16((1 << bit) | 3)));
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.setSbtConfig(7, mask, bytes32("TEST"));
        }
        assertEq(registry.sbtTokenIds().length, 0);
    }

    function testFuzzInvalidMaskCannotRegisterIdentity(uint16 raw) public {
        vm.assume((raw & uint16(0xFFFC)) != 0);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlag.wrap(bytes2(raw)), bytes32("TEST"));
        (bool registered, PermissionFlag stored) = registry.sbtIdentityConfig(7);
        assertFalse(registered);
        assertEq(PermissionFlag.unwrap(stored), bytes2(0));
        assertEq(registry.sbtTokenIds().length, 0);
    }

    function testFuzzInvalidMaskCannotChangeExistingIdentity(uint16 raw) public {
        vm.assume((raw & uint16(0xFFFC)) != 0);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlag.wrap(bytes2(raw)), bytes32("TEST"));
        (bool registered, PermissionFlag stored) = registry.sbtIdentityConfig(7);
        assertTrue(registered);
        assertEq(PermissionFlag.unwrap(stored), PermissionFlag.unwrap(PermissionFlags.SWAP_ALLOWED));
        assertEq(registry.sbtTokenIds().length, 1);
    }

    function testLegacyMaskSurvivesUpgradeAndCanBeExplicitlyCorrected() public {
        _seedLegacyAllMask();
        registry.upgradeToAndCall(address(new TSVRegistryV1()), "");
        (, PermissionFlag legacyMask) = registry.sbtIdentityConfig(7);
        assertEq(PermissionFlag.unwrap(legacyMask), bytes2(0xFFFF));

        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        (, PermissionFlag corrected) = registry.sbtIdentityConfig(7);
        assertEq(PermissionFlag.unwrap(corrected), bytes2(0x0003));
        assertEq(registry.sbtTokenIds().length, 1);
    }

    function testLegacyMaskCanBeRemovedWithNone() public {
        _seedLegacyAllMask();
        registry.upgradeToAndCall(address(new TSVRegistryV1()), "");
        registry.setSbtConfig(7, PermissionFlags.NONE, bytes32("TEST"));
        (bool registered, PermissionFlag stored) = registry.sbtIdentityConfig(7);
        assertFalse(registered);
        assertEq(PermissionFlag.unwrap(stored), bytes2(0));
        assertEq(registry.sbtTokenIds().length, 0);
    }

    function _seedLegacyAllMask() private {
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        registry.upgradeToAndCall(address(new LegacySbtMaskRegistryHarness()), "");
        LegacySbtMaskRegistryHarness(address(registry)).seedLegacyMask(7, PermissionFlags.ALL_ALLOWED);
    }
}
