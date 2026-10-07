// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVTradingHookCallbacksTest is ProtocolFixture {
    function testSwapHooksRequireManagerRouterAndEmptyHookData() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, 4295128740);
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeSwap(address(router), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterSwap(address(router), key, p, BalanceDelta.wrap(0), "");
        for (uint8 i; i < 2; i++) {
            address sender = i == 0 ? alice : address(router);
            bytes memory data = i == 0 ? bytes("") : bytes(hex"01");
            vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
            vm.prank(address(manager));
            hook.beforeSwap(sender, key, p, data);
            vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
            vm.prank(address(manager));
            hook.afterSwap(sender, key, p, BalanceDelta.wrap(0), data);
        }
    }

    function testBeforeSwapReturnsZeroHookDeltaAndFeeOverride() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(router), key, IPoolManager.SwapParams(true, -1, 4295128740), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function testDonateCallbacksAreUnsupported() public {
        vm.expectRevert(TSVHookV1.UnsupportedCallback.selector);
        hook.beforeDonate(address(router), key, 1, 1, "");
        vm.expectRevert(TSVHookV1.UnsupportedCallback.selector);
        hook.afterDonate(address(router), key, 1, 1, "");
    }
}
