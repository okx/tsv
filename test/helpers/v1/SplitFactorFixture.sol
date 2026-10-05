// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";
import {OperationsFixture} from "./OperationsFixture.sol";

/// @dev Report builders and rollback snapshots only; each executable suite owns its cases.
abstract contract SplitFactorFixture is OperationsFixture {
    function _factor(uint32 day, uint128 numerator, uint128 denominator, uint64 version, uint64 sequence, bytes32 id)
        internal
        view
        returns (SplitFactorReport memory report)
    {
        report = SplitFactorReport(
            SECURITY,
            TradeDayLib.previousMonth(day),
            day,
            1,
            numerator,
            denominator,
            uint64(block.timestamp),
            uint64(block.timestamp + 100),
            version,
            sequence,
            id
        );
    }

    function _setFactor(uint32 day, uint128 numerator, uint128 denominator, uint64 version, uint64 sequence) internal {
        SplitFactorReport memory report = _factor(
            day, numerator, denominator, version, sequence, keccak256(abi.encode("factor", day, version, sequence))
        );
        inbox.submitSplitFactor(report);
    }

    function _cancelFactor(uint32 day, uint64 version, uint64 sequence) internal {
        SplitFactorReport memory report =
            _factor(day, 0, 0, version, sequence, keccak256(abi.encode("cancel-factor", day, version, sequence)));
        report.action = 2;
        inbox.submitSplitFactor(report);
    }

    function _assertFactor(uint32 day, uint128 numerator, uint128 denominator) internal view {
        (uint128 actualNumerator, uint128 actualDenominator) = ledger.splitFactorOf(SECURITY, day);
        assertEq(actualNumerator, numerator);
        assertEq(actualDenominator, denominator);
    }

    function _factorState(SplitFactorReport memory report) internal view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                _reportState(report.securityId, report.sourceMonth, report.effectiveTradeDayId, report.reportId),
                inbox.lastSequence(3, report.securityId),
                inbox.lastSourceTimestamp(3, report.securityId),
                ledger.splitFactorVersion(report.securityId, report.sourceMonth),
                ledger.splitFactorCheckpointCount(report.securityId, report.sourceMonth)
            )
        );
        uint256 count = ledger.splitFactorCheckpointCount(report.securityId, report.sourceMonth);
        for (uint256 i; i < count; ++i) {
            state = keccak256(abi.encode(state, ledger.splitFactorCheckpoint(report.securityId, report.sourceMonth, i)));
        }
    }
}
