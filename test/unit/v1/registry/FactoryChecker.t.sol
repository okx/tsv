// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {AssetStatus} from "tsv-v1/types/TSVTypes.sol";
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
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Real Factory exercises token metadata and balance callbacks under the shared Registry lock.
contract ReentrantMetadataToken is ERC20 {
    TSVRegistryV1 private immutable registry;
    bool public balanceProbe;

    constructor(TSVRegistryV1 r) ERC20("probe", "PROBE") {
        registry = r;
    }

    function mint(address to) external {
        _mint(to, 1);
    }

    function setBalanceProbe(bool enabled) external {
        balanceProbe = enabled;
    }

    function _assertLocked() private view {
        (bool ok, bytes memory result) =
            address(registry).staticcall(abi.encodeCall(TSVRegistryV1.verifyPermissionsAdapter, (address(this))));
        require(!ok && bytes4(result) == TSVRegistryV1.FactoryEntryReentrancy.selector, "verify lock missing");
        (ok, result) = address(registry)
            .staticcall(
                abi.encodeCall(
                    TSVRegistryV1.createPermissionsAdapter,
                    (PermissionedIERC20(address(this)), address(this), IAllowlistChecker(address(registry)))
                )
            );
        require(!ok && bytes4(result) == TSVRegistryV1.FactoryEntryReentrancy.selector, "create lock missing");
    }

    function name() public view override returns (string memory) {
        _assertLocked();
        return "probe";
    }

    function balanceOf(address a) public view override returns (uint256) {
        if (balanceProbe) _assertLocked();
        return super.balanceOf(a);
    }
}

