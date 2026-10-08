// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "./OperationsFixture.sol";

/// @dev Independent Q4 2026 calendar/report model. No TSV date/cap getter computes expected results.
///      Hook accounting is unit-level; funded V4 flows are tested separately in local/operations.
contract OperationsHandler is OperationsFixture {
    uint256 private constant OCTOBER_MIDNIGHT = 1790812800;
    uint256 private constant DAYS = 96;

    struct Value {
        uint256 amount;
        uint64 version;
        bytes32 id;
    }

    struct Quota {
        uint256 amount;
        uint64 version;
        bytes32 id;
        bool active;
    }

    struct Checkpoint {
        uint256 ordinal;
        uint32 offset;
    }

    struct Factor {
        uint256 ordinal;
        uint128 numerator;
        uint128 denominator;
        bytes32 id;
    }
    Value[4] private modelAdtv;
    Quota[96] private modelQuota;
    uint256[96] private modelUsed;
    Checkpoint[] private modelCheckpoints;
    Factor[][4] private modelFactors;
    uint64[4] private modelFactorVersions;
    mapping(bytes32 => bool) private modelIds;
    bytes32[] private attemptedIds;
    uint64[4] private modelSequence;
    uint64[4] private modelSourceTime;
    bytes32 private lastAcceptedId;
    uint256 private attempt;
    uint256 private modelTime;
    bool private pending;
    bool private volumeRole = true;
    uint256 public successfulReports;
    uint256 public rejectedReports;
    uint256 public successfulCharges;
    uint256 public rejectedCharges;

    function initializeModel() external {
        require(modelTime == 0, "model already initialized");
        setUp();
        modelTime = block.timestamp;
    }

    function submitAdtv(uint8 monthIndex, uint256 rawValue, uint8 fault) external {
        monthIndex %= 4;
        fault %= 8;
        uint256 value = bound(rawValue, 0, 2000e18);
        ReportMetadata memory m = _candidate(1, modelAdtv[monthIndex].version + 1, fault);
        if (fault == 1) m.version++;
        uint32 month = _month(monthIndex);
        if (fault == 7) month = 202613;
        bool expected =
            _validMetadata(1, m) && value != 0 && month != 202613 && m.version == modelAdtv[monthIndex].version + 1;
        AdtvReport memory report =
            AdtvReport(SECURITY, month, value, m.timestamp, m.deadline, m.version, m.sequence, m.id);
        (bool ok,) = address(inbox).call(abi.encodeCall(inbox.submitAdtv, (report)));
        assertEq(ok, expected, "ADTV acceptance differs from model");
        _finishReport(1, m, ok);
        if (ok) modelAdtv[monthIndex] = Value(value, m.version, m.id);
    }

    function submitQuota(uint8 dayIndex, uint256 rawValue, bool clear, uint8 fault) external {
        dayIndex %= uint8(DAYS);
        fault %= 8;
        uint256 value = clear ? 0 : bound(rawValue, 0, 4e18);
        Quota memory prior = modelQuota[dayIndex];
        ReportMetadata memory m = _candidate(2, prior.version + 1, fault);
        if (fault == 1) m.version++;
        uint8 action = clear ? 2 : 1;
        if (fault == 7) action = 3;
        uint256 hardCap = _cap(dayIndex);
        bool businessValid =
            action == 2 ? prior.active && value == 0 : action == 1 && value != 0 && hardCap != 0 && value <= hardCap;
        bool expected = _validMetadata(2, m) && businessValid && m.version == prior.version + 1;
        QuotaReport memory report =
            QuotaReport(SECURITY, _date(dayIndex), action, value, m.timestamp, m.deadline, m.version, m.sequence, m.id);
        (bool ok,) = address(inbox).call(abi.encodeCall(inbox.submitQuota, (report)));
        assertEq(ok, expected, "quota acceptance differs from model");
        _finishReport(2, m, ok);
        if (ok) modelQuota[dayIndex] = Quota(value, m.version, m.id, !clear);
    }

    function charge(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 0, 3e18);
        uint256 dayIndex = _currentOrdinal();
        uint256 cap = _cap(dayIndex);
        Quota memory quota = modelQuota[dayIndex];
        if (quota.active && quota.amount < cap) cap = quota.amount;
        bool expected = shares != 0 && cap != 0 && modelUsed[dayIndex] + shares <= cap;
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        bytes memory payload = abi.encodeCall(
            TSVVolumeLedgerV1.recordSwap,
            (
                poolId,
                stock0 ? -int128(1e18) : int128(1e6),
                stock0 ? int128(1e6) : -int128(1e18),
                stock0 ? shares : 0,
                stock0 ? 0 : shares
            )
        );
        (bool ok,) = address(ledger).call(payload);
        assertEq(ok, expected, "charge acceptance differs from model");
        if (ok) {
            modelUsed[dayIndex] += shares;
            successfulCharges++;
        } else {
            rejectedCharges++;
        }
    }

    /// @dev Independent linear checkpoint model, including failed metadata, future corrections and cancellations.
    function submitFactor(uint8 dayIndex, uint8 rawNumerator, uint8 rawDenominator, bool cancelFactor, uint8 fault)
        external
    {
        dayIndex %= uint8(DAYS);
        fault %= 8;
        uint8 monthIndex = _sourceMonthIndex(dayIndex);
        uint128 numerator = cancelFactor ? 0 : uint128(rawNumerator % 7 + 1);
        uint128 denominator = cancelFactor ? 0 : uint128(rawDenominator % 5 + 1);
        ReportMetadata memory m = _candidate(3, modelFactorVersions[monthIndex] + 1, fault);
        if (fault == 1) m.version++;
        if (fault == 7) {
            if (cancelFactor) numerator = 1;
            else denominator = 0;
        }
        Factor[] storage factors = modelFactors[monthIndex];
        uint256 count = factors.length;
        bool businessValid = dayIndex > _currentOrdinal();
        if (cancelFactor) {
            businessValid = businessValid && numerator == 0 && denominator == 0 && count != 0;
            if (count != 0) businessValid = businessValid && factors[count - 1].ordinal == dayIndex;
        } else {
            businessValid = businessValid && numerator != 0 && denominator != 0;
            if (count != 0) businessValid = businessValid && factors[count - 1].ordinal <= dayIndex;
        }
        bool expected = _validMetadata(3, m) && businessValid && m.version == modelFactorVersions[monthIndex] + 1;
        SplitFactorReport memory report = SplitFactorReport(
            SECURITY,
            _month(monthIndex),
            _date(dayIndex),
            cancelFactor ? 2 : 1,
            numerator,
            denominator,
            m.timestamp,
            m.deadline,
            m.version,
            m.sequence,
            m.id
        );
        (bool ok,) = address(inbox).call(abi.encodeCall(inbox.submitSplitFactor, (report)));
        assertEq(ok, expected, "split factor acceptance differs from model");
        _finishReport(3, m, ok);
        if (!ok) return;
        modelFactorVersions[monthIndex] = m.version;
        if (cancelFactor) {
            factors.pop();
        } else {
            Factor memory next = Factor(dayIndex, numerator, denominator, m.id);
            if (count != 0 && factors[count - 1].ordinal == dayIndex) factors[count - 1] = next;
            else factors.push(next);
        }
    }

    function advanceTime(uint32 secondsForward) external {
        uint256 end = OCTOBER_MIDNIGHT + 92 days + 86399; // End of 2027-01-01.
        modelTime += bound(secondsForward, 0, 20 days);
        if (modelTime > end) modelTime = end;
        vm.warp(modelTime);
    }

    function schedule(uint32 rawOffset, uint8 daysAhead) external {
        uint32 offset = uint32(bound(rawOffset, 0, 86399));
        uint256 ordinal = (modelTime - OCTOBER_MIDNIGHT) / 1 days + daysAhead % 4;
        uint32 oldOffset = _offset(ordinal);
        uint256 shift = offset > oldOffset ? offset - oldOffset : oldOffset - offset;
        uint256 count = modelCheckpoints.length;
        bool existingPending = pending && modelTime < _start(modelCheckpoints[count - 1].ordinal);
        bool expected = !existingPending && ordinal != 0 && offset != oldOffset && shift <= 4 hours;
        if (ordinal != 0) expected = expected && modelTime < _start(ordinal - 1);
        if (count != 0) expected = expected && ordinal > modelCheckpoints[count - 1].ordinal;
        (bool ok,) = address(ledger).call(abi.encodeCall(TSVVolumeLedgerV1.scheduleDayStart, (offset, _date(ordinal))));
        assertEq(ok, expected, "schedule acceptance differs from model");
        if (ok) {
            modelCheckpoints.push(Checkpoint(ordinal, offset));
            pending = true;
        }
    }

    function cancel() external {
        uint256 count = modelCheckpoints.length;
        bool expected = pending && count != 0;
        if (count != 0) expected = expected && modelTime < _start(modelCheckpoints[count - 1].ordinal - 1);
        (bool ok,) = address(ledger).call(abi.encodeCall(TSVVolumeLedgerV1.cancelPendingDayStart, ()));
        assertEq(ok, expected, "cancel acceptance differs from model");
        if (ok) {
            modelCheckpoints.pop();
            pending = false;
        }
    }

    function toggleReporter() external {
        bytes32 role = inbox.VOLUME_ORACLE_ROLE();
        if (volumeRole) inbox.revokeRole(role, address(this));
        else inbox.grantRole(role, address(this));
        volumeRole = !volumeRole;
    }

    function assertCalendarModel() external view {
        assertEq(block.timestamp, modelTime);
        (, uint32 actualDay) = ledger.currentTradeDay();
        assertEq(actualDay, _date(_currentOrdinal()));
        assertEq(ledger.dayStartCheckpointCount(), modelCheckpoints.length);
        for (uint256 i; i < DAYS; ++i) {
            assertEq(ledger.dayStartUTC(_date(i)), _start(i), "historical boundary drifted");
        }
        for (uint256 i; i < modelCheckpoints.length; ++i) {
            TSVVolumeLedgerV1.DayStartCheckpoint memory actual = ledger.dayStartCheckpoint(i);
            assertEq(actual.effectiveDayId, _date(modelCheckpoints[i].ordinal));
            assertEq(actual.offsetSeconds, modelCheckpoints[i].offset);
        }
    }

    function assertReportModel() external view {
        assertEq(inbox.hasRole(inbox.VOLUME_ORACLE_ROLE(), address(this)), volumeRole);
        for (uint8 kind = 1; kind <= 3; ++kind) {
            assertEq(inbox.lastSequence(kind, SECURITY), modelSequence[kind]);
            assertEq(inbox.lastSourceTimestamp(kind, SECURITY), modelSourceTime[kind]);
        }
        for (uint8 i; i < 4; ++i) {
            TSVVolumeLedgerV1.AdtvValue memory actual = ledger.adtvOf(SECURITY, _month(i));
            assertEq(actual.value, modelAdtv[i].amount);
            assertEq(actual.version, modelAdtv[i].version);
            assertEq(actual.reportId, modelAdtv[i].id);
            assertEq(ledger.splitFactorVersion(SECURITY, _month(i)), modelFactorVersions[i]);
            assertEq(ledger.splitFactorCheckpointCount(SECURITY, _month(i)), modelFactors[i].length);
            for (uint256 j; j < modelFactors[i].length; ++j) {
                TSVVolumeLedgerV1.SplitFactorCheckpoint memory factor =
                    ledger.splitFactorCheckpoint(SECURITY, _month(i), j);
                Factor memory expected = modelFactors[i][j];
                assertEq(factor.effectiveTradeDayId, _date(expected.ordinal));
                assertEq(
                    uint256(factor.numerator) * expected.denominator, uint256(expected.numerator) * factor.denominator
                );
                assertEq(factor.reportId, expected.id);
            }
        }
        for (uint256 i; i < DAYS; ++i) {
            TSVVolumeLedgerV1.QuotaOverride memory actual = ledger.quotaOf(SECURITY, _date(i));
            assertEq(actual.quotaWad, modelQuota[i].amount);
            assertEq(actual.version, modelQuota[i].version);
            assertEq(actual.reportId, modelQuota[i].id);
            assertEq(actual.active, modelQuota[i].active);
            assertEq(ledger.used(SECURITY, _date(i)), modelUsed[i], "report or schedule reset used");
            (uint128 numerator, uint128 denominator) = _modelFactor(i);
            (uint128 actualNumerator, uint128 actualDenominator) = ledger.splitFactorOf(SECURITY, _date(i));
            assertEq(uint256(actualNumerator) * denominator, uint256(numerator) * actualDenominator);
            uint256 cap = _cap(i);
            if (modelQuota[i].active && modelQuota[i].amount < cap) cap = modelQuota[i].amount;
            uint256 left = modelUsed[i] >= cap ? 0 : cap - modelUsed[i];
            (bool valid, uint256 remaining) = ledger.remaining(SECURITY, _date(i));
            assertEq(valid, _cap(i) != 0);
            assertEq(remaining, left);
        }
        for (uint256 i; i < attemptedIds.length; ++i) {
            assertEq(inbox.reportIdUsed(attemptedIds[i]), modelIds[attemptedIds[i]], "failed report consumed ID");
        }
    }

    function _candidate(uint8 kind, uint64 version, uint8 fault) private returns (ReportMetadata memory m) {
        m = ReportMetadata(
            uint64(modelTime),
            uint64(modelTime + 100),
            modelSequence[kind] + 1,
            version,
            keccak256(abi.encode("model-report", ++attempt))
        );
        if (fault == 2) m.sequence = modelSequence[kind];
        else if (fault == 3) m.timestamp = uint64(modelTime + 1);
        else if (fault == 4) m.deadline = uint64(modelTime - 1);
        else if (fault == 5) m.timestamp = modelSourceTime[kind] == 0 ? uint64(0) : modelSourceTime[kind] - 1;
        else if (fault == 6) m.id = lastAcceptedId;
        attemptedIds.push(m.id);
    }

    function _validMetadata(uint8 kind, ReportMetadata memory m) private view returns (bool) {
        return volumeRole && m.id != 0 && !modelIds[m.id] && m.sequence > modelSequence[kind]
            && m.timestamp >= modelSourceTime[kind] && m.timestamp <= modelTime && m.deadline >= modelTime;
    }

    function _finishReport(uint8 kind, ReportMetadata memory m, bool ok) private {
        if (ok) {
            modelSequence[kind] = m.sequence;
            modelSourceTime[kind] = m.timestamp;
            modelIds[m.id] = true;
            lastAcceptedId = m.id;
            successfulReports++;
        } else {
            rejectedReports++;
        }
    }

    function _cap(uint256 dayIndex) private view returns (uint256) {
        (uint128 numerator, uint128 denominator) = _modelFactor(dayIndex);
        return modelAdtv[_sourceMonthIndex(dayIndex)].amount * 25 * numerator / (10000 * uint256(denominator));
    }

    function _modelFactor(uint256 dayIndex) private view returns (uint128 numerator, uint128 denominator) {
        numerator = 1;
        denominator = 1;
        Factor[] storage factors = modelFactors[_sourceMonthIndex(dayIndex)];
        for (uint256 i; i < factors.length; ++i) {
            if (factors[i].ordinal <= dayIndex) {
                numerator = factors[i].numerator;
                denominator = factors[i].denominator;
            }
        }
    }

    function _sourceMonthIndex(uint256 dayIndex) private pure returns (uint8) {
        return dayIndex < 31 ? 0 : dayIndex < 61 ? 1 : dayIndex < 92 ? 2 : 3;
    }

    function _currentOrdinal() private view returns (uint256 ordinal) {
        ordinal = (modelTime - OCTOBER_MIDNIGHT) / 1 days;
        if (modelTime < _start(ordinal)) ordinal--;
    }

    function _start(uint256 ordinal) private view returns (uint256) {
        return OCTOBER_MIDNIGHT + ordinal * 1 days + _offset(ordinal);
    }

    function _offset(uint256 ordinal) private view returns (uint32 offset) {
        offset = 14400;
        for (uint256 i; i < modelCheckpoints.length; ++i) {
            if (modelCheckpoints[i].ordinal <= ordinal) offset = modelCheckpoints[i].offset;
        }
    }

    function _month(uint8 index) private pure returns (uint32) {
        return 202609 + index;
    }

    function _date(uint256 ordinal) private pure returns (uint32) {
        if (ordinal < 31) return uint32(20261001 + ordinal);
        if (ordinal < 61) return uint32(20261101 + ordinal - 31);
        if (ordinal < 92) return uint32(20261201 + ordinal - 61);
        return uint32(20270101 + ordinal - 92);
    }
}
