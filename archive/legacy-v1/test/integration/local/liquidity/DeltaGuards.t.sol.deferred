// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Defensive LP checks when an external PoolManager supplies invalid signed deltas.
contract TSVLPDeltaGuardsTest is ProtocolFixture {
    function testActiveCallbackRejectsTamperedRequestHashBeforePositionOrSettlementChanges() public {
        bytes memory originalCode = address(manager).code;
        bytes32 beforeState = _swapStateDigest(DAY);
        LPCallbackFaultManager faulty = new LPCallbackFaultManager();
        vm.etch(address(manager), address(faulty).code);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        vm.etch(address(manager), originalCode);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
    }

    function testSignedMinimumLiquidityInputRejectedBeforeSettlement() public {
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(type(int128).min, 0), BalanceDelta.wrap(0))
        );
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.InputAmountTooLarge.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
    }

    function testCollectAndForceExitCannotCreateNewOwnerDebt() public {
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-1, 1), BalanceDelta.wrap(0))
        );
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        sbt.setHolder(alice, false);
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
    }
}

/// @dev Negative-path dependency fixture; preserves the real manager's address as callback sender.
contract LPCallbackFaultManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return TSVLPManagerV1(msg.sender).unlockCallback(bytes.concat(data, hex"01"));
    }
}
