// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag, PermissionFlags} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {OperationsSbt} from "../../../helpers/v1/OperationsMocks.sol";

contract TSVOperationsConfigurationTest is FoundationFixture {
    function testTierPolicyBoundsCapacityAndEvents() public {
        bytes32 beforeState = keccak256(abi.encode(registry.getTierPolicy(1)));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(0, 10, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 0, bytes32("TEST"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 10, bytes32(0));
        assertEq(keccak256(abi.encode(registry.getTierPolicy(1))), beforeState);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.TierPolicyChanged(1, 1, bytes32("TEST"));
        registry.setTierPolicy(1, 1, bytes32("TEST"));
        assertEq(registry.getTierPolicy(1).listedCount, 1);
        registry.setTierPolicy(2, 0, bytes32("TEST"));
        assertEq(registry.getTierPolicy(2).maxListed, 0);
    }

    function testSbtMustBeConfiguredAndCredentialIsSeparateFromPermissionsAndPause() public {
        address owner = makeAddr("credential-owner");
        TSVRegistryV1 unbound = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        unbound.hasCredential(owner);
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        unbound.permissionsOf(owner);
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        unbound.hasIdentity(owner, 7);
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        unbound.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        assertFalse(registry.hasCredential(owner));
        assertEq(PermissionFlag.unwrap(registry.permissionsOf(owner)), PermissionFlag.unwrap(PermissionFlags.NONE));
        OperationsSbt credential = identitySbt;
        credential.setCredential(owner, 7, true);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        assertTrue(registry.hasCredential(owner));
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        assertFalse(registry.hasCredential(makeAddr("nonholder")));
        credential.setPaused(true);
        assertTrue(registry.hasCredential(owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        credential.setPaused(false);
        registry.setSbtConfig(7, PermissionFlags.NONE, bytes32("TEST"));
        assertFalse(registry.hasCredential(owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
    }

    function testInvalidIdentityRegistrationAndUpdateAreAtomic() public {
        OperationsSbt good = identitySbt;
        good.setFailVerify(true);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        assertEq(address(registry.participantSbt()), address(good));
        assertEq(registry.sbtTokenIds().length, 0);
        good.setFailVerify(false);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        good.setFailVerify(true);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        _assertConfig(7, true, true);
        assertEq(address(registry.participantSbt()), address(good));
        assertEq(registry.sbtTokenIds().length, 1);
        // Removal does not depend on a live SBT verification call.
        registry.setSbtConfig(7, PermissionFlags.NONE, bytes32("TEST"));
        (bool removedRegistered,) = registry.sbtIdentityConfig(7);
        assertFalse(removedRegistered);
        assertEq(registry.sbtTokenIds().length, 0);
    }

    function testSbtConfigurationAndUpdateEventsWithMalformedReadsAtomic() public {
        OperationsSbt credential = identitySbt;
        bytes[3] memory malformed = [bytes(hex""), bytes(hex"01"), abi.encode(uint256(2))];
        for (uint256 i; i < malformed.length; ++i) {
            vm.mockCall(address(credential), abi.encodeWithSelector(ISmartWalletSbtV1.verify.selector), malformed[i]);
            vm.expectRevert();
            registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
            assertEq(address(registry.participantSbt()), address(credential));
            assertEq(registry.sbtTokenIds().length, 0);
            vm.clearMockedCalls();
        }
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SbtConfigChanged(address(credential), 7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        credential.setPaused(true);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SbtConfigChanged(address(credential), 7, PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        registry.setSbtConfig(7, PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        _assertConfig(7, false, true);
        assertEq(registry.sbtTokenIds().length, 1);
    }

    function testAdditionalIdentityValidationAndReadFailuresDoNotMeanRevocation() public {
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        bytes memory makerConfigCall = abi.encodeCall(ISmartWalletSbtV1.verify, (address(registry), 8));
        vm.mockCallRevert(address(credential), makerConfigCall, "marketmaker unavailable");
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(8, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, 1);
        vm.clearMockedCalls();
        registry.setSbtConfig(8, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        address owner = makeAddr("holder");
        credential.setCredential(owner, 7, true);
        for (uint256 id = 7; id <= 8; ++id) {
            vm.mockCallRevert(address(credential), abi.encodeCall(ISmartWalletSbtV1.verify, (owner, id)), "unavailable");
            vm.expectRevert();
            registry.hasCredential(owner);
            vm.expectRevert();
            registry.permissionsOf(owner);
            vm.clearMockedCalls();
        }
    }

    function testIdentityQueriesRecognizeOnlyRegisteredIdsAndWorkWhilePaused() public {
        address owner = makeAddr("holder");
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.hasIdentity(owner, 7);
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        registry.setSbtConfig(8, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        credential.setCredential(owner, 7, true);
        credential.setCredential(owner, 99, true);
        credential.setPaused(true);
        assertTrue(registry.hasIdentity(owner, 7));
        assertFalse(registry.hasIdentity(owner, 8));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.hasIdentity(owner, 99);
        credential.setCredential(owner, 7, false);
        assertFalse(registry.hasCredential(owner));
    }

    function testPermissionUpdatesAndNONERemovalApplyToHoldersWithoutDuplicateIds() public {
        address owner = makeAddr("holder");
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        registry.setSbtConfig(8, PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        credential.setCredential(owner, 7, true);
        credential.setCredential(owner, 8, true);
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertTrue(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        registry.setSbtConfig(7, PermissionFlags.NONE, bytes32("TEST"));
        (bool removedRegistered,) = registry.sbtIdentityConfig(7);
        assertFalse(removedRegistered);
        assertEq(registry.sbtTokenIds().length, 1);
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertTrue(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        registry.setSbtConfig(8, PermissionFlags.NONE, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, 0);
        assertFalse(registry.hasCredential(owner));
        assertFalse(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED, bytes32("TEST"));
        (bool reRegistered,) = registry.sbtIdentityConfig(7);
        assertTrue(reRegistered);
        assertTrue(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner));
        assertTrue(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner));
        uint256[] memory ids = registry.sbtTokenIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], 7);
    }

    function testSbtIdentityRegistrationHasHardCapAndNONEFreesRegistrationSlot() public {
        uint256 cap = registry.MAX_SBT_IDENTITIES();
        for (uint256 tokenId; tokenId < cap; ++tokenId) {
            registry.setSbtConfig(tokenId, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        }
        assertEq(registry.sbtTokenIds().length, cap);

        // NONE removes the identity from both the permission set and registered-ID list.
        registry.setSbtConfig(0, PermissionFlags.NONE, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, cap - 1);
        registry.setSbtConfig(cap, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, cap);

        // Re-registering a removed ID consumes a free slot and remains bounded.
        registry.setSbtConfig(1, PermissionFlags.NONE, bytes32("TEST"));
        registry.setSbtConfig(0, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, cap);
        vm.expectRevert(TSVRegistryV1.SbtIdentityLimitReached.selector);
        registry.setSbtConfig(cap + 1, PermissionFlags.SWAP_ALLOWED, bytes32("TEST"));
    }

    function testUnrelatedPermissionBitsCannotBeConfiguredOrRequested() public {
        address holder = makeAddr("unwind-only-holder");
        identitySbt.setCredential(holder, 7, true);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlags.UNWIND_ALLOWED, bytes32("TEST"));
        assertFalse(registry.hasCredential(holder));
        assertFalse(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, holder));
        assertFalse(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, holder));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.isSbtAllowed(PermissionFlags.UNWIND_ALLOWED, holder);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(7, PermissionFlags.ALL_ALLOWED, bytes32("TEST"));
        assertEq(registry.sbtTokenIds().length, 0);
    }

    function testFuzzHeldIdentityPermissionsAreUnion(uint8 first, uint8 second, uint8 holders, bool paused) public {
        first &= 3;
        second &= 3;
        holders &= 3;
        address owner = makeAddr("holder");
        OperationsSbt credential = identitySbt;
        registry.setSbtConfig(0, PermissionFlag.wrap(bytes2(uint16(first))), bytes32("TEST"));
        registry.setSbtConfig(8, PermissionFlag.wrap(bytes2(uint16(second))), bytes32("TEST"));
        credential.setCredential(owner, 0, holders & 1 != 0);
        credential.setCredential(owner, 8, holders & 2 != 0);
        credential.setPaused(paused);
        uint8 expected = paused ? 0 : ((holders & 1 != 0 ? first : 0) | (holders & 2 != 0 ? second : 0));
        bool expectedHeld = (holders & 1 != 0 && first != 0) || (holders & 2 != 0 && second != 0);
        assertEq(registry.hasCredential(owner), expectedHeld);
        assertEq(registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, owner), expected & 1 != 0);
        assertEq(registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, owner), expected & 2 != 0);
        assertEq(PermissionFlag.unwrap(registry.permissionsOf(owner)), bytes2(uint16(expected)));
    }

    function _assertConfig(uint256 tokenId, bool swap, bool liquidity) private view {
        (bool registered, PermissionFlag permissions) = registry.sbtIdentityConfig(tokenId);
        assertTrue(registered);
        uint16 mask = (swap ? 1 : 0) | (liquidity ? 2 : 0);
        assertEq(PermissionFlag.unwrap(permissions), bytes2(mask));
    }

    function testQuoteBadDecimalsAndMetadataRemainAbsent() public {
        V1MockToken token = new V1MockToken("new-quote", 6);
        vm.mockCall(address(token), abi.encodeWithSelector(V1MockToken.decimals.selector), abi.encode(uint8(19)));
        vm.expectRevert(TSVRegistryV1.PermissionedMetadataMismatch.selector);
        registry.registerQuoteToken(address(token), bytes32("TEST"));
        assertFalse(registry.getQuoteToken(address(token)).registered);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(token), abi.encodeWithSelector(V1MockToken.decimals.selector), "metadata unavailable");
        vm.expectRevert(TSVRegistryV1.PermissionedMetadataMismatch.selector);
        registry.registerQuoteToken(address(token), bytes32("TEST"));
        vm.clearMockedCalls();
        registry.registerQuoteToken(address(token), bytes32("TEST"));
        assertEq(registry.getQuoteToken(address(token)).rawDecimals, 6);
    }
}
