// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {UnderlyingRecord, PoolRecord} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";

/// @notice Aggregates per-security volume by UTC trade day across every pool of this TSV venue.
/// @dev VolumeLedger owns volume-cap state and accounting, but it does not own admission or report ordering.
///      Registry supplies roles, security tier policy, pool metadata, quote-token registration and W/U binding.
///      DataInbox is the only report writer for ADTV, quota and split-factor reports after replay and sequence
///      checks. Hook is the only swap writer and calls recordSwap after PoolManager produces final deltas.
contract TSVVolumeLedgerV1 is Initializable, UUPSUpgradeable {
    error UnauthorizedUpgrade();

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @dev Reverts when the caller is not an authorized Ledger writer.
    error UnauthorizedWriter();
    /// @dev Reverts when report fields or Ledger configuration are invalid.
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

    /// @notice Quota report action that writes an explicit daily cap override.
    uint8 public constant QUOTA_SET = 1;
    /// @notice Quota report action that removes an active daily cap override.
    uint8 public constant QUOTA_CLEAR = 2;
    /// @notice Split-factor report action that schedules or corrects a future checkpoint.
    uint8 public constant SPLIT_FACTOR_SET = 1;
    /// @notice Split-factor report action that cancels the latest pending checkpoint.
    uint8 public constant SPLIT_FACTOR_CANCEL = 2;
    uint32 private constant SECONDS_PER_DAY = 86_400;
    uint32 private constant MAX_DAY_START_SHIFT = 14_400;
    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant LEGAL_SHARE_ACCOUNTING_LOT_WAD = 1;

    /// @dev Stores a future or historical trade-day boundary transition checkpoint.
    struct DayStartCheckpoint {
        /// @dev First YYYYMMDD trade day that uses the new offset.
        uint32 effectiveDayId;
        /// @dev UTC seconds after midnight used as the new day start.
        uint32 offsetSeconds;
    }

    /// @dev Immutable once its first trade day starts; the reported fraction is stored exactly.
    struct SplitFactorCheckpoint {
        uint32 effectiveTradeDayId;
        uint128 numerator;
        uint128 denominator;
        bytes32 reportId;
    }

    /// @notice Registry used for roles, securities, tiers, pools and currency metadata.
    TSVRegistryV1 public registry;
    /// @notice Hook authorized to record completed swap deltas.
    address public hook;
    /// @notice DataInbox authorized to write source-backed reports.
    address public dataInbox;
    /// @notice Starting UTC seconds-after-midnight offset for TSV trade days.
    uint32 public initialDayStartOffsetSeconds;

    /// @dev Monthly unadjusted share-basis ADTV by security and source month; source month is encoded as YYYYMM.
    ///      Values must already be converted to legal-share WAD, but must not be split-adjusted or notional.
    mapping(bytes32 => mapping(uint32 => uint256)) private adtv;
    /// @dev Optional absolute daily quota override by security and trade day; zero means no override.
    mapping(bytes32 => mapping(uint32 => uint256)) private quotas;
    /// @dev Consumed legal-share volume by security and trade day; never reset by report corrections.
    mapping(bytes32 => mapping(uint32 => uint256)) private usedWad;
    /// @dev Append-only day-start schedule, except the latest pending checkpoint may be cancelled.
    DayStartCheckpoint[] private dayStartCheckpoints;
    /// @dev Source-month-scoped split-factor checkpoints; only the latest pending checkpoint may be changed.
    mapping(bytes32 => mapping(uint32 => SplitFactorCheckpoint[])) private splitFactorCheckpoints;

    /// @notice Emitted when the authorized report writer contracts were bound to the Ledger.
    event WritersBound(address indexed hook, address indexed dataInbox);
    /// @notice Emitted when a monthly ADTV report was accepted.
    event AdtvAccepted(
        bytes32 indexed securityId, uint32 indexed sourceMonth, uint256 adtvWad, bytes32 indexed reportId
    );
    /// @notice Emitted when a daily quota override report was accepted or cleared.
    event QuotaAccepted(
        bytes32 indexed securityId, uint32 indexed tradeDayId, uint8 action, uint256 quotaWad, bytes32 indexed reportId
    );
    /// @notice Emitted when a completed swap delta and its legal-share volume were recorded.
    /// @param poolCurrency PoolKey currency W; rawAmount is denominated in this token.
    /// @param underlying Underlying token U used for canonical legal-share conversion.
    event SwapAccounted(
        bytes32 indexed poolId,
        bytes32 indexed securityId,
        address indexed poolCurrency,
        address underlying,
        bool inputSide,
        uint32 tradeDayId,
        uint256 rawAmount,
        uint256 legalSharesWad
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
        bytes32 reportId
    );
    /// @notice Records removal of the latest pending checkpoint and its source report.
    event SplitFactorCancelled(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint32 indexed effectiveTradeDayId,
        bytes32 scheduledReportId,
        bytes32 reportId
    );

    /// @dev Locks the implementation; proxy storage is initialized separately.
    constructor() {
        _disableInitializers();
    }

    /// @dev Upgrade authorization is managed exclusively by the Registry.
    function _authorizeUpgrade(address) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
    }

    /// @notice Binds the Registry for permissions and sets the starting UTC day boundary.
    /// @dev The initial day boundary is immutable after initialization. Later changes must be scheduled as
    ///      checkpoints so historical day calculations remain reproducible.
    /// @param registry_ Registry that supplies security tiers and pool configuration.
    /// @param dayStartOffsetSeconds Seconds after UTC midnight at which a trade day begins.
    function initialize(address registry_, uint32 dayStartOffsetSeconds) external initializer {
        if (registry_.code.length == 0 || dayStartOffsetSeconds >= SECONDS_PER_DAY) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        initialDayStartOffsetSeconds = dayStartOffsetSeconds;
    }

    /// @notice Binds the only contracts permitted to record swaps and submit reports.
    /// @dev This is a one-time component binding. After it succeeds, reports must flow through DataInbox and
    ///      completed swaps must flow through Hook.
    /// @param hook_ Hook authorized to record completed swaps.
    /// @param dataInbox_ DataInbox authorized to write ADTV, quota and split-factor reports.
    function bindWriters(address hook_, address dataInbox_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hook != address(0) || dataInbox != address(0) || hook_.code.length == 0 || dataInbox_.code.length == 0) {
            revert InvalidReport();
        }
        hook = hook_;
        dataInbox = dataInbox_;
        emit WritersBound(hook_, dataInbox_);
    }

    modifier onlyRole(bytes32 role) {
        if (!registry.hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);
        _;
    }

    /// @dev Restricts report-storage entry points to the configured DataInbox.
    modifier onlyDataInbox() {
        if (msg.sender != dataInbox) revert UnauthorizedWriter();
        _;
    }

    /// @notice Stores a listed security's monthly ADTV report after Inbox ordering checks.
    /// @dev Flow: onlyDataInbox, validate listed security/month/nonzero ADTV, verify the new ADTV remains
    ///      computable with already stored split factors, then replace the monthly ADTV value. A later ADTV
    ///      correction changes future hard-cap calculations but does not reset already consumed daily usage.
    ///      The report value is expected to be the previous-full-month ADTV in source-month share units, converted
    ///      to legal-share WAD. If an upstream source already split-adjusts this ADTV, or reports notional volume
    ///      instead of share volume, split-factor accounting would be double-applied and that source must not be
    ///      submitted through this entry point without a separate policy flag.
    /// @param report Validated ADTV report forwarded by DataInbox.
    function acceptAdtv(AdtvReport calldata report) external onlyDataInbox {
        if (
            report.securityId == 0 || report.adtvWad == 0 || !TradeDayLib.validMonth(report.sourceMonth)
                || !registry.getSecurity(report.securityId).listed
        ) revert InvalidReport();
        // A later ADTV correction or Tier increase must not make a stored factor unrepresentable.
        SplitFactorCheckpoint[] storage factors = splitFactorCheckpoints[report.securityId][report.sourceMonth];
        for (uint256 i; i < factors.length; ++i) {
            Math.mulDiv(report.adtvWad, factors[i].numerator, factors[i].denominator);
        }
        adtv[report.securityId][report.sourceMonth] = report.adtvWad;
        emit AdtvAccepted(report.securityId, report.sourceMonth, report.adtvWad, report.reportId);
    }

    /// @notice Sets or clears a per-security, per-trade-day quota override.
    /// @dev Flow: onlyDataInbox, require listed security, then branch by action. SET requires an existing hard
    ///      cap, a nonzero override and quotaWad <= hardCap. CLEAR requires an active override and quotaWad == 0.
    ///      The override is absolute for that trade day; it is not multiplied by split factors again.
    /// @param report Validated quota report forwarded by DataInbox.
    function acceptQuota(QuotaReport calldata report) external onlyDataInbox {
        if (report.securityId == 0 || !registry.getSecurity(report.securityId).listed) revert InvalidReport();
        if (report.action == QUOTA_SET) {
            uint256 hardCap = _hardCap(report.securityId, report.tradeDayId);
            if (hardCap == 0 || report.quotaWad == 0 || report.quotaWad > hardCap) revert InvalidReport();
        } else if (report.action == QUOTA_CLEAR) {
            if (quotas[report.securityId][report.tradeDayId] == 0 || report.quotaWad != 0) revert InvalidReport();
        } else {
            revert InvalidReport();
        }

        quotas[report.securityId][report.tradeDayId] = report.quotaWad;
        emit QuotaAccepted(report.securityId, report.tradeDayId, report.action, report.quotaWad, report.reportId);
    }

    /// @notice Accepts a source-month-relative split factor for a future trade-day start.
    /// @dev Factors are absolute, not multiplied by the previous checkpoint. No activation transaction is needed.
    ///      Flow: onlyDataInbox, validate listed security/source month/future effective day, then either schedule
    ///      or correct the latest pending checkpoint with SPLIT_FACTOR_SET, or remove the latest pending checkpoint
    ///      with SPLIT_FACTOR_CANCEL. Historical checkpoints and intermediate pending checkpoints are immutable.
    /// @param report Schedule/update or cancellation instruction validated by the DataInbox.
    function acceptSplitFactor(SplitFactorReport calldata report) external onlyDataInbox {
        if (
            report.securityId == 0 || !registry.getSecurity(report.securityId).listed
                || !TradeDayLib.validMonth(report.sourceMonth)
                || TradeDayLib.previousMonth(report.effectiveTradeDayId) != report.sourceMonth
        ) revert InvalidReport();
        uint32 currentDay = currentTradeDay();
        if (report.effectiveTradeDayId <= currentDay) revert InvalidReport();

        SplitFactorCheckpoint[] storage factors = splitFactorCheckpoints[report.securityId][report.sourceMonth];
        uint256 count = factors.length;
        if (report.action == SPLIT_FACTOR_SET) {
            if (report.numerator == 0 || report.denominator == 0) revert InvalidReport();
            uint256 value = adtv[report.securityId][report.sourceMonth];
            if (value != 0) Math.mulDiv(value, report.numerator, report.denominator);
            SplitFactorCheckpoint memory next =
                SplitFactorCheckpoint(report.effectiveTradeDayId, report.numerator, report.denominator, report.reportId);
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
                report.numerator,
                report.denominator,
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
                report.securityId, report.sourceMonth, report.effectiveTradeDayId, scheduledReportId, report.reportId
            );
        } else {
            revert InvalidReport();
        }
    }

    /// @notice Returns the factor applicable to a security and trade day, defaulting to 1/1.
    /// @dev Source-month scoping prevents old actions from being reapplied to a new month's ADTV basis.
    ///      The checkpoint list is ordered by effectiveTradeDayId, so lookup is a binary search for the latest
    ///      checkpoint whose effective day is not after the queried trade day.
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
    /// @dev Flow: admin only, validate offset/date, require the previous pending checkpoint to have passed or be
    ///      absent, require monotonically increasing effective days, cap the shift size, and require the transition
    ///      day to be unopened under the old schedule. This preserves historical trade-day assignment.
    /// @param newOffsetSeconds New offset from UTC midnight, less than one day.
    /// @param effectiveDayId First trade-day ID that uses the new offset.
    function scheduleDayStart(uint32 newOffsetSeconds, uint32 effectiveDayId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOffsetSeconds >= SECONDS_PER_DAY) revert InvalidPeriod();
        uint256 count = dayStartCheckpoints.length;
        if (count != 0 && block.timestamp < _dayStartUTC(dayStartCheckpoints[count - 1].effectiveDayId)) {
            revert InvalidPeriod();
        }
        uint256 ordinal = TradeDayLib.dateToOrdinal(effectiveDayId);
        if (ordinal == 0) revert InvalidPeriod();
        uint32 transitionDayId = TradeDayLib.ordinalToDate(ordinal - 1);

        uint32 oldOffset = _offsetFor(effectiveDayId);
        if (newOffsetSeconds == oldOffset) revert InvalidPeriod();
        uint32 shift = newOffsetSeconds > oldOffset ? newOffsetSeconds - oldOffset : oldOffset - newOffsetSeconds;
        if (shift > MAX_DAY_START_SHIFT) revert InvalidPeriod();
        if (count != 0 && effectiveDayId <= dayStartCheckpoints[count - 1].effectiveDayId) {
            revert InvalidPeriod();
        }

        // The transition day has not started under the existing schedule, so no historical cycle changes.
        if (block.timestamp >= _dayStartUTC(transitionDayId)) revert InvalidPeriod();
        uint64 newEffectiveStart = TradeDayLib.timestamp64(ordinal * SECONDS_PER_DAY + newOffsetSeconds);
        dayStartCheckpoints.push(DayStartCheckpoint(effectiveDayId, newOffsetSeconds));
        emit DayStartScheduled(
            effectiveDayId, transitionDayId, oldOffset, newOffsetSeconds, newEffectiveStart, msg.sender
        );
    }

    /// @notice Cancels a scheduled day-start change before its transition day begins.
    /// @dev Only the latest pending checkpoint can be cancelled. Once its transition day has started, the schedule
    ///      is treated as historical and must remain stable for accounting and audit queries.
    function cancelPendingDayStart() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 count = dayStartCheckpoints.length;
        if (count == 0) revert InvalidPeriod();
        uint32 effectiveDayId = dayStartCheckpoints[count - 1].effectiveDayId;
        uint32 transitionDayId = TradeDayLib.ordinalToDate(TradeDayLib.dateToOrdinal(effectiveDayId) - 1);
        if (block.timestamp >= _dayStartUTC(transitionDayId)) revert InvalidPeriod();
        dayStartCheckpoints.pop();
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
    /// @dev Calculates the UTC calendar day first, then compares block.timestamp against the effective offset for
    ///      that day. If the local trade-day start has not arrived, accounting belongs to the previous YYYYMMDD.
    /// @return tradeDayId Current day identifier in YYYYMMDD form.
    function currentTradeDay() public view returns (uint32 tradeDayId) {
        uint256 ordinal = block.timestamp / SECONDS_PER_DAY;
        uint32 today = TradeDayLib.ordinalToDate(ordinal);
        if (block.timestamp >= ordinal * SECONDS_PER_DAY + _offsetFor(today)) return today;
        if (ordinal == 0) revert InvalidPeriod();
        return TradeDayLib.ordinalToDate(ordinal - 1);
    }

    /// @notice Returns the legal-share volume already consumed for a security and trade day.
    /// @param securityId Listed security whose usage is queried.
    /// @param tradeDayId Trade-day identifier in YYYYMMDD form.
    /// @return legalSharesWad Cumulative volume recorded in WAD.
    function used(bytes32 securityId, uint32 tradeDayId) external view returns (uint256) {
        return usedWad[securityId][tradeDayId];
    }

    /// @notice Returns the accepted ADTV value for one security and source month.
    /// @param securityId Listed security whose report is queried.
    /// @param sourceMonth Source month in YYYYMM form.
    /// @return value Stored ADTV in legal-share WAD units.
    function adtvOf(bytes32 securityId, uint32 sourceMonth) external view returns (uint256 value) {
        return adtv[securityId][sourceMonth];
    }

    /// @notice Returns the optional daily quota override.
    /// @param securityId Listed security whose override is queried.
    /// @param tradeDayId Trade-day identifier in YYYYMMDD form.
    /// @return quotaWad Stored amount in legal-share WAD units; zero means no override.
    function quotaOf(bytes32 securityId, uint32 tradeDayId) external view returns (uint256 quotaWad) {
        return quotas[securityId][tradeDayId];
    }

    /// @notice Returns the remaining effective volume cap, or marks it invalid when ADTV is missing.
    /// @dev Flow: compute the ADTV/tier/split-factor hard cap, apply an optional daily quota override, then
    ///      subtract already consumed legal-share volume. Missing ADTV returns valid=false instead of reverting.
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
    /// @dev Pool admission and trading pauses are checked by Hook.beforeSwap.
    /// @dev Flow: validate the two PoolManager deltas form one swap, load PoolRecord from Registry, resolve the
    ///      current trade day, map each pool currency to either the pool security or zero for quote tokens, then
    ///      account both legs. Quote legs must carry zero legalSharesWad; stock legs consume cap in legal-share WAD.
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
        PoolRecord memory pool = registry.getPool(poolId);
        uint32 day = currentTradeDay();
        address currency0 = Currency.unwrap(pool.key.currency0);
        address currency1 = Currency.unwrap(pool.key.currency1);
        _recordLeg(poolId, _legSecurityId(pool.securityId, currency0), currency0, delta0, legalShares0, day);
        _recordLeg(poolId, _legSecurityId(pool.securityId, currency1), currency1, delta1, legalShares1, day);
    }

    /// @dev Returns the pool security only for permissioned stock currencies; quote tokens have no security leg.
    function _legSecurityId(bytes32 poolSecurityId, address currency) private view returns (bytes32) {
        return registry.getCurrencyUnderlying(currency) == address(0) ? bytes32(0) : poolSecurityId;
    }

    /// @dev Validates and accounts one pool leg using its canonical legal-share conversion.
    ///      Quote-token legs are validated as registered quote tokens and return without consuming quota. Stock
    ///      legs must resolve to an underlying whose security matches the pool, have a nonzero legalSharesWad, and
    ///      then call _consume before emitting the audit event.
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
        address underlyingAddress = registry.getCurrencyUnderlying(currency);
        if (underlyingAddress == address(0)) {
            if (!registry.getQuoteToken(currency).registered || securityId != 0 || legalSharesWad != 0) {
                revert InvalidLegalShareAmount();
            }
            return;
        }
        UnderlyingRecord memory underlying = registry.getUnderlying(underlyingAddress);
        if (securityId == 0 || underlying.securityId != securityId || underlying.legalShareAdapter == address(0)) {
            revert InvalidLegalShareAmount();
        }
        if (legalSharesWad == 0) revert InvalidLegalShareAmount();
        uint256 raw = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        _consume(securityId, day, legalSharesWad);
        emit SwapAccounted(poolId, securityId, currency, underlyingAddress, delta < 0, day, raw, legalSharesWad);
    }

    /// @dev Adds a charge only when an ADTV-derived hard cap and effective quota permit it.
    ///      Missing ADTV fails closed with MissingReport. Otherwise the new cumulative usage must fit within the
    ///      lower of the hard cap and any active daily override.
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
    ///      acceptQuota enforces quotaWad <= hardCap at write time; Math.min keeps reads robust across later ADTV,
    ///      tier or split-factor corrections that may lower the hard cap.
    /// @param securityId Security whose override is read.
    /// @param day Trade-day identifier whose override is read.
    /// @param hardCap ADTV and Tier-derived maximum for the day.
    /// @return Effective cap after applying the optional override.
    function _effectiveCap(bytes32 securityId, uint32 day, uint256 hardCap) private view returns (uint256) {
        uint256 quotaWad = quotas[securityId][day];
        return quotaWad == 0 ? hardCap : Math.min(hardCap, quotaWad);
    }

    /// @dev Computes floorToLot(previousFullMonth ADTV shares × splitFactor × tierBps / 10000).
    ///      The source month is the full calendar month immediately before the trade day. ADTV is stored in that
    ///      source month's unadjusted share basis and splitFactor translates it to the target trade day's share
    ///      basis. A zero return means no accepted ADTV exists, the bps/factor result floors to zero, or no explicit
    ///      fallback policy exists; swap accounting then fails closed and remaining() reports invalid.
    /// @param securityId Security whose ADTV and Tier policy are used.
    /// @param day Trade-day identifier in YYYYMMDD form.
    /// @return Cap in legal-share WAD, or zero when the required ADTV is missing.
    function _hardCap(bytes32 securityId, uint32 day) private view returns (uint256) {
        uint32 sourceMonth = _sourceMonthFor(day);
        uint256 monthlyAdtvSharesWad = adtv[securityId][sourceMonth];
        if (monthlyAdtvSharesWad == 0) return 0;

        uint8 tierId = registry.getSecurity(securityId).tierId;
        uint16 bps = registry.getTierPolicy(tierId).tierBps;
        uint256 adjustedAdtvSharesWad = _splitAdjustedAdtvShares(securityId, day, monthlyAdtvSharesWad);
        return _floorToLot(Math.mulDiv(adjustedAdtvSharesWad, bps, BASIS_POINTS));
    }

    /// @dev Returns the previous full calendar month that supplies the ADTV basis for `day`.
    ///      This intentionally does not fall back to partial current-month data.
    function _sourceMonthFor(uint32 day) private pure returns (uint32) {
        return TradeDayLib.previousMonth(day);
    }

    /// @dev Converts source-month ADTV share units to target-day share units using the applicable absolute factor.
    function _splitAdjustedAdtvShares(bytes32 securityId, uint32 day, uint256 monthlyAdtvSharesWad)
        private
        view
        returns (uint256)
    {
        (uint128 numerator, uint128 denominator) = splitFactorOf(securityId, day);
        return Math.mulDiv(monthlyAdtvSharesWad, numerator, denominator);
    }

    /// @dev Floors a cap to the configured accounting lot. Current storage has no exchange-level lot-size policy,
    ///      so the active lot is the smallest legal-share WAD accounting unit. A future lot-size field should replace
    ///      this helper without changing the hard-cap call site.
    function _floorToLot(uint256 value) private pure returns (uint256) {
        return value / LEGAL_SHARE_ACCOUNTING_LOT_WAD * LEGAL_SHARE_ACCOUNTING_LOT_WAD;
    }

    /// @dev Converts a trade-day identifier and its applicable offset into a UTC timestamp.
    ///      Invalid calendar dates are rejected by TradeDayLib.dateToOrdinal.
    /// @param dayId Trade-day identifier in YYYYMMDD form.
    /// @return Timestamp at the beginning of the trade day.
    function _dayStartUTC(uint32 dayId) private view returns (uint64) {
        uint256 ordinal = TradeDayLib.dateToOrdinal(dayId);
        return TradeDayLib.timestamp64(ordinal * SECONDS_PER_DAY + _offsetFor(dayId));
    }

    /// @dev Binary-searches checkpoints and returns the latest offset effective on `dayId`.
    ///      If no checkpoint applies, the immutable initial offset is used.
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
