// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, PoolConfig, PoolStatus} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";

/// @notice Aggregates per-security volume by UTC trade day across every pool of this TSV venue.
contract TSVVolumeLedgerV1 is TSVGoverned {
    error UnauthorizedWriter();
    error InvalidReport();
    error MissingReport();
    error InvalidPeriod();
    error ZeroSwapAmount();
    error InvalidLegalShareAmount();
    error QuotaExceeded(bytes32 securityId, uint32 tradeDayId);

    uint8 public constant QUOTA_SET = 1;
    uint8 public constant QUOTA_CLEAR = 2;
    uint32 private constant SECONDS_PER_DAY = 86_400;
    uint32 private constant MAX_DAY_START_SHIFT = 14_400;

    struct AdtvValue {
        uint256 value;
        uint64 version;
        bytes32 reportId;
    }

    struct QuotaOverride {
        uint256 quotaWad;
        bool active;
        uint64 version;
        bytes32 reportId;
    }

    struct DayStartCheckpoint {
        uint32 effectiveDayId;
        uint32 offsetSeconds;
        bytes32 reasonHash;
    }

    TSVRegistryV1 public registry;
    address public hook;
    address public dataInbox;
    uint32 public initialDayStartOffsetSeconds;

    mapping(bytes32 => mapping(uint32 => AdtvValue)) private adtv;
    mapping(bytes32 => mapping(uint32 => QuotaOverride)) private quotas;
    mapping(bytes32 => mapping(uint32 => uint256)) private usedWad;
    DayStartCheckpoint[] private dayStartCheckpoints;
    bool private hasPendingDayStart;

    event WritersBound(address indexed hook, address indexed dataInbox);
    event AdtvAccepted(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint256 adtvWad,
        uint64 version,
        bytes32 indexed reportId
    );
    event QuotaAccepted(
        bytes32 indexed securityId,
        uint32 indexed tradeDayId,
        uint8 action,
        uint256 quotaWad,
        uint64 version,
        bytes32 indexed reportId
    );
    event SwapAccounted(
        bytes32 indexed poolId,
        bytes32 indexed securityId,
        address indexed poolCurrency,
        bool inputSide,
        uint32 tradeDayId,
        uint256 rawAmount,
        uint256 legalSharesWad,
        uint32 legalAdapterVersion
    );
    event DayStartScheduled(
        uint32 indexed effectiveDayId,
        uint32 indexed transitionDayId,
        uint32 oldOffsetSeconds,
        uint32 newOffsetSeconds,
        uint64 effectiveStartUTC,
        address indexed operator,
        bytes32 reasonHash
    );
    event DayStartCancelled(uint32 indexed effectiveDayId, address indexed operator, bytes32 reasonHash);

    function initialize(
        address authority,
        address timelock,
        address controller,
        address registry_,
        uint32 dayStartOffsetSeconds
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        if (registry_ == address(0) || dayStartOffsetSeconds >= SECONDS_PER_DAY) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        initialDayStartOffsetSeconds = dayStartOffsetSeconds;
    }

    function bindWriters(address hook_, address dataInbox_) external onlyGovernor {
        if (hook != address(0) || dataInbox != address(0) || hook_.code.length == 0 || dataInbox_.code.length == 0) {
            revert InvalidReport();
        }
        hook = hook_;
        dataInbox = dataInbox_;
        emit WritersBound(hook_, dataInbox_);
    }

    modifier onlyDataInbox() {
        if (msg.sender != dataInbox) revert UnauthorizedWriter();
        _;
    }

    function acceptAdtv(AdtvReport calldata report) external onlyDataInbox {
        if (
            report.securityId == 0 || report.adtvWad == 0 || !TradeDayLib.validMonth(report.sourceMonth)
                || !registry.getSecurity(report.securityId).listed
        ) revert InvalidReport();
        AdtvValue storage current = adtv[report.securityId][report.sourceMonth];
        if (report.version != current.version + 1) revert InvalidReport();
        current.value = report.adtvWad;
        current.version = report.version;
        current.reportId = report.reportId;
        emit AdtvAccepted(report.securityId, report.sourceMonth, report.adtvWad, report.version, report.reportId);
    }

    function acceptQuota(QuotaReport calldata report) external onlyDataInbox {
        if (report.securityId == 0 || !registry.getSecurity(report.securityId).listed) revert InvalidReport();
        QuotaOverride storage current = quotas[report.securityId][report.tradeDayId];
        if (report.version != current.version + 1) revert InvalidReport();

        if (report.action == QUOTA_SET) {
            uint256 hardCap = _hardCap(report.securityId, report.tradeDayId);
            if (hardCap == 0 || report.quotaWad == 0 || report.quotaWad > hardCap) revert InvalidReport();
            current.quotaWad = report.quotaWad;
            current.active = true;
        } else if (report.action == QUOTA_CLEAR) {
            if (!current.active || report.quotaWad != 0) revert InvalidReport();
            current.quotaWad = 0;
            current.active = false;
        } else {
            revert InvalidReport();
        }

        current.version = report.version;
        current.reportId = report.reportId;
        emit QuotaAccepted(
            report.securityId, report.tradeDayId, report.action, report.quotaWad, report.version, report.reportId
        );
    }

    function scheduleDayStart(uint32 newOffsetSeconds, uint32 effectiveDayId, bytes32 reasonHash)
        external
        onlyGovernor
    {
        if (newOffsetSeconds >= SECONDS_PER_DAY || reasonHash == 0) revert InvalidPeriod();
        if (hasPendingDayStart) {
            uint32 priorEffectiveDayId = dayStartCheckpoints[dayStartCheckpoints.length - 1].effectiveDayId;
            if (block.timestamp < _dayStartUTC(priorEffectiveDayId)) revert InvalidPeriod();
            hasPendingDayStart = false;
        }
        uint256 ordinal = TradeDayLib.dateToOrdinal(effectiveDayId);
        if (ordinal == 0) revert InvalidPeriod();
        uint32 transitionDayId = TradeDayLib.ordinalToDate(ordinal - 1);

        uint32 oldOffset = _offsetFor(effectiveDayId);
        if (newOffsetSeconds == oldOffset) revert InvalidPeriod();
        uint32 shift = newOffsetSeconds > oldOffset ? newOffsetSeconds - oldOffset : oldOffset - newOffsetSeconds;
        if (shift > MAX_DAY_START_SHIFT) revert InvalidPeriod();
        if (
            dayStartCheckpoints.length != 0
                && effectiveDayId <= dayStartCheckpoints[dayStartCheckpoints.length - 1].effectiveDayId
        ) {
            revert InvalidPeriod();
        }

        // The transition day has not started under the existing schedule, so no historical cycle changes.
        if (block.timestamp >= _dayStartUTC(transitionDayId)) revert InvalidPeriod();
        uint64 newEffectiveStart =
            TradeDayLib.timestamp64(TradeDayLib.dateToOrdinal(effectiveDayId) * SECONDS_PER_DAY + newOffsetSeconds);
        dayStartCheckpoints.push(DayStartCheckpoint(effectiveDayId, newOffsetSeconds, reasonHash));
        hasPendingDayStart = true;
        emit DayStartScheduled(
            effectiveDayId, transitionDayId, oldOffset, newOffsetSeconds, newEffectiveStart, msg.sender, reasonHash
        );
    }

    function cancelPendingDayStart(bytes32 reasonHash) external onlyGovernor {
        uint256 count = dayStartCheckpoints.length;
        if (!hasPendingDayStart || reasonHash == 0 || count == 0) revert InvalidPeriod();
        uint32 transitionDayId =
            TradeDayLib.ordinalToDate(TradeDayLib.dateToOrdinal(dayStartCheckpoints[count - 1].effectiveDayId) - 1);
        if (block.timestamp >= _dayStartUTC(transitionDayId)) revert InvalidPeriod();
        uint32 effectiveDayId = dayStartCheckpoints[count - 1].effectiveDayId;
        dayStartCheckpoints.pop();
        hasPendingDayStart = false;
        emit DayStartCancelled(effectiveDayId, msg.sender, reasonHash);
    }

    function dayStartUTC(uint32 dayId) external view returns (uint64) {
        return _dayStartUTC(dayId);
    }

    function dayStartCheckpointCount() external view returns (uint256) {
        return dayStartCheckpoints.length;
    }

    function dayStartCheckpoint(uint256 index) external view returns (DayStartCheckpoint memory) {
        return dayStartCheckpoints[index];
    }

    function currentTradeDay() public view returns (bool exists, uint32 tradeDayId) {
        uint256 ordinal = block.timestamp / SECONDS_PER_DAY;
        uint32 today = TradeDayLib.ordinalToDate(ordinal);
        if (block.timestamp >= _dayStartUTC(today)) return (true, today);
        if (ordinal == 0) revert InvalidPeriod();
        return (true, TradeDayLib.ordinalToDate(ordinal - 1));
    }

    function used(bytes32 securityId, uint32 tradeDayId) external view returns (uint256) {
        return usedWad[securityId][tradeDayId];
    }

    function adtvOf(bytes32 securityId, uint32 sourceMonth) external view returns (AdtvValue memory) {
        return adtv[securityId][sourceMonth];
    }

    function quotaOf(bytes32 securityId, uint32 tradeDayId) external view returns (QuotaOverride memory) {
        return quotas[securityId][tradeDayId];
    }

    function remaining(bytes32 securityId, uint32 tradeDayId) external view returns (bool valid, uint256 value) {
        uint256 hardCap = _hardCap(securityId, tradeDayId);
        if (hardCap == 0) return (false, 0);
        uint256 effectiveCap = _effectiveCap(securityId, tradeDayId, hardCap);
        uint256 consumed = usedWad[securityId][tradeDayId];
        return (true, consumed >= effectiveCap ? 0 : effectiveCap - consumed);
    }

    function recordSwap(bytes32 poolId, int128 delta0, int128 delta1, uint256 legalShares0, uint256 legalShares1)
        external
    {
        if (msg.sender != hook) revert UnauthorizedWriter();
        if (delta0 == 0 || delta1 == 0 || (delta0 < 0) == (delta1 < 0)) revert ZeroSwapAmount();
        PoolConfig memory pool = registry.getPool(poolId);
        if (pool.status != PoolStatus.ACTIVE || !registry.isTradable(poolId)) revert InvalidPeriod();
        (, uint32 day) = currentTradeDay();
        _recordLeg(poolId, pool.securityId0, Currency.unwrap(pool.key.currency0), delta0, legalShares0, day);
        _recordLeg(poolId, pool.securityId1, Currency.unwrap(pool.key.currency1), delta1, legalShares1, day);
    }

    function _recordLeg(
        bytes32 poolId,
        bytes32 securityId,
        address currency,
        int128 delta,
        uint256 legalSharesWad,
        uint32 day
    ) private {
        if (securityId == 0) {
            if (legalSharesWad != 0) revert InvalidLegalShareAmount();
            return;
        }
        if (legalSharesWad == 0) revert InvalidLegalShareAmount();
        TokenConfig memory config = registry.getToken(currency);
        if (
            config.securityId != securityId || config.legalShareAdapter == address(0) || config.legalAdapterVersion == 0
        ) {
            revert InvalidLegalShareAmount();
        }
        uint256 raw = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        _consume(securityId, day, legalSharesWad);
        emit SwapAccounted(
            poolId, securityId, currency, delta < 0, day, raw, legalSharesWad, config.legalAdapterVersion
        );
    }

    function _consume(bytes32 securityId, uint32 day, uint256 charge) private {
        uint256 hardCap = _hardCap(securityId, day);
        if (hardCap == 0) revert MissingReport();
        uint256 next = usedWad[securityId][day] + charge;
        if (next > _effectiveCap(securityId, day, hardCap)) revert QuotaExceeded(securityId, day);
        usedWad[securityId][day] = next;
    }

    function _effectiveCap(bytes32 securityId, uint32 day, uint256 hardCap) private view returns (uint256) {
        QuotaOverride storage quota = quotas[securityId][day];
        return quota.active ? Math.min(hardCap, quota.quotaWad) : hardCap;
    }

    function _hardCap(bytes32 securityId, uint32 day) private view returns (uint256) {
        uint32 sourceMonth = TradeDayLib.previousMonth(day);
        uint256 monthlyAdtv = adtv[securityId][sourceMonth].value;
        if (monthlyAdtv == 0) return 0;
        uint8 tierId = registry.getSecurity(securityId).tierId;
        uint16 bps = registry.tierPolicy(tierId).tierBps;
        return Math.mulDiv(monthlyAdtv, bps, 10_000);
    }

    function _dayStartUTC(uint32 dayId) private view returns (uint64) {
        uint256 ordinal = TradeDayLib.dateToOrdinal(dayId);
        return TradeDayLib.timestamp64(ordinal * SECONDS_PER_DAY + _offsetFor(dayId));
    }

    function _offsetFor(uint32 dayId) private view returns (uint32) {
        uint256 low;
        uint256 high = dayStartCheckpoints.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (dayStartCheckpoints[mid].effectiveDayId <= dayId) low = mid + 1;
            else high = mid;
        }
        return low == 0 ? initialDayStartOffsetSeconds : dayStartCheckpoints[low - 1].offsetSeconds;
    }
}