contract TSVFactoryCheckerTest is FoundationFixture {
    function testUnboundQueriesAreEmptyAndMutationRejects() public {
        TSVRegistryV1 empty = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        assertEq(empty.POOL_MANAGER(), address(0));
        assertEq(empty.permissionsAdapterOf(address(stock)), address(0));
        assertEq(empty.verifiedPermissionsAdapterOf(address(stock)), address(0));
        assertEq(empty.permissionedAllowlistChecker(), address(empty));
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(empty))
        );
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.verifyPermissionsAdapter(address(stock));
        empty.grantRole(empty.SYMBOL_ADMIN_ROLE(), address(this));
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.registerQuoteToken(address(quote));
        vm.expectRevert(TSVRegistryV1.PermissionedEnvironmentNotBound.selector);
        empty.registerPermissionedCurrency(_config(address(stock), SECURITY, address(stockAdapter)));
    }

    function testFactoryForwardingIsPermissionlessAndPreservesOwnerAndEventEmitter() public {
        address caller = makeAddr("permissionless-caller");
        V1ConfigReceiver owner = new V1ConfigReceiver();
        vm.recordLogs();
        vm.prank(caller);
        address w = registry.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(owner), IAllowlistChecker(address(registry))
        );
        assertEq(PermissionsAdapter(w).owner(), address(owner));
        assertEq(registry.permissionsAdapterOf(w), address(stockToken));
        assertEq(registry.verifiedPermissionsAdapterOf(w), address(0));
        assertEq(PermissionsAdapter(w).POOL_MANAGER(), address(manager));
        assertEq(address(PermissionsAdapter(w).allowListChecker()), address(registry));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 created = keccak256("PermissionsAdapterCreated(address,address)");
        uint256 count;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == created) {
                assertEq(entries[i].emitter, address(permissionsFactory));
                ++count;
            }
        }
        assertEq(count, 1);
        stockToken.mintTestShares(w, 1);
        vm.prank(caller);
        registry.verifyPermissionsAdapter(w);
        assertEq(registry.verifiedPermissionsAdapterOf(w), address(stockToken));
        assertEq(registry.getCurrency(w).underlying, address(0));
        assertFalse(isApprovedOwner(address(owner)));
        PermissionsAdapterFactory foreign = new PermissionsAdapterFactory(address(manager));
        address foreignW = foreign.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(owner), IAllowlistChecker(address(registry))
        );
        assertEq(registry.permissionsAdapterOf(foreignW), address(0));
    }

    function isApprovedOwner(address owner) private view returns (bool) {
        return registry.isPermissionedOwnerApproved(owner);
    }

    function testVerificationErrorsBubbleAndDoNotLeaveLock() public {
        address missing = makeAddr("missing");
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapterFactory.PermissionsAdapterNotFound.selector, missing));
        registry.verifyPermissionsAdapter(missing);
        address w = registry.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(registry))
        );
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapterFactory.PermissionsAdapterNotVerified.selector, w));
        registry.verifyPermissionsAdapter(w);
        stockToken.mintTestShares(w, 1);
        registry.verifyPermissionsAdapter(w);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapterFactory.PermissionsAdapterAlreadyVerified.selector, w)
        );
        registry.verifyPermissionsAdapter(w);
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(this))
        );
        registry.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), IAllowlistChecker(address(registry))
        );
        // The real Factory can create a valid W with a different checker; TSV must still reject it.
        IAllowlistChecker otherChecker = IAllowlistChecker(address(new TSVRegistryV1()));
        address wrongCheckerW = permissionsFactory.createPermissionsAdapter(
            PermissionedIERC20(address(stockToken)), address(this), otherChecker
        );
        stockToken.mintTestShares(wrongCheckerW, 1);
        permissionsFactory.verifyPermissionsAdapter(wrongCheckerW);
        assertEq(registry.verifiedPermissionsAdapterOf(wrongCheckerW), address(stockToken));
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(_config(wrongCheckerW, SECURITY, address(stockAdapter)));
    }

    function testRealFactoryCallbacksObserveSharedCreateVerifyLock() public {
        ReentrantMetadataToken token = new ReentrantMetadataToken(registry);
        address w = registry.createPermissionsAdapter(
            PermissionedIERC20(address(token)), address(this), IAllowlistChecker(address(registry))
        );
        token.mint(w);
        token.setBalanceProbe(true);
        registry.verifyPermissionsAdapter(w);
        assertEq(registry.verifiedPermissionsAdapterOf(w), address(token));
        token.setBalanceProbe(false);
        registry.createPermissionsAdapter(
            PermissionedIERC20(address(token)), address(this), IAllowlistChecker(address(registry))
        );
    }

    function testProxySupportsInterfacesWithinERC165Budget() public view {
        bytes4[4] memory ids = [
            type(IAllowlistChecker).interfaceId,
            type(IPermissionsAdapterFactory).interfaceId,
            type(IAccessControl).interfaceId,
            bytes4(0x01ffc9a7)
        ];
        for (uint256 i; i < ids.length; ++i) {
            (bool ok, bytes memory result) =
                address(registry).staticcall{gas: 30_000}(abi.encodeWithSignature("supportsInterface(bytes4)", ids[i]));
            assertTrue(ok);
            assertTrue(abi.decode(result, (bool)));
        }
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    function testCheckerUsesWrapperIdentityAndSbtFailClosed() public {
        address user = makeAddr("credential-user");
        assertFalse(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        OperationsSbt credential = new OperationsSbt();
        credential.setCredential(user, 7, true);
        registry.setSbtConfig(address(credential), 7);
        assertTrue(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));
        address[5] memory callers =
            [user, address(manager), address(permissionedRouterFixture), address(permissionsFactory), address(quote)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            assertEq(PermissionFlag.unwrap(registry.checkAllowlist(user, address(stockToken))), bytes2(0));
        }
        vm.prank(address(stock));
        assertEq(PermissionFlag.unwrap(registry.checkAllowlist(user, address(quote))), bytes2(0));
        credential.setPaused(true);
        assertFalse(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        assertTrue(registry.hasCredential(user));
        credential.setPaused(false);
        credential.setFailVerify(true);
        vm.expectRevert();
        stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED);
        credential.setFailVerify(false);
        address w2 = _prepareCurrency(address(stockToken), SECURITY, address(stockAdapter)).currency;
        registry.registerPermissionedCurrency(_config(w2, SECURITY, address(stockAdapter)));
        registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
        assertFalse(stock.isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        assertTrue(PermissionsAdapter(w2).isAllowed(user, PermissionFlags.SWAP_ALLOWED));
        registry.disablePool(poolId);
        registry.delistSecurity(SECURITY);
        assertFalse(PermissionsAdapter(w2).isAllowed(user, PermissionFlags.SWAP_ALLOWED));
    }
}
