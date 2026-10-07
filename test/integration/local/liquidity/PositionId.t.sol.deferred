// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Verifies position identifiers and their V4 storage isolation against a real local PoolManager.
contract TSVPositionIdLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;

    function testPositionIdSameRangeKeepsV4PositionsSeparate() public {
        assertEq(positionId, 1);
        assertEq(lpManager.nextPositionId(), 2);

        vm.prank(alice);
        uint256 secondId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());

        assertEq(secondId, 2);
        assertEq(lpManager.nextPositionId(), 3);
        assertEq(lpManager.ownerOf(secondId), alice);
        assertEq(lpManager.getPosition(positionId).salt, bytes32(positionId));
        assertEq(lpManager.getPosition(secondId).salt, bytes32(secondId));
        assertEq(_v4Liquidity(positionId), 1e20);
        assertEq(_v4Liquidity(secondId), 1e18);

        vm.prank(alice);
        lpManager.increaseLiquidity(secondId, 1e18, _positionBounds());
        assertEq(_v4Liquidity(positionId), 1e20);
        assertEq(_v4Liquidity(secondId), 2e18);
        assertEq(lpManager.nextPositionId(), 3);
    }

    function testPositionIdCounterIsSharedAcrossUsersAndPools() public {
        address bob = makeAddr("position-id-bob");
        sbt.setHolder(bob, true);
        stock.mintTestShares(bob, 1e22);
        quote.mint(bob, 1e22);
        vm.startPrank(bob);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        uint256 bobId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        vm.stopPrank();

        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        lpManager.initializePool(otherPool, uint160(1 << 96));
        vm.prank(alice);
        uint256 otherPoolId = lpManager.openPosition(otherPool, -600, 600, 1e18, _positionBounds());

        assertEq(bobId, 2);
        assertEq(otherPoolId, 3);
        assertEq(lpManager.nextPositionId(), 4);
        assertEq(lpManager.ownerOf(bobId), bob);
        assertEq(lpManager.ownerOf(otherPoolId), alice);
        assertEq(_v4Liquidity(positionId), 1e20);
        assertEq(_v4Liquidity(bobId), 1e18);
        assertEq(_v4Liquidity(otherPoolId), 1e18);
    }

    function testPositionIdClosedIdIsNotReused() public {
        vm.prank(alice);
        lpManager.closePosition(positionId, _positionBounds());

        assertEq(lpManager.nextPositionId(), 2);
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(_v4Liquidity(positionId), 0);
        vm.expectRevert();
        lpManager.ownerOf(positionId);
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _positionBounds());

        vm.prank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(newId, 2);
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(_v4Liquidity(positionId), 0);
        assertEq(_v4Liquidity(newId), 1e18);
    }

    function testPositionIdForcedExitIdIsNotReused() public {
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("position-id-revoke"));
        assertEq(lpManager.nextPositionId(), 2);
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(_v4Liquidity(positionId), 0);

        sbt.setHolder(alice, true);
        vm.prank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(newId, 2);
        assertEq(_v4Liquidity(newId), 1e18);
    }

    function testPositionIdFailedOpenRollsBackCounterAndV4State() public {
        uint256 expectedId = lpManager.nextPositionId();
        LPBounds memory bounds = _positionBounds();
        bounds.maxPoolIn0 = 0;
        bounds.maxPoolIn1 = 0;
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.openPosition(key, -600, 600, 1e18, bounds);

        assertEq(lpManager.nextPositionId(), expectedId);
        assertEq(lpManager.getPosition(expectedId).owner, address(0));
        assertFalse(lpManager.getPosition(expectedId).active);
        assertEq(_v4Liquidity(positionId), 1e20);
        bytes32 failedKey = Position.calculatePositionKey(address(lpManager), -600, 600, bytes32(expectedId));
        assertEq(StateLibrary.getPositionLiquidity(IPoolManager(address(manager)), key.toId(), failedKey), 0);
        vm.expectRevert();
        lpManager.ownerOf(expectedId);

        vm.prank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(newId, expectedId);
        assertEq(lpManager.nextPositionId(), expectedId + 1);
        assertEq(_v4Liquidity(newId), 1e18);
    }

    function testPositionIdCounterOverflowRevertsInsteadOfWrapping() public {
        stdstore.target(address(lpManager)).sig("nextPositionId()").checked_write(type(uint256).max - 1);
        vm.prank(alice);
        uint256 lastId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(lastId, type(uint256).max - 1);
        assertEq(lpManager.getPosition(lastId).salt, bytes32(lastId));
        assertEq(lpManager.nextPositionId(), type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(lpManager.nextPositionId(), type(uint256).max);
        assertFalse(lpManager.getPosition(type(uint256).max).active);
        assertFalse(lpManager.getPosition(0).active);
        assertEq(_v4Liquidity(positionId), 1e20);
        assertEq(_v4Liquidity(lastId), 1e18);
    }

    function testPositionIdCompatibleUpgradePreservesCounterAndBlocksReinitialization() public {
        TSVLPManagerV1 replacement = new TSVLPManagerV1();
        address anchor = address(lpManager.governanceAnchor());
        lpManager.upgradeToAndCall(address(replacement), bytes(""));

        assertEq(lpManager.nextPositionId(), 2);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(lpManager.getPosition(positionId).salt, bytes32(positionId));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        lpManager.initialize(anchor, address(manager), address(registry));
        assertEq(lpManager.nextPositionId(), 2);

        vm.prank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, _positionBounds());
        assertEq(newId, 2);
        assertEq(_v4Liquidity(positionId), 1e20);
        assertEq(_v4Liquidity(newId), 1e18);
    }

    function testPositionIdSeparateManagerHasIndependentCounter() public {
        TSVLPManagerV1 separateManager = TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVLPManagerV1()),
                    abi.encodeCall(
                        TSVLPManagerV1.initialize,
                        (address(lpManager.governanceAnchor()), address(manager), address(registry))
                    )
                )
            )
        );
        assertEq(separateManager.nextPositionId(), 1);
        assertEq(lpManager.nextPositionId(), 2);
        assertTrue(address(separateManager) != address(lpManager));
        assertFalse(separateManager.getPosition(positionId).active);
    }

    function _positionBounds() private view returns (LPBounds memory bounds) {
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
    }

    function _v4Liquidity(uint256 id) private view returns (uint128 liquidity) {
        TSVLPManagerV1.Position memory p = lpManager.getPosition(id);
        (liquidity,,) = StateLibrary.getPositionInfo(
            IPoolManager(address(manager)), p.key.toId(), address(lpManager), p.tickLower, p.tickUpper, p.salt
        );
    }
}
