// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SwapRequest, LPBounds, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "./ProtocolFixture.sol";

/// @dev Stateful real-V4 fixture with independent position, quota, and daily volume models.
///      Each failed external operation must preserve the full relevant state digest.
contract TradingLPHandler is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    struct ModelPosition {
        address owner;
        uint128 liquidity;
        bool active;
    }
    mapping(uint256 => ModelPosition) public modelPositions;
    mapping(uint32 => uint256) public expectedUsed;
    mapping(uint32 => uint256) public modelCap;
    address public bob;
    uint256 public modelNextId = 2;
    uint32 public dayIndex;
    uint256 public multiplier = 1e18;
    bool public hasSbt = true;
    bool public sbtPaused;
    PauseMode public pauseMode;
    uint256 private pauseId;
    uint64 private quotaSequence;
    uint256 public successfulSwaps;
    uint256 public successfulLPChanges;
    uint256 public rejectedOperations;

    constructor() {
        setUp();
        bob = makeAddr("stateful-bob");
        sbt.setHolder(bob, true);
        stock.mintTestShares(bob, 1e24);
        quote.mint(bob, 1e24);
        vm.startPrank(bob);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        vm.stopPrank();
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        modelPositions[1] = ModelPosition(alice, 1e20, true);
    }

    function swap(uint256 seed, bool stockInput, bool exactInput, bool badSlippage) external {
        uint128 amount = uint128(bound(seed, 1e12, 1e15));
        bool direction = stockInput == (address(stock) == Currency.unwrap(key.currency0));
        SwapRequest memory request = _swapRequest(direction, amount);
        request.limitAmount = badSlippage ? (exactInput ? type(uint128).max : 1) : (exactInput ? 1 : 1e19);
        address trader = seed % 2 == 0 ? alice : bob;
        uint32 day = DAY + dayIndex;
        uint256 cap = modelCap[day] == 0 ? 1e24 : modelCap[day];
        bool allowed = hasSbt && !sbtPaused && pauseMode != PauseMode.TRADE && pauseMode != PauseMode.ALL
            && multiplier != 0 && !badSlippage && cap - (expectedUsed[day] < cap ? expectedUsed[day] : cap) > 1e18;
        bytes32 beforeState = _fullDigest();
        uint256 stockBefore = stock.balanceOf(trader);
        vm.prank(trader);
        (bool ok, bytes memory result) = address(router)
            .call(
                exactInput
                    ? abi.encodeCall(TSVSwapRouterV1.swapExactInput, (request))
                    : abi.encodeCall(TSVSwapRouterV1.swapExactOutput, (request))
            );
        assertEq(ok, allowed, "swap disagrees with independent policy model");
        if (!ok) {
            _assertRollback(beforeState);
            return;
        }
        (uint256 actualIn, uint256 actualOut) = abi.decode(result, (uint256, uint256));
        uint256 rawStock = stockInput ? stockBefore - stock.balanceOf(trader) : stock.balanceOf(trader) - stockBefore;
        assertEq(rawStock, stockInput ? actualIn : actualOut);
        if (!exactInput) assertEq(actualOut, amount);
        // Independent integer formula; never asks the legal-share Adapter for its expected output.
        expectedUsed[day] += rawStock * multiplier / 1e18;
        assertLe(expectedUsed[day], cap);
        successfulSwaps++;
    }

    function open(uint256 seed, bool badBounds) external {
        address owner = seed % 2 == 0 ? alice : bob;
        uint128 liquidity = uint128(bound(seed, 1e16, 1e18));
        LPBounds memory b = _pauseTestBounds();
        if (badBounds) {
            b.maxPoolIn0 = 0;
            b.maxPoolIn1 = 0;
        }
        bool allowed = _lpAllowed() && !badBounds;
        bytes32 beforeState = _fullDigest();
        vm.prank(owner);
        (bool ok, bytes memory result) =
            address(lpManager).call(abi.encodeCall(TSVLPManagerV1.openPosition, (key, -600, 600, liquidity, b)));
        assertEq(ok, allowed, "open disagrees with policy model");
        if (!ok) {
            _assertRollback(beforeState);
            return;
        }
        uint256 id = abi.decode(result, (uint256));
        assertEq(id, modelNextId++);
        modelPositions[id] = ModelPosition(owner, liquidity, true);
        successfulLPChanges++;
    }

    function change(uint256 seed, bool increase, bool wrongOwner) external {
        uint256 id = 1 + seed % (modelNextId - 1);
        ModelPosition storage p = modelPositions[id];
        address owner = wrongOwner ? (p.owner == alice ? bob : alice) : p.owner;
        uint128 amount = increase ? uint128(1e16) : p.liquidity / 10;
        bool allowed = p.active && !wrongOwner && _lpAllowed() && (increase || amount > 0);
        bytes32 beforeState = _fullDigest();
        vm.prank(owner);
        (bool ok,) = address(lpManager)
            .call(
                increase
                    ? abi.encodeCall(TSVLPManagerV1.increaseLiquidity, (id, amount, _pauseTestBounds()))
                    : abi.encodeCall(TSVLPManagerV1.decreaseLiquidity, (id, amount, _pauseTestBounds()))
            );
        assertEq(ok, allowed, "liquidity change disagrees with model");
        if (!ok) {
            _assertRollback(beforeState);
            return;
        }
        p.liquidity = increase ? p.liquidity + amount : p.liquidity - amount;
        successfulLPChanges++;
    }

    function collect(uint256 seed) external {
        uint256 id = 1 + seed % (modelNextId - 1);
        ModelPosition memory p = modelPositions[id];
        bytes32 beforeState = _fullDigest();
        vm.prank(p.owner);
        (bool ok, bytes memory errorData) =
            address(lpManager).call(abi.encodeCall(TSVLPManagerV1.collectFees, (id, _pauseTestBounds())));
        if (!ok) {
            if (p.active && _lpAllowed()) assertEq(bytes4(errorData), TSVLPManagerV1.NoFees.selector);
            _assertRollback(beforeState);
        } else {
            assertTrue(p.active && _lpAllowed());
            successfulLPChanges++;
        }
    }

    function close(uint256 seed, bool forced) external {
        // Keep the baseline position liquid so successful swaps remain predictable.
        if (modelNextId == 2) return;
        uint256 id = 2 + seed % (modelNextId - 2);
        ModelPosition storage p = modelPositions[id];
        bool allowed = p.active && (forced || _lpAllowed());
        bytes32 beforeState = _fullDigest();
        if (!forced) vm.prank(p.owner);
        (bool ok,) = address(lpManager)
            .call(
                forced
                    ? abi.encodeCall(
                        TSVLPManagerV1.forceExit, (id, 0, 0, keccak256("model-exit"), keccak256("evidence"))
                    )
                    : abi.encodeCall(TSVLPManagerV1.closePosition, (id, _pauseTestBounds()))
            );
        assertEq(ok, allowed, "close disagrees with model");
        if (!ok) {
            _assertRollback(beforeState);
            return;
        }
        p.liquidity = 0;
        p.active = false;
        successfulLPChanges++;
    }

    function credential(bool held, bool paused_) external {
        hasSbt = held;
        sbtPaused = paused_;
        sbt.setHolder(alice, held);
        sbt.setHolder(bob, held);
        sbt.setPaused(paused_);
    }

    function pause(uint8 seed) external {
        if (pauseId != 0) registry.clearEmergencyPause(pauseId, keccak256("model-resume"));
        pauseMode = PauseMode(seed % 4);
        pauseId = pauseMode == PauseMode.NONE ? 0 : _pauseLocal(PauseScope.GLOBAL, 0, pauseMode);
    }

    function conversion(uint256 seed) external {
        multiplier = seed % 5 == 0 ? 0 : bound(seed, 5e17, 2e18);
        stockUnderlying.setMultiplier(multiplier, seed);
    }

    function quota(bool restrictive, bool clear) external {
        uint32 day = DAY + dayIndex;
        uint256 used_ = expectedUsed[day];
        uint256 cap = restrictive ? (used_ < 2 ? 1 : used_ / 2) : 1e24;
        bool hasOverride = ledger.quotaOf(SECURITY, day).active;
        if (clear && !hasOverride) return;
        uint64 version = ledger.quotaOf(SECURITY, day).version + 1;
        quotaSequence++;
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                day,
                clear ? uint8(2) : uint8(1),
                clear ? 0 : cap,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 100),
                version,
                quotaSequence,
                keccak256(abi.encode("stateful-quota", quotaSequence)),
                keccak256("source")
            )
        );
        modelCap[day] = clear ? 1e24 : cap;
    }

    function advanceDay(uint8 seed) external {
        dayIndex += uint32(seed % 2);
        if (dayIndex > 6) dayIndex = 6;
        vm.warp(1_790_827_201 + uint256(dayIndex) * 86_400);
    }

    function assertModel() external view {
        uint256 aliceReceipts;
        uint256 bobReceipts;
        for (uint256 id = 1; id < modelNextId; id++) {
            ModelPosition memory expected = modelPositions[id];
            TSVLPManagerV1.Position memory p = lpManager.getPosition(id);
            assertEq(p.owner, expected.owner);
            assertEq(p.active, expected.active);
            assertEq(p.liquidity, expected.liquidity);
            assertEq(p.salt, bytes32(id));
            bytes32 positionKey = keccak256(abi.encodePacked(address(lpManager), int24(-600), int24(600), bytes32(id)));
            assertEq(StateLibrary.getPositionLiquidity(manager, key.toId(), positionKey), expected.liquidity);
            if (expected.active) {
                assertEq(lpManager.ownerOf(id), expected.owner);
                if (expected.owner == alice) aliceReceipts++;
                else bobReceipts++;
            }
        }
        assertEq(lpManager.balanceOf(alice), aliceReceipts);
        assertEq(lpManager.balanceOf(bob), bobReceipts);
        assertEq(lpManager.nextPositionId(), modelNextId);
        for (uint32 i; i <= 6; i++) {
            assertEq(ledger.used(SECURITY, DAY + i), expectedUsed[DAY + i]);
        }
        assertEq(stock.balanceOf(alice) + stock.balanceOf(bob) + stock.balanceOf(address(manager)), 2e24);
        assertEq(quote.balanceOf(alice) + quote.balanceOf(bob) + quote.balanceOf(address(manager)), 2e24);
        assertEq(stock.balanceOf(address(router)) + stock.balanceOf(address(lpManager)), 0);
        assertEq(quote.balanceOf(address(router)) + quote.balanceOf(address(lpManager)), 0);
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(manager), 0);
        assertFalse(TransientStateLibrary.isUnlocked(manager));
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(router), key.currency1), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(lpManager), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(lpManager), key.currency1), 0);
    }

    function _lpAllowed() private view returns (bool) {
        return hasSbt && !sbtPaused && pauseMode != PauseMode.LP && pauseMode != PauseMode.ALL;
    }

    function _fullDigest() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                _swapStateDigest(DAY + dayIndex),
                stock.balanceOf(bob),
                quote.balanceOf(bob),
                lpManager.nextPositionId(),
                lpManager.balanceOf(alice),
                lpManager.balanceOf(bob)
            )
        );
        for (uint256 id = 2; id < modelNextId; id++) {
            digest = keccak256(abi.encode(digest, lpManager.getPosition(id)));
        }
    }

    function _assertRollback(bytes32 beforeState) private {
        assertEq(_fullDigest(), beforeState, "failed operation changed protocol state");
        rejectedOperations++;
    }
}
