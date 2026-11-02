// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LPLinkedFixture,
    LPLinkedHarness,
    TSVLPManagerV1,
    ITSVPermissionedRegistry,
    IPoolManager,
    TSVERC1967Proxy
} from "../../../helpers/v1/LPLinkedFixture.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LPRegistryRolesTest is LPLinkedFixture {
    function _createRegistry() internal override returns (address) {
        return address(
            new TSVERC1967Proxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this))))
        );
    }

    function _grantForceExitRole() internal override {
        TSVRegistryV1(registry).grantRole(lp.FORCE_EXIT_ADMIN_ROLE(), address(this));
    }

    function testPoolCreatorGrantAndRevocationTakeEffectImmediately() public {
        bytes32 role = lp.POOL_CREATOR_ROLE();
        _expectMissingRole(address(this), role);
        lp.initializePool(key, uint160(1 << 96));

        TSVRegistryV1(registry).grantRole(role, address(this));
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.registerPool, (key)), abi.encode(bytes32(0)));
        vm.mockCall(
            address(manager), abi.encodeCall(IPoolManager.initialize, (key, uint160(1 << 96))), abi.encode(int24(0))
        );
        vm.expectCall(registry, abi.encodeCall(ITSVPermissionedRegistry.hasRole, (role, address(this))));
        assertEq(lp.initializePool(key, uint160(1 << 96)), 0);

        TSVRegistryV1(registry).revokeRole(role, address(this));
        _expectMissingRole(address(this), role);
        lp.initializePool(key, uint160(1 << 96));
    }

    function testForceExitGrantAndRevocationTakeEffectImmediately() public {
        bytes32 role = lp.FORCE_EXIT_ADMIN_ROLE();
        TSVRegistryV1(registry).revokeRole(role, address(this));
        _expectMissingRole(address(this), role);
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(lp.ownerOf(tokenId), owner);

        TSVRegistryV1(registry).grantRole(role, address(this));
        vm.expectCall(registry, abi.encodeCall(ITSVPermissionedRegistry.hasRole, (role, address(this))));
        lp.unwindPositionByTsv(tokenId, 0, 0, "");
        assertEq(lp.balanceOf(owner), 0);
    }

    function testUpgradeRequiresRegistryUpgradeRoleAndPreservesProxyState() public {
        LPLinkedHarness implementation = _newImplementation();
        bytes32 domain = lp.DOMAIN_SEPARATOR();
        vm.prank(owner);
        lp.approve(address(this), tokenId);
        vm.prank(owner);
        lp.revokeNonce(9);

        // A Registry business role does not authorize upgrades.
        TSVRegistryV1(registry).grantRole(lp.POOL_CREATOR_ROLE(), owner);
        vm.expectRevert(TSVLPManagerV1.UnauthorizedUpgrade.selector);
        vm.prank(owner);
        lp.upgradeToAndCall(address(implementation), "");

        vm.expectCall(
            registry, abi.encodeCall(ITSVPermissionedRegistry.hasRole, (lp.UPGRADE_ADMIN_ROLE(), address(this)))
        );
        lp.upgradeToAndCall(address(implementation), "");
        assertEq(_implementation(), address(implementation));
        assertEq(address(lp.registry()), registry);
        assertEq(lp.ownerOf(tokenId), owner);
        assertEq(lp.getApproved(tokenId), address(this));
        assertEq(lp.nonces(owner, 0), 1 << 9);
        assertEq(lp.nextTokenId(), tokenId + 1);
        assertEq(lp.DOMAIN_SEPARATOR(), domain);
    }

    function testUpgradeRoleGrantAndRevocationTakeEffectImmediately() public {
        address nextAdmin = makeAddr("next-upgrade-admin");
        bytes32 role = lp.UPGRADE_ADMIN_ROLE();
        TSVRegistryV1(registry).grantRole(role, nextAdmin);
        TSVRegistryV1(registry).revokeRole(role, address(this));
        LPLinkedHarness implementation = _newImplementation();
        vm.expectRevert(TSVLPManagerV1.UnauthorizedUpgrade.selector);
        lp.upgradeToAndCall(address(implementation), "");
        vm.prank(nextAdmin);
        lp.upgradeToAndCall(address(implementation), "");
        assertEq(_implementation(), address(implementation));
    }

    function testUpgradeStillRespectsRegistryPause() public {
        LPLinkedHarness implementation = _newImplementation();
        vm.mockCall(registry, abi.encodeCall(ITSVPermissionedRegistry.isPaused, ()), abi.encode(true));
        vm.expectRevert(TSVLPManagerV1.RegistryPaused.selector);
        lp.upgradeToAndCall(address(implementation), "");
    }

    function testInitializerAndUupsContextRemainProtected() public {
        LPLinkedHarness implementation = _newImplementation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(ITSVPermissionedRegistry(registry));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        lp.initialize(ITSVPermissionedRegistry(registry));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(implementation), "");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        lp.proxiableUUID();
    }

    function testLpDoesNotExposeLocalAccessControl() public {
        assertFalse(lp.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(lp.supportsInterface(0x80ac58cd)); // ERC-721
        bytes32 role = lp.POOL_CREATOR_ROLE();
        vm.expectRevert();
        IAccessControl(address(lp)).grantRole(role, owner);
    }

    function _newImplementation() private returns (LPLinkedHarness) {
        return new LPLinkedHarness(address(manager), factory, registry, address(deps));
    }

    function _implementation() private view returns (address) {
        return address(
            uint160(uint256(vm.load(address(lp), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))))
        );
    }

    function _expectMissingRole(address account, bytes32 role) private {
        vm.expectRevert(abi.encodeWithSelector(TSVLPManagerV1.AccessControlUnauthorizedAccount.selector, account, role));
    }
}
