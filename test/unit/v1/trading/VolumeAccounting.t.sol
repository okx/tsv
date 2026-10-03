// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev Trading volume and pause gates; real swap settlement lives in local/trading.
contract TSVVolumeAccountingTest is FoundationFixture {
    /// @dev Verifies reports and the Ledger use actual deltas and a shared quota.
    function testReportsAndLedgerUseRealDeltaAndSharedQuota() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        assertTrue(registry.isTradable(poolId));
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? 1e18 : 0,
            stock0 ? 0 : 1e18
        );
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1e18);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(11e17) : int128(1e6),
            stock0 ? int128(1e6) : -int128(11e17),
            stock0 ? 11e17 : 0,
            stock0 ? 0 : 11e17
        );
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function testLedgerUsesOnlyTradingPauseForSwapAccounting() public {
        _submitAdtv(1000e18);
        _grantPauseRoles();
        _pause(PauseScope.GLOBAL, 0, PauseMode.LP);
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        int128 delta0 = stock0 ? -int128(1e18) : int128(1e6);
        int128 delta1 = stock0 ? int128(1e6) : -int128(1e18);
        ledger.recordSwap(poolId, delta0, delta1, stock0 ? 1e18 : 0, stock0 ? 0 : 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.recordSwap(poolId, delta0, delta1, stock0 ? 1e18 : 0, stock0 ? 0 : 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }
}
