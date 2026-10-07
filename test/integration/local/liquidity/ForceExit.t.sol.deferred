// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TokenStatus, MarketAction, PauseScope, PauseMode, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVForceExitLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVForceExitLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev Verifies force exit returns the original owner assets after SBT revocation.
    function testForceExitWhenSbtRevokedReturnsOriginalOwnerAssets() public {
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"));
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(quote.balanceOf(alice), quoteBefore);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        lpManager.ownerOf(positionId);
    }

    /// @dev Verifies a force-exit admin can act as revoke executor while the owner still holds an SBT.
    function testForceExitAdminCanActWhenAlsoRevokeExecutorAndOwnerStillHasSbt() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        assertTrue(registry.hasCredential(alice));
        lpManager.forceExit(positionId, 1, 1, keccak256("incident"));
        assertFalse(lpManager.getPosition(positionId).active);
    }

    /// @dev Verifies force exit by the original owner reverts atomically.
    function testForceExitRejectsOriginalOwnerRollsBackEverything() public {
        sbt.setHolder(alice, false);
        quote.setBlockedRecipient(alice);
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeQuote = quote.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        uint128 beforeLiquidity = lpManager.getPosition(positionId).liquidity;
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"));
        assertEq(stock.balanceOf(alice), beforeStock);
        assertEq(quote.balanceOf(alice), beforeQuote);
        assertEq(ledger.used(SECURITY, DAY), beforeUsed);
        assertEq(lpManager.getPosition(positionId).liquidity, beforeLiquidity);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    /// @dev Verifies an SBT pause blocks user swaps but allows force exit.
    function testSbtPauseBlocksUserSwapButNotForceExit() public {
        assertTrue(registry.isEligible(alice));
        sbt.setPaused(true);
        assertFalse(registry.isEligible(alice));
        vm.prank(alice);
        vm.expectRevert();
        router.swapExactInput(_swapRequest(true, 1e18));
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
    }

    /// @dev Verifies failed SBT reads are not treated as revocation.
    function testSbtReadFailuresDoNotBecomeRevocationSignals() public {
        sbt.setFailReads(true, false);
        vm.expectRevert();
        registry.hasCredential(alice);
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"));
        assertEq(lpManager.ownerOf(positionId), alice);

        sbt.setFailReads(false, true);
        vm.expectRevert();
        registry.isEligible(alice);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    /// @dev Verifies the Registry rejects an SBT that lacks required selectors.
    function testRegistryRejectsSbtWithoutRequiredSelectors() public {
        address oldSbt = address(registry.participantSbt());
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(quote), 1);
        assertEq(address(registry.participantSbt()), oldSbt);
        assertTrue(registry.isEligible(alice));
    }

    /// @dev Verifies force exit enforces both minimum outputs atomically.
    function testForceExitEnforcesBothMinimumOutputsAtomically() public {
        sbt.setHolder(alice, false);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, type(uint256).max, 0, keccak256("revoke"));

        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, 0, type(uint256).max, keccak256("revoke"));

        TSVLPManagerV1.Position memory position = lpManager.getPosition(positionId);
        assertTrue(position.active);
        assertEq(position.liquidity, liquidityBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(stock.balanceOf(alice), stockBefore);
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function testForceExitBypassesEveryEmergencyAndMarketPauseMode() public {
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        for (uint8 mode = 1; mode <= 3; mode++) {
            _submitLocalMarket(MarketAction.HALT, PauseMode(mode));
            uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode(mode));
            uint256 stockBefore = stock.balanceOf(alice);
            uint256 quoteBefore = quote.balanceOf(alice);
            lpManager.forceExit(positionId, 1, 1, keccak256("pause-exit"));
            assertFalse(lpManager.getPosition(positionId).active);
            assertGt(stock.balanceOf(alice), stockBefore);
            assertGt(quote.balanceOf(alice), quoteBefore);
            vm.expectRevert();
            lpManager.ownerOf(positionId);
            registry.clearEmergencyPause(id, keccak256("resume"));
            _submitLocalMarket(MarketAction.RESUME, PauseMode.ALL);
            if (mode != uint8(PauseMode.ALL)) {
                vm.prank(alice);
                positionId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
            }
        }
    }

    function testSbtAndDisabledAssetsStillBlockBothOperationTypes() public {
        _seedPauseTestFees();
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.LP);
        sbt.setPaused(true);
        SwapRequest memory request = _swapRequest(true, 1e18);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(alice);
        router.swapExactInput(request);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        sbt.setPaused(false);
        registry.clearEmergencyPause(id, keccak256("resume"));

        registry.setTokenStatus(address(stock), TokenStatus.DISABLED);
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED);
        registry.disablePool(PoolId.unwrap(key.toId()));
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
    }
}
