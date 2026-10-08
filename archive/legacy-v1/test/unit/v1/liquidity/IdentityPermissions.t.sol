// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds, PermissionedCurrencyConfig} from "tsv-v1/types/TSVTypes.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {V1LocalERC20} from "../../../helpers/v1/LocalMocks.sol";
import {OperationsSbt} from "../../../helpers/v1/OperationsMocks.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {V1PermissionedComponent} from "../../../helpers/v1/PermissionedMocks.sol";

/// @dev Identity/exit tests use real LP, Registry, PM and direct ERC20 settlement on a hookless pool.
///      Pool admission, W classification and issuer responses are mocked; SBT checks remain real.
///      This does not validate production Wrapped LP.
contract TSVLPIdentityPermissionsTest is Test {
    using PoolIdLibrary for PoolKey;

    TSVRegistryV1 private registry;
    TSVLPManagerV1 private lp;
    OperationsSbt private sbt;
    V1LocalERC20 private token0;
    V1LocalERC20 private token1;
    PoolKey private key;
    address private alice;

    function setUp() public {
        alice = makeAddr("lp-owner");
        TSVGovernanceAnchor anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        PoolManager manager = new PoolManager(address(this));
        lp = TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVLPManagerV1()),
                    abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), address(manager), address(registry)))
                )
            )
        );
        sbt = new OperationsSbt();
        PermissionsAdapterFactory factory = new PermissionsAdapterFactory(address(manager));
        V1PermissionedComponent hook =
            new V1PermissionedComponent(address(manager), address(registry), address(factory));
        V1PermissionedComponent router =
            new V1PermissionedComponent(address(manager), address(registry), address(factory));
        hook.setLinks(address(router), address(lp), address(this));
        registry.bindComponents(address(hook), address(lp), address(this), address(factory), address(sbt));
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
        registry.setSbtConfig(8, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
        sbt.setCredential(alice, 7, true);
        lp.grantRole(lp.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        token0 = new V1LocalERC20("LP0");
        token1 = new V1LocalERC20("LP1");
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        _mockAdmissionAndIssuer();
        token0.mint(alice, 1e24);
        token1.mint(alice, 1e24);
        vm.startPrank(alice);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzzEitherIdentityAllowsOrdinaryLPLifecycle(bool marketmaker) public {
        sbt.setCredential(alice, 7, !marketmaker);
        sbt.setCredential(alice, 8, marketmaker);
        uint256 id = _open();
        vm.startPrank(alice);
        lp.increaseLiquidity(id, 1e18, _bounds());
        lp.decreaseLiquidity(id, 1e18, _bounds());
        vm.expectRevert(TSVLPManagerV1.NoFees.selector);
        lp.collectFees(id, _bounds());
        lp.closePosition(id, _bounds());
        vm.stopPrank();
        assertFalse(lp.getPosition(id).active);
        vm.expectRevert();
        lp.ownerOf(id);
    }

    function testPartialRevocationPreservesLPAndBlocksRevokeExitForEitherRemainingIdentity() public {
        uint256 id = _open();
        sbt.setCredential(alice, 8, true);
        for (uint256 remaining = 7; remaining <= 8; ++remaining) {
            sbt.setCredential(alice, 7, remaining == 7);
            sbt.setCredential(alice, 8, remaining == 8);
            vm.prank(alice);
            lp.increaseLiquidity(id, 1e18, _bounds());
            vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
            lp.forceExit(id, 0, 0, keccak256("partial-revocation"));
            assertEq(lp.ownerOf(id), alice);
        }
    }

    function testAllIdentitiesRevokedBlocksEveryOrdinaryOperationAndAllowsExitToOwner() public {
        uint256 id = _open();
        sbt.setCredential(alice, 7, false);
        sbt.setCredential(alice, 99, true); // An unrelated SBT grants no operation or exit protection.
        vm.startPrank(alice);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.openPosition(key, -600, 600, 1e18, _bounds());
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.increaseLiquidity(id, 1e18, _bounds());
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.decreaseLiquidity(id, 1e18, _bounds());
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.collectFees(id, _bounds());
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.closePosition(id, _bounds());
        vm.stopPrank();
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lp.forceExit(id, 0, 0, keccak256("unauthorized"));
        vm.mockCall(
            address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (PoolId.unwrap(key.toId()))), abi.encode(false)
        );
        _assertExitToOwner(id);
    }

    function testPauseAloneDoesNotAllowRevokeExitButDoesNotBlockAlreadyRevokedExit() public {
        uint256 id = _open();
        sbt.setPaused(true);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.forceExit(id, 0, 0, keccak256("paused"));
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lp.closePosition(id, _bounds());
        sbt.setCredential(alice, 7, false);
        _assertExitToOwner(id);
    }

    function testEitherIdentityReadFailureBlocksRevokeExit() public {
        uint256 id = _open();
        sbt.setCredential(alice, 7, false);
        for (uint256 tokenId = 7; tokenId <= 8; ++tokenId) {
            vm.mockCallRevert(address(sbt), abi.encodeCall(ISmartWalletSbtV1.verify, (alice, tokenId)), "unavailable");
            vm.expectRevert(bytes("unavailable"));
            lp.forceExit(id, 0, 0, keccak256("read-failed"));
            assertTrue(lp.getPosition(id).active);
            assertEq(lp.ownerOf(id), alice);
            vm.clearMockedCalls();
            _mockAdmissionAndIssuer();
        }
    }

    function testAdminExitRemainsIndependentOfIdentityAndReadFailures() public {
        uint256 id = _open();
        lp.grantRole(lp.FORCE_EXIT_ADMIN_ROLE(), address(this));
        sbt.setFailVerify(true);
        _assertExitToOwner(id);
    }

    function testPermissionUpdatesBlockLPButHeldSwapOnlyIdentityStillBlocksRevokeExit() public {
        uint256 id = _open();
        registry.setSbtConfig(7, PermissionFlags.SWAP_ALLOWED);
        assertTrue(registry.isAllowed(PermissionFlags.SWAP_ALLOWED, alice));
        assertFalse(registry.isAllowed(PermissionFlags.LIQUIDITY_ALLOWED, alice));
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lp.increaseLiquidity(id, 1e18, _bounds());
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.forceExit(id, 0, 0, keccak256("swap-only"));
        registry.setSbtConfig(7, PermissionFlags.NONE);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lp.forceExit(id, 0, 0, keccak256("no-operation-permissions"));
        registry.setSbtConfig(7, PermissionFlags.LIQUIDITY_ALLOWED);
        vm.prank(alice);
        lp.increaseLiquidity(id, 1e18, _bounds());
        sbt.setCredential(alice, 7, false);
        _assertExitToOwner(id);
    }

    function testOrdinaryLPRequiresIssuerPermissionAsWellAsSbtPermission() public {
        // Settlement still uses real ERC20/PM; only the issuer response changes.
        bytes memory permissionCall =
            abi.encodeCall(IPermissionsAdapter.isAllowed, (alice, PermissionFlags.LIQUIDITY_ALLOWED));
        vm.mockCall(address(token0), permissionCall, abi.encode(false));
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        _open();
        assertEq(lp.nextPositionId(), 1);
        vm.mockCall(address(token0), permissionCall, abi.encode(true));
        uint256 id = _open();
        sbt.setCredential(alice, 7, false);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lp.increaseLiquidity(id, 1e18, _bounds());
        sbt.setCredential(alice, 8, true);
        vm.prank(alice);
        lp.increaseLiquidity(id, 1e18, _bounds());
        vm.mockCall(address(token0), permissionCall, abi.encode(false));
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lp.closePosition(id, _bounds());
        assertTrue(lp.getPosition(id).active);
        sbt.setCredential(alice, 8, false);
        _assertExitToOwner(id); // Revoke exit keeps its separate authorization and delivery rules.
    }

    function testRejectedDeliveryRollsBackForcedExitAndReceipt() public {
        uint256 id = _open();
        sbt.setCredential(alice, 7, false);
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);
        token1.setBlockedRecipient(alice);
        vm.expectRevert();
        lp.forceExit(id, 0, 0, keccak256("blocked-delivery"));
        assertTrue(lp.getPosition(id).active);
        assertEq(lp.ownerOf(id), alice);
        assertEq(token0.balanceOf(alice), before0);
        assertEq(token1.balanceOf(alice), before1);
        token1.setBlockedRecipient(address(0));
        _assertExitToOwner(id);
    }

    function _open() private returns (uint256 id) {
        vm.prank(alice);
        return lp.openPosition(key, -600, 600, 1e20, _bounds());
    }

    function _mockAdmissionAndIssuer() private {
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isLPAllowed, (poolId)), abi.encode(true));
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.isKnownPool, (poolId)), abi.encode(true));
        vm.mockCall(
            address(registry),
            abi.encodeCall(TSVRegistryV1.getCurrency, (address(token0))),
            abi.encode(PermissionedCurrencyConfig(address(token1), address(this)))
        );
        vm.mockCall(address(token0), abi.encodeWithSelector(IPermissionsAdapter.isAllowed.selector), abi.encode(true));
    }

    function _bounds() private view returns (LPBounds memory bounds) {
        bounds.maxPoolIn0 = type(uint256).max;
        bounds.maxPoolIn1 = type(uint256).max;
        bounds.deadline = uint64(block.timestamp);
    }

    function _assertExitToOwner(uint256 id) private {
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);
        lp.forceExit(id, 1, 1, keccak256("all-revoked"));
        assertGt(token0.balanceOf(alice), before0);
        assertGt(token1.balanceOf(alice), before1);
        assertEq(token0.balanceOf(address(this)), 0);
        assertEq(token1.balanceOf(address(this)), 0);
        assertFalse(lp.getPosition(id).active);
        vm.expectRevert();
        lp.ownerOf(id);
    }
}
