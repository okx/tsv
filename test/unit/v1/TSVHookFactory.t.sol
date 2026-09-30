// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";

contract TSVHookFactoryTest is Test {
    function testMinedProxyHasV4PermissionsAndStableImplementationGetter() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        TSVBusinessAuthority authority = new TSVBusinessAuthority(address(this), address(0xA11CE));
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(authority),
                address(0xA11CE),
                address(0xCAFE),
                address(this),
                address(this),
                address(this),
                address(0xBEEF),
                address(0xF00D)
            )
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(address(implementation), initData, salt);
            if ((uint160(predicted) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predicted) & 0x3FFF, 0x3FFF);
        address proxy = factory.deploy(address(implementation), initData, salt);
        assertEq(proxy, predicted);
        assertEq(TSVERC1967Proxy(payable(proxy)).tsvImplementation(), address(implementation));
        assertEq(address(TSVHookV1(proxy).businessAuthority()), address(authority));
        vm.expectRevert();
        factory.deploy(address(implementation), initData, salt);
    }

    function testWrongPermissionSaltReverts() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (address(1), address(2), address(3), address(4), address(5), address(6), address(7), address(8))
        );
        bytes32 salt;
        while ((uint160(factory.predict(address(implementation), initData, salt)) & 0x3FFF) == 0x3FFF) {
            salt = bytes32(uint256(salt) + 1);
        }
        vm.expectRevert(TSVHookProxyFactoryV1.InvalidHookAddress.selector);
        factory.deploy(address(implementation), initData, salt);
    }
}
