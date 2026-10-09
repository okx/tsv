// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

/// @dev Makes the Router's user identity observable during the initial SBT validation as well as payment.
contract V1ContextCredential {
    TSVSwapRouterV1 private immutable router;
    address private immutable user;

    constructor(TSVSwapRouterV1 router_, address user_) {
        router = router_;
        user = user_;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function verify(address account, uint256) external view returns (bool) {
        return account == user && router.msgSender() == account;
    }
}

contract TSVWrappedPolicyTest is WrappedSwapFixture {
    using PoolIdLibrary for PoolKey;

    function testUserIdentityIsAvailableFromFirstCredentialRead() public {
        vm.etch(address(sbt), address(new V1ContextCredential(router, alice)).code);
        _swap(true, true, 1e16);
        _swap(false, false, 1e16);
        assertEq(router.msgSender(), address(0));
    }

    function testBothIdentitiesAuthorizeBothSwapModesUntilAllAreRevoked() public {
        // Retail is issued in the fixture. Marketmaker alone must also authorize both swap directions.
        _swap(true, true, 1e16);
        _swap(false, false, 1e16);
        sbt.setHolder(alice, 2, true);
        sbt.setHolder(alice, 1, false);
        _swap(true, false, 1e16);
        _swap(false, true, 1e16);
        sbt.setHolder(alice, 1, true);
        sbt.setHolder(alice, 2, false);
        _swap(true, true, 1e16);
        sbt.setHolder(alice, 1, false);
        sbt.setHolder(alice, 99, true);
        bytes32 before_ = _digest();
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        _swap(true, true, 1e16);
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        _swap(false, false, 1e16);
        assertEq(_digest(), before_);
    }

    function testSwapRequiresSwapPermissionAndUpdatesApplyToExistingHolders() public {
        registry.setSbtConfig(1, PermissionFlags.LIQUIDITY_ALLOWED);
        assertTrue(registry.hasCredential(alice));
        assertTrue(registry.isAllowed(PermissionFlags.LIQUIDITY_ALLOWED, alice));
        bytes32 before_ = _digest();
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        _swap(true, true, 1e16);
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        _swap(false, false, 1e16);
        assertEq(_digest(), before_);
        registry.setSbtConfig(2, PermissionFlags.SWAP_ALLOWED);
        sbt.setHolder(alice, 2, true);
        _swap(true, true, 1e16);
        _swap(false, false, 1e16);
        registry.setSbtConfig(2, PermissionFlags.NONE);
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        _swap(true, true, 1e16);
        registry.setSbtConfig(1, PermissionFlags.SWAP_ALLOWED);
        _swap(false, true, 1e16);
        assertFalse(registry.isAllowed(PermissionFlags.LIQUIDITY_ALLOWED, alice));
    }

    function testOnlyTradingPauseBlocksSwapsAndPreservesAccounting() public {
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.LP, keccak256("pause-lp"));
        for (uint256 i; i < 4; ++i) {
            _swap(i < 2, i % 2 == 0, 1e16);
        }
        assertGt(ledger.used(SECURITY, DAY), 0);

        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.TRADE, keccak256("pause-trade"));
        bytes32 before_ = _digest();
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert();
            _swap(i < 2, i % 2 == 0, 1e16);
        }
        assertEq(_digest(), before_);
    }

    function testFuzzPolicyRevocationRejectsBeforeTransfer(uint8 fault) public {
        fault = uint8(bound(fault, 0, 10));
        if (fault == 0) {
            issuerChecker.setPermissions(alice, address(underlying), PermissionFlags.NONE);
        } else if (fault == 1) {
            stock.updateAllowedWrapper(address(router), false);
        } else if (fault == 2) {
            stock.updateAllowedHook(IHooks(address(hook)), false);
        } else if (fault == 3) {
            stock.updateSwappingEnabled(false);
        } else if (fault == 4) {
            registry.addEmergencyPause(
                PauseScope.TOKEN, bytes32(uint256(uint160(address(stock)))), PauseMode.ALL, keccak256("stop")
            );
        } else if (fault == 5) {
            registry.addEmergencyPause(
                PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.ALL, keccak256("stop")
            );
        } else if (fault == 6) {
            registry.addEmergencyPause(PauseScope.POOL, PoolId.unwrap(key.toId()), PauseMode.ALL, keccak256("stop"));
        } else if (fault == 7) {
            registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.TRADE, keccak256("stop"));
        } else if (fault == 8) {
            sbt.setPaused(true);
        } else if (fault == 9) {
            sbt.setFailReads(true, false);
        } else {
            issuer.setMultiplier(0, 1); // Positive raw must not produce zero legal shares.
        }
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }

    function testStockUserMustApproveRouterForUnderlying() public {
        vm.startPrank(alice);
        underlying.approve(address(router), 0);
        underlying.approve(address(stock), type(uint256).max);
        vm.stopPrank();
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
    }

    function testExitAdminNeverReceivesSwapOutputAndIssuerCanRejectUser() public {
        underlying.setBlockedRecipient(alice);
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(false, true, 1e16);
        assertEq(_digest(), before_);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
        underlying.setBlockedRecipient(address(0));
        _swap(false, true, 1e16);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
    }

    function testImmutableBindingsCheckedOnInitializeAndUpgrade() public {
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        new TSVSwapRouterV1(address(this), address(factory));
        PermissionsAdapterFactory otherPMFactory = new PermissionsAdapterFactory(address(this));
        TSVSwapRouterV1 mismatchedPM = new TSVSwapRouterV1(address(this), address(otherPMFactory));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        _proxy(
            address(mismatchedPM),
            abi.encodeCall(TSVSwapRouterV1.initialize, (address(anchor), address(manager), address(registry)))
        );
        PermissionsAdapterFactory otherFactory = new PermissionsAdapterFactory(address(manager));
        TSVSwapRouterV1 mismatchedFactory = new TSVSwapRouterV1(address(manager), address(otherFactory));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(mismatchedFactory), bytes(""));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(mismatchedPM), bytes(""));
        TSVSwapRouterV1 next = new TSVSwapRouterV1(address(manager), address(factory));
        router.upgradeToAndCall(address(next), bytes(""));
        assertEq(address(router.poolManager()), address(manager));
        assertEq(address(router.PERMISSIONS_ADAPTER_FACTORY()), address(factory));
        _swap(true, true, 1e16);
    }
}
