// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Faulty PoolManager deltas exercise defensive guards before any token settlement.
contract TSVSwapDeltaGuardsTest is ProtocolFixture {
    function testInvalidDeltaSignsRejectedInEitherDirection() public {
        int128[3] memory inputs = [int128(0), int128(1), int128(-1)];
        int128[3] memory outputs = [int128(1), int128(1), int128(0)];
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 d; d < 2; d++) {
            for (uint8 i; i < 3; i++) {
                BalanceDelta delta =
                    d == 0 ? toBalanceDelta(inputs[i], outputs[i]) : toBalanceDelta(outputs[i], inputs[i]);
                vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
                vm.expectRevert(TSVSwapRouterV1.SlippageExceeded.selector);
                vm.prank(alice);
                router.swapExactInput(_swapRequest(d == 0, 1e18));
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        vm.clearMockedCalls();
    }

    function testMinimumSignedInputDeltaRejectsBeforeNegationAndTransfers() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 d; d < 2; d++) {
            BalanceDelta delta = d == 0 ? toBalanceDelta(type(int128).min, 1) : toBalanceDelta(1, type(int128).min);
            vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
            vm.expectRevert(TSVSwapRouterV1.InputAmountTooLarge.selector);
            vm.prank(alice);
            router.swapExactInput(_swapRequest(d == 0, 1e18));
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        vm.clearMockedCalls();
    }
}
