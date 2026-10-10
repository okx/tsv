// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {
    TSVLPManagerV1,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    IPermissionsAdapterFactory,
    Currency
} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {ITokenApproveProxy} from "tsv-v1/interfaces/ITokenApproveProxy.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IERC721Permit_v4} from "v4-periphery/interfaces/IERC721Permit_v4.sol";
import {PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {V1SwapToken} from "../../../helpers/v1/WrappedSwapMocks.sol";
import {V1IssuerAllowlistChecker} from "../../../helpers/v1/PermissionedMocks.sol";
import {LPLinkedDependencies} from "../../../helpers/v1/LPLinkedFixture.sol";

/// @dev Real PoolManager claims, factory verification and adapter unwrapping; Registry permission responses are mocked.
contract LPClaimWithdrawalTest is Test {
    PoolManager private manager;
    PermissionsAdapterFactory private factory;
    PermissionsAdapter private adapter;
    V1SwapToken private underlying;
    TSVLPManagerV1 private lp;
    address private registry;
    address private lpOwner;
    Currency private currency;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new PermissionsAdapterFactory(address(manager));
        underlying = new V1SwapToken("Stock", 18, address(0));
        adapter = PermissionsAdapter(
            factory.createPermissionsAdapter(
                IERC20(address(underlying)), address(this), IAllowlistChecker(address(new V1IssuerAllowlistChecker()))
            )
        );
        underlying.mint(address(adapter), 1);
        factory.verifyPermissionsAdapter(address(adapter));
        adapter.updateAllowedWrapper(address(this), true);
        currency = Currency.wrap(address(adapter));
        registry = makeAddr("registry");
        lpOwner = makeAddr("lp-owner");
        vm.etch(registry, hex"00");
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isPaused, ()), abi.encode(false));
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.isAllowed.selector), abi.encode(false));
        vm.mockCall(registry, abi.encodeWithSelector(ITSVPermissionedRegistry.hasRole.selector), abi.encode(false));
        LPLinkedDependencies deps = new LPLinkedDependencies();
        TSVLPManagerV1 implementation = new TSVLPManagerV1(
            IPoolManager(address(manager)),
            IAllowanceTransfer(address(deps)),
            200_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0)),
            IPermissionsAdapterFactory(address(factory)),
            500_000,
            ITSVPermissionedRegistry(registry),
            ITokenApproveProxy(address(deps))
        );
        lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(TSVLPManagerV1.initialize, (ITSVPermissionedRegistry(registry)))
                    )
                ))
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address holder, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(currency);
        underlying.mint(address(adapter), amount);
        adapter.wrapToPoolManager(amount);
        manager.settle();
        manager.mint(holder, currency.toId(), amount);
        return "";
    }

    function _seed(address holder, uint256 amount) private {
        manager.unlock(abi.encode(holder, amount));
        vm.prank(holder);
        manager.setOperator(address(lp), true);
    }

    function _allow(address account, bool allowed) private {
        vm.mockCall(
            registry,
            abi.encodeCall(ITSVPermissionedRegistry.isAllowed, (PermissionFlags.LIQUIDITY_ALLOWED, account)),
            abi.encode(allowed)
        );
    }

    function testAdapterOwnerRedeemsWithoutSbtAndReceivesUnderlying() public {
        _seed(address(this), 9);
        lp.withdrawClaim(currency, 9, address(1));
        assertEq(manager.balanceOf(address(this), currency.toId()), 0);
        assertEq(underlying.balanceOf(address(this)), 9);
        assertEq(adapter.balanceOf(address(this)), 0);
    }

    function testNonOwnerCannotBypassSbtEvenWithOwnClaim() public {
        _seed(lpOwner, 9);
        vm.prank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, lpOwner);
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
    }

    function _setForceExitAdmin(address account, bool enabled) private {
        vm.mockCall(
            registry,
            abi.encodeCall(ITSVPermissionedRegistry.hasRole, (lp.FORCE_EXIT_ADMIN_ROLE(), account)),
            abi.encode(enabled)
        );
    }

    function testForceExitAdminRedeemsOwnClaimWithoutSbt() public {
        _seed(lpOwner, 9);
        _setForceExitAdmin(lpOwner, true);
        vm.prank(lpOwner);
        lp.withdrawClaim(currency, 9, address(1));
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 0);
        assertEq(underlying.balanceOf(lpOwner), 9);
    }

    function testForceExitAdminCannotSendToThirdPartyOrManager() public {
        _seed(lpOwner, 9);
        _setForceExitAdmin(lpOwner, true);
        vm.startPrank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, address(this));
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, address(2));
        vm.stopPrank();
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
    }

    function testRevokedForceExitAdminCannotBypassSbt() public {
        _seed(lpOwner, 9);
        _setForceExitAdmin(lpOwner, true);
        _setForceExitAdmin(lpOwner, false);
        vm.prank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, lpOwner);
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
    }

    function testForceExitAdminCannotSpendAnotherHoldersClaim() public {
        _seed(address(this), 9);
        _setForceExitAdmin(lpOwner, true);
        vm.prank(lpOwner);
        manager.setOperator(address(lp), true);
        vm.prank(lpOwner);
        vm.expectRevert();
        lp.withdrawClaim(currency, 9, lpOwner);
        assertEq(manager.balanceOf(address(this), currency.toId()), 9);
        assertEq(underlying.balanceOf(lpOwner), 0);
    }

    function testForceExitAdminStillRequiresClaimApproval() public {
        _seed(lpOwner, 9);
        _setForceExitAdmin(lpOwner, true);
        vm.startPrank(lpOwner);
        manager.setOperator(address(lp), false);
        vm.expectRevert();
        lp.withdrawClaim(currency, 9, lpOwner);
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
        manager.approve(address(lp), currency.toId(), 9);
        lp.withdrawClaim(currency, 9, lpOwner);
        vm.stopPrank();
        assertEq(underlying.balanceOf(lpOwner), 9);
    }

    function testOwnerCannotSendToThirdPartyOrManager() public {
        _seed(address(this), 9);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(currency, 9, address(2));
        assertEq(manager.balanceOf(address(this), currency.toId()), 9);
    }

    function testUnverifiedAdapterAndOrdinaryCurrencyCannotUseOwnerPath() public {
        address unverified = factory.createPermissionsAdapter(
            IERC20(address(underlying)), address(this), IAllowlistChecker(address(new V1IssuerAllowlistChecker()))
        );
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(Currency.wrap(unverified), 0, address(this));
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaim(Currency.wrap(address(underlying)), 0, address(this));
    }

    function testClaimApprovalIsRequired() public {
        _seed(address(this), 9);
        manager.setOperator(address(lp), false);
        vm.expectRevert();
        lp.withdrawClaim(currency, 9, address(this));
        assertEq(manager.balanceOf(address(this), currency.toId()), 9);
        manager.approve(address(lp), currency.toId(), 9);
        lp.withdrawClaim(currency, 9, address(this));
        assertEq(manager.allowance(address(this), address(lp), currency.toId()), 0);
        assertEq(underlying.balanceOf(address(this)), 9);
    }

    function testOwnerCannotSpendAnotherHoldersClaim() public {
        _seed(lpOwner, 9);
        manager.setOperator(address(lp), true);
        vm.expectRevert();
        lp.withdrawClaim(currency, 9, address(this));
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
        assertEq(underlying.balanceOf(address(this)), 0);
    }

    function testUnderlyingRejectionRollsBackClaimBurn() public {
        _seed(address(this), 9);
        underlying.setBlockedRecipient(address(this));
        vm.expectRevert();
        lp.withdrawClaim(currency, 9, address(this));
        assertEq(manager.balanceOf(address(this), currency.toId()), 9);
        assertEq(adapter.balanceOf(address(manager)), 9);
        underlying.setBlockedRecipient(address(0));
        lp.withdrawClaim(currency, 9, address(this));
        assertEq(underlying.balanceOf(address(this)), 9);
    }

    function testLpPathRequiresCallerAndRecipientPermission() public {
        _seed(lpOwner, 9);
        _allow(address(this), true);
        vm.prank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaimByLp(currency, 9, address(this));
        _allow(lpOwner, true);
        _allow(address(this), false);
        vm.prank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaimByLp(currency, 9, address(this));
        assertEq(manager.balanceOf(lpOwner, currency.toId()), 9);
        _allow(address(this), true);
        vm.prank(lpOwner);
        lp.withdrawClaimByLp(currency, 9, address(this));
        assertEq(underlying.balanceOf(address(this)), 9);
    }

    function testOwnerWithdrawalDoesNotLeaveSbtBypassAuthorization() public {
        _seed(address(this), 1);
        _seed(lpOwner, 9);
        lp.withdrawClaim(currency, 1, address(this));
        vm.prank(lpOwner);
        vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
        lp.withdrawClaimByLp(currency, 9, lpOwner);
    }

    function testPausedRegistryBlocksBothPaths() public {
        _seed(address(this), 9);
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isPaused, ()), abi.encode(true));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.withdrawClaim(currency, 9, address(this));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.withdrawClaimByLp(currency, 9, address(this));
    }
}
