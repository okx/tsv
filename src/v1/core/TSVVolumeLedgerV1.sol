// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, PoolConfig, PoolStatus} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";

/// @notice Aggregates per-security volume by UTC trade day across every pool of this TSV venue.
contract TSVVolumeLedgerV1 is TSVGoverned {
    /// @dev Reverts when the caller is not an authorized Ledger writer.
    error UnauthorizedWriter();
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the required report has not been accepted.
    error MissingReport();
    /// @dev Reverts when the supplied date or reporting period is invalid.
    error InvalidPeriod();
    /// @dev Reverts when the swap contains no nonzero amount to account.
    error ZeroSwapAmount();
    /// @dev Reverts when the converted legal-share amount is invalid.
    error InvalidLegalShareAmount();
    /// @dev Reverts when the operation would exceed the remaining legal-share quota.
    error QuotaExceeded(bytes32 securityId, uint32 tradeDayId);

    uint8 public constant QUOTA_SET = 1;
    uint8 public constant QUOTA_CLEAR = 2;
    uint8 public constant SPLIT_FACTOR_SET = 1;
    uint8 public constant SPLIT_FACTOR_CANCEL = 2;
    uint32 private constant SECONDS_PER_DAY = 86_400;
    uint32 private constant MAX_DAY_START_SHIFT = 14_400;

    /// @dev Stores the active ADTV value and its effective report metadata.
    struct AdtvValue {
        /// @dev Accepted average daily volume in legal-share WAD units.
        uint256 value;
        /// @dev Latest accepted report version for the security and source month.
        uint64 version;
        /// @dev Identifier of the latest accepted ADTV report.
        bytes32 reportId;
    }

    /// @dev Stores a per-security daily quota override and its effective report metadata.
    struct QuotaOverride {
        /// @dev Override cap in legal-share WAD units.
        uint256 quotaWad;
        /// @dev Whether the override is active for this security and trade day.
        bool active;
        /// @dev Latest accepted report version for this security and trade day.
        uint64 version;
        /// @dev Identifier of the report that set or cleared the override.
        bytes32 reportId;
    }

    /// @dev Stores the pending trade-day boundary transition checkpoint.
    struct DayStartCheckpoint {
        /// @dev First YYYYMMDD trade day that uses the new offset.
        uint32 effectiveDayId;
        /// @dev UTC seconds after midnight used as the new day start.
        uint32 offsetSeconds;
    }

    /// @dev Immutable once its first trade day starts; the fraction is reduced before storage.
    struct SplitFactorCheckpoint {
        uint32 effectiveTradeDayId;
        uint128 numerator;
        uint128 denominator;
        bytes32 reportId;
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

    // Appended storage: existing ADTV, quota, usage and day-start slots retain their layouts.
    mapping(bytes32 => mapping(uint32 => SplitFactorCheckpoint[])) private splitFactorCheckpoints;
    mapping(bytes32 => mapping(uint32 => uint64)) private splitFactorVersions;

    /// @notice Emitted when the authorized report writer contracts were bound to the Ledger.
    event WritersBound(address indexed hook, address indexed dataInbox);
    /// @notice Emitted when a monthly ADTV report was accepted.
    event AdtvAccepted(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint256 adtvWad,
        uint64 version,
        bytes32 indexed reportId
    );
    /// @notice Emitted when a daily quota override report was accepted or cleared.
    event QuotaAccepted(
        bytes32 indexed securityId,
        uint32 indexed tradeDayId,
        uint8 action,
        uint256 quotaWad,
        uint64 version,
        bytes32 indexed reportId
    );
    /// @notice Emitted when a completed swap delta and its legal-share volume were recorded.
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
    /// @notice Emitted when a future trade-day boundary change was scheduled.
    event DayStartScheduled(
        uint32 indexed effectiveDayId,
        uint32 indexed transitionDayId,
        uint32 oldOffsetSeconds,
        uint32 newOffsetSeconds,
        uint64 effectiveStartUTC,
        address indexed operator
    );
    /// @notice Emitted when a pending trade-day boundary change was cancelled.
    event DayStartCancelled(uint32 indexed effectiveDayId, address indexed operator);
    /// @notice Records a new or corrected future factor; the trade-day ID determines activation.
    event SplitFactorScheduled(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint32 indexed effectiveTradeDayId,
        uint128 numerator,
        uint128 denominator,
        uint64 version,
        bytes32 reportId
    );
    /// @notice Records removal of the latest pending checkpoint without reusing its version.
    event SplitFactorCancelled(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint32 indexed effectiveTradeDayId,
        bytes32 scheduledReportId,
        uint64 version,
        bytes32 reportId
    );

    /// @notice Initializes governance, the Registry, and the starting UTC day boundary.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param registry_ Registry that supplies security tiers and pool configuration.
    /// @param dayStartOffsetSeconds Seconds after UTC midnight at which a trade day begins.
    function initialize(address anchor, address registry_, uint32 dayStartOffsetSeconds) external initializer {
        __TSVGoverned_init(anchor);
        if (registry_ == address(0) || dayStartOffsetSeconds >= SECONDS_PER_DAY) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        initialDayStartOffsetSeconds = dayStartOffsetSeconds;
    }

    /// @notice Binds the only contracts permitted to record swaps and submit reports.
    /// @param hook_ Hook authorized to record completed swaps.
    /// @param dataInbox_ DataInbox authorized to write ADTV, quota and split-factor reports.
    function bindWriters(address hook_, address dataInbox_) external onlyGovernor {
        if (hook != address(0) || dataInbox != address(0) || hook_.code.length == 0 || dataInbox_.code.length == 0) {
            revert InvalidReport();
        }
        hook = hook_;
        dataInbox = dataInbox_;
        emit WritersBound(hook_, dataInbox_);
    }

    /// @dev Restricts report-storage entry points to the configured DataInbox.
    modifier onlyDataInbox() {
        if (msg.sender != dataInbox) revert UnauthorizedWriter();
        _;
    }

    /// @notice Stores the next version of a listed security's monthly ADTV report.
    /// @param report Validated ADTV report forwarded by DataInbox.
    function acceptAdtv(AdtvReport calldata report) external onlyDataInbox {
        if (
            report.securityId == 0 || report.adtvWad == 0 || !TradeDayLib.validMonth(report.sourceMonth)
                || !registry.getSecurity(report.securityId).listed
        ) revert InvalidReport();
        AdtvValue storage current = adtv[report.securityId][report.sourceMonth];
        if (report.version != current.version + 1) revert InvalidReport();
        // A later ADTV correction or Tier increase must not make a stored factor unrepresentable.
        SplitFactorCheckpoint[] storage factors = splitFactorCheckpoints[report.securityId][report.sourceMonth];
        for (uint256 i; i < factors.length; ++i) {
            Math.mulDiv(report.adtvWad, factors[i].numerator, factors[i].denominator);
        }
        current.value = report.adtvWad;
        current.version = report.version;
        current.reportId = report.reportId;
        emit AdtvAccepted(report.securityId, report.sourceMonth, report.adtvWad, report.version, report.reportId);
    }

    /// @notice Sets or clears a per-security, per-trade-day quota override.
    /// @param report Validated quota report forwarded by DataInbox.
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

    /// @notice Accepts a source-month-relative split factor for a future trade-day start.
    /// @dev Factors are absolute, not multiplied by the previous checkpoint. No activation transaction is needed.
    /// @param report Schedule/update or cancellation instruction validated by the DataInbox.
    function acceptSplitFactor(SplitFactorReport calldata report) external onlyDataInbox {
        if (
            report.securityId == 0 || !registry.getSecurity(report.securityId).listed
                || !TradeDayLib.validMonth(report.sourceMonth)
                || TradeDayLib.previousMonth(report.effectiveTradeDayId) != report.sourceMonth
                || report.version != splitFactorVersions[report.securityId][report.sourceMonth] + 1
        ) revert InvalidReport();
        (, uint32 currentDay) = currentTradeDay();
        if (report.effectiveTradeDayId <= currentDay) revert InvalidReport();

        SplitFactorCheckpoint[] storage factors = splitFactorCheckpoints[report.securityId][report.sourceMonth];
        uint256 count = factors.length;
        if (report.action == SPLIT_FACTOR_SET) {
            (uint128 numerator, uint128 denominator) = _reducedFactor(report.numerator, report.denominator);
            uint256 value = adtv[report.securityId][report.sourceMonth].value;
            if (value != 0) Math.mulDiv(value, numerator, denominator);
            SplitFactorCheckpoint memory next =
                SplitFactorCheckpoint(report.effectiveTradeDayId, numerator, denominator, report.reportId);
            if (count != 0 && factors[count - 1].effectiveTradeDayId >= report.effectiveTradeDayId) {
                // Only the latest pending checkpoint can be corrected; historical and intermediate entries are fixed.
                if (factors[count - 1].effectiveTradeDayId != report.effectiveTradeDayId) revert InvalidReport();
                factors[count - 1] = next;
            } else {
                factors.push(next);
            }
            emit SplitFactorScheduled(
                report.securityId,
                report.sourceMonth,
                report.effectiveTradeDayId,
                numerator,
                denominator,
                report.version,
                report.reportId
            );
        } else if (report.action == SPLIT_FACTOR_CANCEL) {
            if (
                report.numerator != 0 || report.denominator != 0 || count == 0
                    || factors[count - 1].effectiveTradeDayId != report.effectiveTradeDayId
            ) revert InvalidReport();
            bytes32 scheduledReportId = factors[count - 1].reportId;
            factors.pop();
            emit SplitFactorCancelled(
                report.securityId,
                report.sourceMonth,
                report.effectiveTradeDayId,
                scheduledReportId,
                report.version,
                report.reportId
            );
        } else {
            revert InvalidReport();
        }
        splitFactorVersions[report.securityId][report.sourceMonth] = report.version;
    }

    /// @notice Returns the factor applicable to a security and trade day, defaulting to 1/1.
    /// @dev Source-month scoping prevents old actions from being reapplied to a new month's ADTV basis.
    function splitFactorOf(bytes32 securityId, uint32 tradeDayId)
        public
        view
        returns (uint128 numerator, uint128 denominator)
    {
        SplitFactorCheckpoint[] storage factors =
            splitFactorCheckpoints[securityId][TradeDayLib.previousMonth(tradeDayId)];
        uint256 low;
        uint256 high = factors.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (factors[mid].effectiveTradeDayId <= tradeDayId) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (1, 1);
        SplitFactorCheckpoint storage factor = factors[low - 1];
        return (factor.numerator, factor.denominator);
    }

    /// @notice Returns accepted schedule/cancellation version for a security and ADTV source month.
    function splitFactorVersion(bytes32 securityId, uint32 sourceMonth) external view returns (uint64) {
        return splitFactorVersions[securityId][sourceMonth];
    }

    /// @notice Returns the number of retained factor checkpoints for an ADTV source month.
    function splitFactorCheckpointCount(bytes32 securityId, uint32 sourceMonth) external view returns (uint256) {
        return splitFactorCheckpoints[securityId][sourceMonth].length;
    }

    /// @notice Returns a pending or historical checkpoint; cancelled entries remain in events only.
    function splitFactorCheckpoint(bytes32 securityId, uint32 sourceMonth, uint256 index)
        external
        view
        returns (SplitFactorCheckpoint memory)
    {
        return splitFactorCheckpoints[securityId][sourceMonth][index];
    }

    /// @notice Schedules a bounded UTC day-start change without rewriting an active transition day.
    /// @param newOffsetSeconds New offset from UTC midnight, less than one day.
    /// @param effectiveDayId First trade-day ID that uses the new offset.
    function scheduleDayStart(uint32 newOffsetSeconds, uint32 effectiveDayId) external onlyGovernor {
        if (newOffsetSeconds >= SECONDS_PER_DAY) revert InvalidPeriod();
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
        dayStartCheckpoints.push(DayStartCheckpoint(effectiveDayId, newOffsetSeconds));
        hasPendingDayStart = true;
        emit DayStartScheduled(
            effectiveDayId, transitionDayId, oldOffset, newOffsetSeconds, newEffectiveStart, msg.sender
        );
    }

    /// @notice Cancels a scheduled day-start change before its transition day begins.
    function cancelPendingDayStart() external onlyGovernor {
        uint256 count = dayStartCheckpoints.length;
        if (!hasPendingDayStart || count == 0) revert InvalidPeriod();
        uint32 transitionDayId =
            TradeDayLib.ordinalToDate(TradeDayLib.dateToOrdinal(dayStartCheckpoints[count - 1].effectiveDayId) - 1);
        if (block.timestamp >= _dayStartUTC(transitionDayId)) revert InvalidPeriod();
        uint32 effectiveDayId = dayStartCheckpoints[count - 1].effectiveDayId;
        dayStartCheckpoints.pop();
        hasPendingDayStart = false;
        emit DayStartCancelled(effectiveDayId, msg.sender);
    }

    /// @notice Returns the UTC timestamp at which `dayId` begins under the stored schedule.
    /// @param dayId Trade-day identifier in YYYYMMDD form.
    /// @return Timestamp in seconds since the Unix epoch.
    function dayStartUTC(uint32 dayId) external view returns (uint64) {
        return _dayStartUTC(dayId);
    }

    /// @notice Returns the number of scheduled day-start checkpoints retained.
    /// @return Number of checkpoints in the schedule.
    function dayStartCheckpointCount() external view returns (uint256) {
        return dayStartCheckpoints.length;
    }

    /// @notice Returns the day-start checkpoint at `index`.
    /// @param index Zero-based checkpoint index.
    /// @return checkpoint Effective day and offset stored at that index.
    function dayStartCheckpoint(uint256 index) external view returns (DayStartCheckpoint memory) {
        return dayStartCheckpoints[index];
    }

    /// @notice Computes the current trade day using UTC and the effective day-start offset.
    /// @return exists Always true when calculation succeeds; retained for ABI compatibility.
    /// @return tradeDayId Current day identifier in YYYYMMDD form.
    function currentTradeDay() public view returns (bool exists, uint32 tradeDayId) {
        uint256 ordinal = block.timestamp / SECONDS_PER_DAY;
        uint32 today = TradeDayLib.ordinalToDate(ordinal);
        if (block.timestamp >= _dayStartUTC(today)) return (true, today);
        if (ordinal == 0) revert InvalidPeriod();
        return (true, TradeDayLib.ordinalToDate(ordinal - 1));
    }

    /// @notice Returns the legal-share volume already consumed for a security and trade day.
    /// @param securityId Listed security whose usage is queried.
    /// @param tradeDayId Trade-day identifier in YYYYMMDD form.
    /// @return legalSharesWad Cumulative volume recorded in WAD.
    function used(bytes32 securityId, uint32 tradeDayId) external view returns (uint256) {
        return usedWad[securityId][tradeDayId];
    }

    /// @notice Returns the accepted ADTV value and metadata for one security and source month.
    /// @param securityId Listed security whose report is queried.
    /// @param sourceMonth Source month in YYYYMM form.
    /// @return value Stored ADTV, version, and report ID.
    function adtvOf(bytes32 securityId, uint32 sourceMonth) external view returns (AdtvValue memory) {
        return adtv[securityId][sourceMonth];
    }

    /// @notice Returns the optional daily quota override and its version metadata.
    /// @param securityId Listed security whose override is queried.
    /// @param tradeDayId Trade-day identifier in YYYYMMDD form.
    /// @return quota Stored amount, active flag, version, and report ID.
    function quotaOf(bytes32 securityId, uint32 tradeDayId) external view returns (QuotaOverride memory) {
        return quotas[securityId][tradeDayId];
    }

    /// @notice Returns the remaining effective volume cap, or marks it invalid when ADTV is missing.
    /// @param securityId Listed security whose remaining cap is queried.
    /// @param tradeDayId Trade-day identifier in YYYYMMDD form.
    /// @return valid Whether the hard cap can be computed from an accepted ADTV report.
    /// @return value Remaining legal-share volume after recorded usage, floored at zero.
    function remaining(bytes32 securityId, uint32 tradeDayId) external view returns (bool valid, uint256 value) {
        uint256 hardCap = _hardCap(securityId, tradeDayId);
        if (hardCap == 0) return (false, 0);
        uint256 effectiveCap = _effectiveCap(securityId, tradeDayId, hardCap);
        uint256 consumed = usedWad[securityId][tradeDayId];
        return (true, consumed >= effectiveCap ? 0 : effectiveCap - consumed);
    }

    /// @notice Records actual swap deltas and consumes the applicable cap for each security leg.
    /// @dev Only the Hook may call this; any invalid leg or cap breach reverts the enclosing swap.
    /// @param poolId Active pool in which the swap occurred.
    /// @param delta0 Actual signed PoolManager delta for currency0.
    /// @param delta1 Actual signed PoolManager delta for currency1.
    /// @param legalShares0 Currency0 volume converted to legal shares in WAD, or zero for a non-stock leg.
    /// @param legalShares1 Currency1 volume converted to legal shares in WAD, or zero for a non-stock leg.
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

    /// @dev Validates and accounts one pool leg, emitting the adapter version used for the conversion.
    /// @param poolId Pool that produced the actual swap delta.
    /// @param securityId Security assigned to this Currency, or zero for a non-stock token.
    /// @param currency Pool Currency associated with the delta.
    /// @param delta Signed actual PoolManager delta for this leg.
    /// @param legalSharesWad Converted volume for the stock leg.
    /// @param day Trade day to which the volume is charged.
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

    /// @dev Adds a charge only when an ADTV-derived hard cap and effective quota permit it.
    /// @param securityId Security being charged.
    /// @param day Trade-day identifier receiving the charge.
    /// @param charge Legal-share volume to add in WAD.
    function _consume(bytes32 securityId, uint32 day, uint256 charge) private {
        uint256 hardCap = _hardCap(securityId, day);
        if (hardCap == 0) revert MissingReport();
        uint256 next = usedWad[securityId][day] + charge;
        if (next > _effectiveCap(securityId, day, hardCap)) revert QuotaExceeded(securityId, day);
        usedWad[securityId][day] = next;
    }

    /// @dev Applies an active daily quota override without allowing it to exceed the hard cap.
    /// @param securityId Security whose override is read.
    /// @param day Trade-day identifier whose override is read.
    /// @param hardCap ADTV and Tier-derived maximum for the day.
    /// @return Effective cap after applying the optional override.
    function _effectiveCap(bytes32 securityId, uint32 day, uint256 hardCap) private view returns (uint256) {
        QuotaOverride storage quota = quotas[securityId][day];
        return quota.active ? Math.min(hardCap, quota.quotaWad) : hardCap;
    }

    /// @dev Computes ADTV × Tier × the source-month-relative factor with one final floor rounding.
    /// @param securityId Security whose ADTV and Tier policy are used.
    /// @param day Trade-day identifier in YYYYMMDD form.
    /// @return Cap in legal-share WAD, or zero when the required ADTV is missing.
    function _hardCap(bytes32 securityId, uint32 day) private view returns (uint256) {
        uint32 sourceMonth = TradeDayLib.previousMonth(day);
        uint256 monthlyAdtv = adtv[securityId][sourceMonth].value;
        if (monthlyAdtv == 0) return 0;
        uint8 tierId = registry.getSecurity(securityId).tierId;
        uint16 bps = registry.tierPolicy(tierId).tierBps;
        (uint128 numerator, uint128 denominator) = splitFactorOf(securityId, day);
        return Math.mulDiv(monthlyAdtv, uint256(bps) * numerator, 10_000 * uint256(denominator));
    }

    /// @dev Rejects zero components and reduces an exact factor without a fixed-point approximation.
    function _reducedFactor(uint128 numerator, uint128 denominator) private pure returns (uint128, uint128) {
        if (numerator == 0 || denominator == 0) revert InvalidReport();
        uint128 a = numerator;
        uint128 b = denominator;
        while (b != 0) {
            uint128 remainder = a % b;
            a = b;
            b = remainder;
        }
        return (numerator / a, denominator / a);
    }

    /// @dev Converts a trade-day identifier and its applicable offset into a UTC timestamp.
    /// @param dayId Trade-day identifier in YYYYMMDD form.
    /// @return Timestamp at the beginning of the trade day.
    function _dayStartUTC(uint32 dayId) private view returns (uint64) {
        uint256 ordinal = TradeDayLib.dateToOrdinal(dayId);
        return TradeDayLib.timestamp64(ordinal * SECONDS_PER_DAY + _offsetFor(dayId));
    }

    /// @dev Binary-searches checkpoints and returns the latest offset effective on `dayId`.
    /// @param dayId Trade-day identifier in YYYYMMDD form.
    /// @return offsetSeconds UTC seconds after midnight used for that day.
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
