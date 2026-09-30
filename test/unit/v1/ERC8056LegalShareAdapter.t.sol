// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC8056TestToken} from "../../../lib/TestToken/erc8056/ERC8056TestToken.sol";
import {ERC8056LegalShareAdapter} from "tsv-v1/adapters/ERC8056LegalShareAdapter.sol";
import {RateSnapshot, RoundingMode, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";

contract ERC8056LegalShareAdapterTest is Test {
    ERC8056TestToken internal token;
    ERC8056LegalShareAdapter internal adapter;

    function setUp() public {
        token = new ERC8056TestToken("ERC8056", "E8056", 18, 0);
        adapter = new ERC8056LegalShareAdapter(address(token), 1);
    }

    function testUsesActiveUiMultiplierAndKeepsRawBalanceStable() public {
        address alice = makeAddr("alice");
        token.mint(alice, 3e18);

        RateSnapshot memory initial = adapter.snapshot(address(token));
        assertEq(initial.numerator, 1e18);
        assertEq(initial.denominator, 1e18);
        assertEq(uint8(initial.rounding), uint8(RoundingMode.FLOOR));
        assertEq(adapter.toLegalShares(address(token), 3e18, initial), 3e18);

        token.setUIMultiplier(2e18, block.timestamp + 1);
        assertEq(token.balanceOf(alice), 3e18);
        assertEq(token.uiMultiplier(), 1e18);
        vm.warp(block.timestamp + 1);

        RateSnapshot memory updated = adapter.snapshot(address(token));
        assertEq(updated.numerator, 2e18);
        assertEq(adapter.toLegalShares(address(token), 3e18, updated), 6e18);
        assertFalse(adapter.isCurrent(address(token), initial));
        assertEq(token.balanceOf(alice), 3e18);
    }

    function testPendingMultiplierDoesNotChangeCurrentSnapshot() public {
        RateSnapshot memory initial = adapter.snapshot(address(token));
        token.setUIMultiplier(2e18, block.timestamp + 10);
        RateSnapshot memory pending = adapter.snapshot(address(token));
        assertEq(pending.rateId, initial.rateId);
        assertTrue(adapter.isCurrent(address(token), initial));
    }

    function testRawBoundsUseTheSameActiveMultiplier() public {
        token.setUIMultiplier(2e18, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        RateSnapshot memory current = adapter.snapshot(address(token));

        uint256 minRaw =
            adapter.rawForLegalShares(address(token), 3e18, current, RawBoundMode.MIN_RAW_FOR_AT_LEAST_SHARES);
        uint256 maxRaw =
            adapter.rawForLegalShares(address(token), 3e18, current, RawBoundMode.MAX_RAW_FOR_AT_MOST_SHARES);
        assertEq(minRaw, 15e17);
        assertEq(maxRaw, 15e17);
        assertEq(adapter.toLegalShares(address(token), minRaw, current), 3e18);
    }

    function testRejectsZeroMultiplierTokenAddressMismatchAndStaleRate() public {
        ERC8056TestToken other = new ERC8056TestToken("Other", "OTH", 18, 0);
        vm.expectRevert(ERC8056LegalShareAdapter.InvalidRate.selector);
        adapter.snapshot(address(other));

        RateSnapshot memory initial = adapter.snapshot(address(token));
        token.setUIMultiplier(2e18, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(ERC8056LegalShareAdapter.InvalidRate.selector);
        adapter.toLegalShares(address(token), 1e18, initial);
    }
}
