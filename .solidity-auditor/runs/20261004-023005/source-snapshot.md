# Audit source snapshot

Scope: src and script security review; test scenario coverage review ONLY. External repositories are context ONLY.

### src/v1/types/TSVReports.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";

/// @notice Source-backed market-state transition submitted through DataInbox.
struct MarketReport {
    /// @notice Listed security affected by the market-state report.
    bytes32 securityId;
    /// @notice Halt or resume action; admission defaults to open.
    MarketAction action;
    /// @notice Operations paused or resumed: TRADE, LP, or ALL.
    PauseMode mode;
    /// @notice Nonzero operational reason code included for audit.
    bytes32 reasonCode;
    /// @notice Nonzero digest identifying the exchange or market source.
    bytes32 exchangeHash;
    /// @notice Time when the source produced this market information.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Increasing sequence for this security's market reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}

/// @notice Versioned monthly average-daily-volume input for one listed security.
struct AdtvReport {
    /// @notice Listed security whose hard volume cap uses this report.
    bytes32 securityId;
    /// @notice Calendar month from which the ADTV data was sourced, encoded as YYYYMM.
    uint32 sourceMonth;
    /// @notice Average daily volume converted to legal-share WAD units.
    uint256 adtvWad;
    /// @notice Time when the source produced this ADTV value.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Incrementing version for this security and source month.
    uint64 version;
    /// @notice Increasing sequence for this security's ADTV reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}

/// @notice Versioned optional quota override for one security and TSV trade day.
struct QuotaReport {
    /// @notice Listed security whose daily cap is overridden.
    bytes32 securityId;
    /// @notice TSV trade day affected, encoded as YYYYMMDD.
    uint32 tradeDayId;
    /// @notice Ledger action: set an override or clear an active override.
    uint8 action;
    /// @notice Override value in legal-share WAD; zero when clearing.
    uint256 quotaWad;
    /// @notice Time when the source produced this quota instruction.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Incrementing version for this security and trade day.
    uint64 version;
    /// @notice Increasing sequence for this security's quota reports.
    uint64 sequence;
    /// @notice Globally unique report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the supporting source material.
    bytes32 sourceHash;
}

/// @notice Schedules or cancels an absolute split factor relative to one month's ADTV units.
struct SplitFactorReport {
    /// @notice Listed security whose ADTV-derived cap is adjusted.
    bytes32 securityId;
    /// @notice Unchanged ADTV source month, encoded as YYYYMM.
    uint32 sourceMonth;
    /// @notice First YYYYMMDD trade day using the factor; only future day starts are allowed.
    uint32 effectiveTradeDayId;
    /// @notice Schedule/update = 1, cancel the latest pending checkpoint = 2.
    uint8 action;
    /// @notice Absolute cumulative factor numerator relative to the source-month units.
    uint128 numerator;
    /// @notice Absolute cumulative factor denominator; both components are zero when cancelling.
    uint128 denominator;
    /// @notice Time when the source produced this instruction.
    uint64 sourceTimestamp;
    /// @notice Latest timestamp at which DataInbox may accept the report.
    uint64 submitDeadline;
    /// @notice Next version for this security and source month, including cancellations.
    uint64 version;
    /// @notice Increasing sequence for this security's split-factor report stream.
    uint64 sequence;
    /// @notice Globally unique nonzero report identifier.
    bytes32 reportId;
    /// @notice Nonzero digest of the announcement and supporting source material.
    bytes32 sourceHash;
}

```

### src/v1/types/TSVTypes.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Admission state for a pool Currency registered in the Registry.
enum TokenStatus {
    ABSENT, // No approved Currency has been registered.
    APPROVED, // Reviewed and permitted for new pool operations.
    DISABLED // Temporarily or permanently blocked from new pool operations.
}
/// @notice Lifecycle state for a Registry pool.
enum PoolStatus {
    ABSENT, // No pool record exists.
    PENDING, // Registered while PoolManager initialization is in progress.
    ACTIVE, // Initialized and available when all other trading gates pass.
    DISABLED // Registered but blocked from ordinary user operations.
}
/// @notice Market state derived from a known security's current pause mask.
enum MarketStatus {
    OPEN, // Market operations may proceed when all other gates pass.
    HALTED // Trading, ordinary LP actions, or both are paused.
}
/// @notice Allowed market pause transitions after admission defaults to open.
enum MarketAction {
    HALT, // Adds the selected trading and/or LP pause to a listed security.
    RESUME // Removes the selected pause; the security is open once all market pauses clear.
}
/// @notice Scope used to target an emergency pause record.
enum PauseScope {
    GLOBAL, // Applies to all TSV pools and assets.
    SECURITY, // Applies to pools containing one security.
    TOKEN, // Applies to pools containing one Currency.
    POOL // Applies to one V4 pool ID.
}
/// @notice Operations affected by a pause; values also form the market pause bitmask.
enum PauseMode {
    NONE, // No market pause; invalid as the mode of a pause or resume request.
    TRADE, // Blocks swaps only.
    LP, // Blocks all ordinary LP actions only.
    ALL // Blocks swaps and all ordinary LP actions.
}
/// @notice Operation mode bound to an LP Manager callback context.
enum LPOperationMode {
    OPEN, // Adds the initial positive liquidity to a new position.
    INCREASE, // Adds liquidity to an existing position.
    DECREASE, // Removes part of existing liquidity.
    COLLECT, // Collects accrued fees without changing liquidity.
    CLOSE, // Removes all liquidity at the owner's request.
    FORCE_EXIT // Removes all liquidity through the authorized forced-exit path.
}

/// @notice Registry configuration and review metadata for a pool Currency.
struct TokenConfig {
    /// @notice ERC-20 address used directly as the V4 Currency.
    address poolCurrency;
    /// @notice Token decimals checked against the token at registration.
    uint8 poolDecimals;
    /// @notice Listed security ID, or zero for a non-security Currency.
    bytes32 securityId;
    /// @notice Adapter converting this Currency's raw amount to legal shares; zero for non-security tokens.
    address legalShareAdapter;
    /// @notice Reviewed version of `legalShareAdapter`; zero for non-security tokens.
    uint32 legalAdapterVersion;
    /// @notice Current approval or disablement state of the Currency.
    TokenStatus status;
    /// @notice Runtime code hash required when the token is admitted or re-enabled.
    bytes32 poolRuntimeCodeHash;
    /// @notice Runtime code hash recorded for the legal-share adapter.
    bytes32 legalAdapterCodeHash;
    /// @notice Off-chain implementation evidence retained for review.
    bytes32 poolImplementationHash;
    /// @notice Nonzero digest of the token admission review required for approval.
    bytes32 reviewHash;
    /// @notice Off-chain digest of the token's restrictions review.
    bytes32 restrictionsHash;
    /// @notice Nonzero digest of the legal-share conversion policy.
    bytes32 legalSharePolicyHash;
}

/// @notice Registry state for one listed or delisted security.
struct SecurityConfig {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
    /// @notice Unique digest of the display symbol or ticker.
    bytes32 symbolHash;
    /// @notice Tier whose multiplier sets the security's hard daily volume cap.
    uint8 tierId;
    /// @notice Whether the security is currently listed for pool and report use.
    bool listed;
    /// @notice Number of active pools containing this security.
    uint32 activePoolCount;
    /// @notice Incremented whenever listing or tier configuration changes.
    uint32 version;
}

/// @notice Stored key, security legs, status, and version for a V4 pool.
struct PoolConfig {
    /// @notice Full V4 pool key.
    PoolKey key;
    /// @notice Security ID for currency0, or zero for an ordinary Currency.
    bytes32 securityId0;
    /// @notice Security ID for currency1, or zero for an ordinary Currency.
    bytes32 securityId1;
    /// @notice Registry lifecycle state of the pool.
    PoolStatus status;
    /// @notice Incremented when the pool is activated or its status changes.
    uint32 version;
}

/// @notice LP Manager state exposed to the Hook while one liquidity operation is in progress.
struct LPContext {
    /// @notice Pool identifier derived from the position's V4 key.
    bytes32 poolId;
    /// @notice TSV position identifier.
    uint256 positionId;
    /// @notice Lower tick boundary of the position.
    int24 tickLower;
    /// @notice Upper tick boundary of the position.
    int24 tickUpper;
    /// @notice Operation being performed on this position.
    LPOperationMode mode;
    /// @notice Unique V4 salt assigned to the position.
    bytes32 salt;
    /// @notice Signed liquidity change expected in the PoolManager callback.
    int256 liquidityDelta;
}

/// @notice Reduced LP operation context returned to the Hook for callback validation.
struct LPHookContext {
    /// @notice Pool identifier derived from the position's V4 key.
    bytes32 poolId;
    /// @notice Lower tick boundary of the position.
    int24 tickLower;
    /// @notice Upper tick boundary of the position.
    int24 tickUpper;
    /// @notice Operation being performed on this position.
    LPOperationMode mode;
    /// @notice Unique V4 salt assigned to the position.
    bytes32 salt;
    /// @notice Signed liquidity change expected in the PoolManager callback.
    int256 liquidityDelta;
}

/// @notice Shared one-pool request for direct exact-in/out and approved Adapter exact-in swaps.
/// @dev The Router derives a full-range V4 price limit from `zeroForOne`.
struct SwapRequest {
    /// @notice Full V4 pool key; the Registry must recognize it as tradable.
    PoolKey key;
    /// @notice True for currency0-to-currency1, false for the reverse direction.
    bool zeroForOne;
    /// @notice Exact input amount or exact output amount, depending on the entry point.
    uint128 amountSpecified;
    /// @notice Minimum output for exact-input swaps or maximum input for exact-output swaps.
    uint128 limitAmount;
    /// @notice Latest timestamp at which the swap may execute.
    uint64 deadline;
}

/// @notice Raw-unit settlement limits and deadline for an LP operation.
struct LPBounds {
    /// @notice Maximum currency0 amount the owner may be charged.
    uint256 maxPoolIn0;
    /// @notice Maximum currency1 amount the owner may be charged.
    uint256 maxPoolIn1;
    /// @notice Minimum currency0 amount that must be returned to the owner.
    uint256 minPoolOut0;
    /// @notice Minimum currency1 amount that must be returned to the owner.
    uint256 minPoolOut1;
    /// @notice Latest timestamp at which the LP operation may execute.
    uint64 deadline;
}

```

### src/v1/core/TSVVolumeLedgerV1.sol — SECURITY REVIEW

```solidity
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
        /// @dev Digest of the evidence supporting the schedule change.
        bytes32 reasonHash;
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
        address indexed operator,
        bytes32 reasonHash
    );
    /// @notice Emitted when a pending trade-day boundary change was cancelled.
    event DayStartCancelled(uint32 indexed effectiveDayId, address indexed operator, bytes32 reasonHash);
    /// @notice Records a new or corrected future factor; the trade-day ID determines activation.
    event SplitFactorScheduled(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint32 indexed effectiveTradeDayId,
        uint128 numerator,
        uint128 denominator,
        uint64 version,
        bytes32 reportId,
        bytes32 sourceHash
    );
    /// @notice Records removal of the latest pending checkpoint without reusing its version.
    event SplitFactorCancelled(
        bytes32 indexed securityId,
        uint32 indexed sourceMonth,
        uint32 indexed effectiveTradeDayId,
        bytes32 scheduledReportId,
        uint64 version,
        bytes32 reportId,
        bytes32 sourceHash
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
                report.reportId,
                report.sourceHash
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
                report.reportId,
                report.sourceHash
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
    /// @param reasonHash Nonzero digest recording the reason for the schedule.
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

    /// @notice Cancels a scheduled day-start change before its transition day begins.
    /// @param reasonHash Nonzero digest recording the cancellation reason.
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
    /// @return checkpoint Effective day, offset, and reason hash stored at that index.
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

```

### src/v1/core/TSVDataInboxV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketReport, AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {ReportValidationLib} from "tsv-v1/libraries/ReportValidationLib.sol";

/// @notice Validates signed-off market and volume reports before forwarding them to TSV state contracts.
contract TSVDataInboxV1 is TSVGoverned {
    /// @dev Reverts when the caller is not an authorized report submitter.
    error UnauthorizedReporter();
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();

    /// @dev Bounded to keep a monthly report submission within block gas limits.
    uint256 public constant MAX_ADTV_BATCH_SIZE = 100;

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    mapping(bytes32 => bool) public reportIdUsed;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSequence;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSourceTimestamp;

    /// @notice Initializes governance and binds the Registry and Volume Ledger.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param registry_ Registry that receives market-status transitions.
    /// @param ledger_ Volume Ledger that stores ADTV and quota reports.
    function initialize(address anchor, address registry_, address ledger_) external initializer {
        __TSVGoverned_init(anchor);
        if (registry_ == address(0) || ledger_ == address(0)) revert InvalidReport();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    /// @notice Validates and records the next market-state report for a listed security.
    /// @param report Market action, source metadata, ordering fields, and evidence hashes.
    function submitMarketStatus(MarketReport calldata report) external {
        _accept(
            0,
            report.securityId,
            HALT_REPORTER_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        if (
            report.securityId == 0 || report.mode == PauseMode.NONE || report.reasonCode == 0
                || report.exchangeHash == 0
        ) revert InvalidReport();
        registry.applyMarketStatus(report.securityId, report.action, report.mode, report.sequence, report.reportId);
    }

    /// @notice Validates and accepts one monthly ADTV report.
    /// @param report Security, source month, ADTV value, version, and source metadata.
    function submitAdtv(AdtvReport calldata report) external {
        _submitAdtv(report);
    }

    /// @notice Atomically accepts the monthly ADTV reports for multiple securities.
    /// @dev Reports must use the same source month and be sorted by unique securityId.
    /// @param reports Reports to accept; the whole batch reverts if any entry is invalid.
    function submitAdtvBatch(AdtvReport[] calldata reports) external {
        if (reports.length == 0 || reports.length > MAX_ADTV_BATCH_SIZE) {
            revert InvalidReport();
        }

        uint32 sourceMonth = reports[0].sourceMonth;
        bytes32 previousSecurityId;
        for (uint256 i; i < reports.length; i++) {
            AdtvReport calldata report = reports[i];
            if (
                report.securityId == 0 || report.sourceMonth != sourceMonth
                    || (i != 0 && uint256(report.securityId) <= uint256(previousSecurityId))
            ) {
                revert InvalidReport();
            }
            _submitAdtv(report);
            previousSecurityId = report.securityId;
        }
    }

    /// @dev Applies common ingress checks and forwards one ADTV report to the Ledger.
    /// @param report ADTV report being accepted.
    function _submitAdtv(AdtvReport calldata report) private {
        _accept(
            1,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        ledger.acceptAdtv(report);
    }

    /// @notice Validates and accepts a quota override for one security and trade day.
    /// @param report Quota action, target day, version, and source metadata.
    function submitQuota(QuotaReport calldata report) external {
        _accept(
            2,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        ledger.acceptQuota(report);
    }

    /// @notice Schedules, corrects or cancels a split factor at a future trade-day start.
    /// @param report Source-month-relative factor and the announcement's effective trade day.
    function submitSplitFactor(SplitFactorReport calldata report) external {
        _accept(
            3,
            report.securityId,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash
        );
        ledger.acceptSplitFactor(report);
    }

    /// @dev Enforces reporter authorization and shared report freshness and uniqueness rules.
    /// @param kind Report category used to maintain independent ordering state.
    /// @param key Security identifier whose reports are being ordered.
    /// @param role Role required from the submitting address.
    /// @param sourceTimestamp Time at which the source data was produced.
    /// @param submitDeadline Last timestamp at which the report may be submitted.
    /// @param sequence Monotonically increasing sequence for this category and security.
    /// @param reportId Globally unique nonzero report identifier.
    /// @param sourceHash Nonzero digest identifying the supporting source material.
    function _accept(
        uint8 kind,
        bytes32 key,
        bytes32 role,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        bytes32 sourceHash
    ) private {
        if (!hasRole(role, msg.sender)) revert UnauthorizedReporter();
        ReportValidationLib.validate(
            lastSequence[kind][key],
            lastSourceTimestamp[kind][key],
            reportIdUsed[reportId],
            sourceTimestamp,
            submitDeadline,
            sequence,
            reportId,
            sourceHash,
            block.timestamp
        );
        lastSequence[kind][key] = sequence;
        lastSourceTimestamp[kind][key] = sourceTimestamp;
        reportIdUsed[reportId] = true;
    }
}

```

### src/v1/core/TSVHookV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolConfig, PoolStatus, TokenConfig, LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @dev Exposes the active LP operation context used to authorize Hook callbacks.
interface IActiveLPContextV1 {
    /// @notice Returns the LP Manager's active operation context for Hook validation.
    function activeLPContext() external view returns (LPHookContext memory);
}

/// @notice Upgradeable hook whose proxy address carries the V4 permission bits.
contract TSVHookV1 is TSVGoverned, IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Reserve all V4 callback and return-delta permissions at the proxy address.
    // V1 returns zero deltas; nonzero deltas require a separately reviewed accounting upgrade.
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    /// @dev Reverts when the callback caller or context is not authorized.
    error UnauthorizedCallback();
    /// @dev Reverts when the Hook proxy address does not contain the required V4 permission bits.
    error InvalidHookAddress();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the requested operation is not valid in the current state or callback context.
    error InvalidOperation();
    /// @dev Reverts when the requested Hook callback is not supported.
    error UnsupportedCallback();

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    address public router;
    address public lpManager;

    /// @notice Initializes the Hook's trusted component addresses and verifies its V4 permission bits.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param poolManager_ V4 PoolManager that invokes Hook callbacks.
    /// @param registry_ Registry used for pool, token, and market validation.
    /// @param ledger_ Volume Ledger that records completed swaps.
    /// @param router_ Only router permitted to execute swaps through this Hook.
    /// @param lpManager_ Only LP Manager permitted to initialize pools and modify liquidity.
    function initialize(
        address anchor,
        address poolManager_,
        address registry_,
        address ledger_,
        address router_,
        address lpManager_
    ) external initializer {
        __TSVGoverned_init(anchor);
        if ((uint160(address(this)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS) revert InvalidHookAddress();
        if (
            poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0
                || router_.code.length == 0 || lpManager_.code.length == 0
        ) revert InvalidOperation();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        router = router_;
        lpManager = lpManager_;
    }

    /// @dev Restricts V4 callback implementations to the configured PoolManager.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        _;
    }

    /// @notice Allows initialization only for a pending pool created by the LP Manager.
    /// @param sender Contract that initiated PoolManager.initialize.
    /// @param key Full V4 pool key being initialized.
    /// @return V4 callback selector acknowledging this Hook callback.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requirePending(sender, key);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Confirms that PoolManager completed initialization for a pending TSV pool.
    /// @param sender Contract that initiated PoolManager.initialize.
    /// @param key Full V4 pool key that was initialized.
    /// @return V4 callback selector acknowledging this Hook callback.
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requirePending(sender, key);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Allows positive liquidity changes only for an authorized operation passing LP admission and pause checks.
    /// @param sender Contract that initiated PoolManager.modifyLiquidity.
    /// @param key Full V4 pool key being modified.
    /// @param params Tick range, salt, and liquidity change requested by the manager.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPHookContext memory ctx = _checkLP(sender, key, params, hookData);
        if (
            params.liquidityDelta <= 0 || (ctx.mode != LPOperationMode.OPEN && ctx.mode != LPOperationMode.INCREASE)
                || !registry.isLPAllowed(ctx.poolId)
        ) revert InvalidOperation();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Returns zero Hook delta after a validated liquidity addition.
    /// @dev V1 does not apply a Hook delta to the liquidity caller or accrued fees.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not adjust liquidity deltas.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Validates removal context and allows forced exits to bypass ordinary LP admission and pause checks.
    /// @param sender Contract that initiated PoolManager.modifyLiquidity.
    /// @param key Full V4 pool key being modified.
    /// @param params Tick range, salt, and liquidity change requested by the manager.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        LPHookContext memory ctx = _checkLP(sender, key, params, hookData);
        if (params.liquidityDelta > 0 || ctx.mode == LPOperationMode.OPEN || ctx.mode == LPOperationMode.INCREASE) {
            revert InvalidOperation();
        }
        if (ctx.mode == LPOperationMode.FORCE_EXIT) {
            if (params.liquidityDelta >= 0) revert InvalidOperation();
        } else if (!registry.isLPAllowed(ctx.poolId)) {
            revert InvalidPool();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Returns zero Hook delta after a validated liquidity removal.
    /// @dev V1 does not apply a Hook delta to the liquidity caller or accrued fees.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not adjust liquidity deltas.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Allows the configured Router to swap only through an active, tradable registered pool.
    /// @param sender Contract that initiated the swap; must equal the configured Router.
    /// @param key Full V4 pool key being swapped.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not alter the swap delta.
    /// @return Zero because V1 does not override the pool fee.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != router || hookData.length != 0) revert UnauthorizedCallback();
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (!registry.isTradable(poolId)) revert InvalidOperation();
        _requireExactKey(key, poolId);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /// @notice Converts actual stock-side swap deltas to legal shares and records them in the Ledger.
    /// @param sender Contract that initiated the swap; must equal the configured Router.
    /// @param key Full V4 pool key that was swapped.
    /// @param delta Actual PoolManager balance delta for both currencies.
    /// @param hookData Additional callback data; TSV requires it to be empty.
    /// @return V4 callback selector acknowledging this Hook callback.
    /// @return Zero because V1 does not alter the swap delta.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (sender != router || hookData.length != 0) revert UnauthorizedCallback();
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolConfig memory pool = registry.getPool(poolId);
        uint256 shares0 = _sharesForLeg(pool.securityId0, Currency.unwrap(key.currency0), delta.amount0());
        uint256 shares1 = _sharesForLeg(pool.securityId1, Currency.unwrap(key.currency1), delta.amount1());
        ledger.recordSwap(poolId, delta.amount0(), delta.amount1(), shares0, shares1);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Rejects donations because TSV V1 exposes no donation operation.
    /// @dev All callback inputs are ignored because donations are unsupported.
    /// @return Unreachable; the callback always reverts with `UnsupportedCallback`.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    /// @notice Rejects post-donation callbacks because TSV V1 does not support donations.
    /// @dev All callback inputs are ignored because donations are unsupported.
    /// @return Unreachable; the callback always reverts with `UnsupportedCallback`.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    /// @dev Requires initialization to originate from the LP Manager for an exactly registered pending key.
    /// @param sender Contract that invoked the PoolManager operation.
    /// @param key Pool key being initialized.
    function _requirePending(address sender, PoolKey calldata key) private view {
        if (
            sender != lpManager || address(key.hooks) != address(this)
                || registry.getPool(PoolId.unwrap(key.toId())).status != PoolStatus.PENDING
        ) revert InvalidPool();
        _requireExactKey(key, PoolId.unwrap(key.toId()));
    }

    /// @dev Prevents a caller from reusing a registered pool ID with a different key.
    /// @param key Pool key supplied to the current PoolManager callback.
    /// @param poolId Identifier derived from that key.
    function _requireExactKey(PoolKey calldata key, bytes32 poolId) private view {
        PoolConfig memory pool = registry.getPool(poolId);
        if (keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))) revert InvalidPool();
    }

    /// @dev Matches the PoolManager callback against the LP Manager's one-operation context.
    /// @param sender Contract that invoked the liquidity modification.
    /// @param key Pool key being modified.
    /// @param params Tick range, salt, and liquidity delta from PoolManager.
    /// @param hookData Additional callback data, which must be empty.
    /// @return ctx Validated LP context for the current operation.
    function _checkLP(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) private view returns (LPHookContext memory ctx) {
        if (sender != lpManager || hookData.length != 0) revert UnauthorizedCallback();
        ctx = IActiveLPContextV1(lpManager).activeLPContext();
        if (
            ctx.poolId == 0 || ctx.poolId != PoolId.unwrap(key.toId()) || ctx.salt != params.salt
                || ctx.tickLower != params.tickLower || ctx.tickUpper != params.tickUpper
                || ctx.liquidityDelta != params.liquidityDelta
        ) revert InvalidOperation();
        _requireExactKey(key, ctx.poolId);
    }

    /// @dev Converts the absolute raw delta of a stock leg; non-stock and zero deltas account as zero.
    /// @param securityId Security assigned to the pool leg, or zero for an ordinary Currency.
    /// @param currency Pool Currency whose adapter performs the legal-share conversion.
    /// @param delta Actual signed PoolManager delta for this leg.
    /// @return Legal-share amount in WAD for the Ledger.
    function _sharesForLeg(bytes32 securityId, address currency, int128 delta) private view returns (uint256) {
        if (securityId == 0 || delta == 0) return 0;
        TokenConfig memory config = registry.getToken(currency);
        if (config.securityId != securityId || config.legalShareAdapter == address(0)) revert InvalidPool();
        uint256 rawAmount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        return IDirectLegalShareAdapter(config.legalShareAdapter).toLegalShares(currency, rawAmount);
    }
}

```

### src/v1/core/TSVRegistryV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    TokenConfig,
    SecurityConfig,
    PoolConfig,
    TokenStatus,
    PoolStatus,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @dev Exposes ERC-20 decimal metadata used during token registration.
interface IERC20DecimalsV1 {
    /// @notice Returns the token's configured decimal precision for registration checks.
    function decimals() external view returns (uint8);
}

/// @dev Defines the SBT pause and credential-verification views required by the Registry.
interface ISmartWalletSbtV1 {
    /// @notice Checks whether `user` holds the configured credential token.
    function verify(address user, uint256 tokenId) external view returns (bool);

    /// @notice Reports whether the SBT contract has globally paused credential checks.
    function paused() external view returns (bool);
}

/// @notice Single TSV venue asset, security, pool and pause registry.
contract TSVRegistryV1 is TSVGoverned {
    using PoolIdLibrary for PoolKey;

    /// @dev Reverts when the supplied Registry configuration is invalid.
    error InvalidConfig();
    /// @dev Reverts when the requested status transition is not allowed.
    error InvalidStatus();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the required participant SBT has not been configured.
    error SbtNotConfigured();
    /// @dev Reverts when the affected component or asset is paused.
    error Paused(uint8 scope, bytes32 target);

    /// @dev Stores the listing limits and fee policy for a security tier.
    struct TierPolicy {
        /// @dev ADTV hard-cap multiplier in basis points.
        uint16 tierBps;
        /// @dev Maximum number of securities that may be listed in this tier.
        uint32 maxListed;
        /// @dev Number of securities currently assigned to this tier.
        uint32 listedCount;
    }

    /// @dev Records the evidence and timing associated with an emergency pause.
    struct EmergencyPause {
        /// @dev Scope of the pause, such as one token, security, pool, or all pools.
        PauseScope scope;
        /// @dev Scope-specific target identifier; zero for a global pause.
        bytes32 target;
        /// @dev Trading, ordinary LP operations, or both blocked by this record.
        PauseMode mode;
        /// @dev Operational reason assigned to the pause.
        bytes32 reasonCode;
        /// @dev Digest of the supporting incident evidence.
        bytes32 sourceHash;
        /// @dev Account that opened the pause.
        address openedBy;
        /// @dev Timestamp when the pause was opened.
        uint64 openedAt;
        /// @dev Whether this pause currently blocks operations.
        bool active;
    }

    address public hook;
    address public lpManager;
    address public dataInbox;
    uint256 public nextPauseId;

    mapping(bytes32 => SecurityConfig) private securities;
    mapping(bytes32 => bytes32) private symbolToSecurity;
    mapping(uint8 => TierPolicy) private tiers;
    mapping(address => TokenConfig) private tokens;
    mapping(address => uint32) public activePoolCountByCurrency;
    mapping(bytes32 => PoolConfig) private pools;
    mapping(bytes32 => uint64) public marketSequence;
    mapping(uint256 => EmergencyPause) public emergencyPauses;
    /// @notice Number of active records for exactly the specified scope, target, and mode.
    mapping(uint8 => mapping(bytes32 => mapping(uint8 => uint256))) public activePauseCount;
    ISmartWalletSbtV1 public participantSbt;
    uint256 public sbtTokenId;
    /// @notice Current market pause mask; admitted securities default to NONE.
    mapping(bytes32 => PauseMode) public marketPauseMode;

    /// @notice Emitted when core component addresses were bound to the Registry.
    event ComponentsBound(address indexed hook, address indexed lpManager, address indexed dataInbox);
    /// @notice Emitted when a security was added to the Registry with its listing tier and evidence.
    event SecurityListed(bytes32 indexed securityId, bytes32 symbolHash, uint8 tierId, bytes32 evidenceHash);
    /// @notice Emitted when a security was removed from the active listing set.
    event SecurityDelisted(bytes32 indexed securityId, bytes32 evidenceHash);
    /// @notice Emitted when a listed security was assigned a different tier.
    event SecurityTierChanged(bytes32 indexed securityId, uint8 oldTierId, uint8 newTierId, bytes32 evidenceHash);
    /// @notice Emitted when a security tier policy was created or updated.
    event TierPolicyChanged(uint8 indexed tierId, uint16 tierBps, uint32 maxListed, bytes32 evidenceHash);
    /// @notice Emitted when a Currency and its security metadata were registered.
    event TokenRegistered(address indexed poolCurrency, bytes32 indexed securityId, bytes32 evidenceHash);
    /// @notice Emitted when a registered Currency status was changed.
    event TokenStatusChanged(address indexed poolCurrency, uint8 oldStatus, uint8 newStatus, bytes32 evidenceHash);
    /// @notice Emitted when a Currency legal-share adapter was replaced.
    event LegalShareAdapterChanged(
        address indexed poolCurrency,
        address oldAdapter,
        address newAdapter,
        uint32 legalAdapterVersion,
        bytes32 evidenceHash
    );
    /// @notice Emitted when a pending pool completed initialization and became active.
    event PoolInitialized(
        bytes32 indexed poolId, uint160 sqrtPriceX96, address indexed creator, bytes32 priceBasisHash
    );
    /// @notice Emitted when a registered pool status was changed.
    event PoolStatusChanged(bytes32 indexed poolId, uint8 oldStatus, uint8 newStatus, bytes32 evidenceHash);
    /// @notice Emitted when a security market-state report was accepted.
    event MarketStatusChanged(
        bytes32 indexed securityId,
        uint8 oldStatus,
        uint8 newStatus,
        uint8 oldPauseMode,
        uint8 newPauseMode,
        uint64 sequence,
        bytes32 indexed reportId
    );
    /// @notice Emitted when an emergency pause record was opened.
    event EmergencyPauseOpened(
        uint256 indexed recordId, uint8 scope, bytes32 indexed target, uint8 mode, bytes32 reasonCode
    );
    /// @notice Emitted when an emergency pause record was closed.
    event EmergencyPauseClosed(uint256 indexed recordId, bytes32 reasonCode);
    /// @notice Emitted when the configured participant SBT or token identifier was changed.
    event SbtConfigChanged(
        address indexed oldSbt, address indexed newSbt, uint256 oldTokenId, uint256 newTokenId, bytes32 evidenceHash
    );

    /// @notice Initializes governance and starts emergency-pause IDs at one.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    function initialize(address anchor) external initializer {
        __TSVGoverned_init(anchor);
        nextPauseId = 1;
    }

    /// @notice Binds the Hook, LP Manager, and DataInbox once after all three are deployed.
    /// @param hook_ TSV Hook authorized for pool callbacks.
    /// @param lpManager_ LP Manager authorized to register and activate pools.
    /// @param dataInbox_ DataInbox authorized to apply market reports.
    function bindComponents(address hook_, address lpManager_, address dataInbox_) external onlyGovernor {
        if (hook != address(0) || lpManager != address(0) || dataInbox != address(0)) revert InvalidStatus();
        if (hook_.code.length == 0 || lpManager_.code.length == 0 || dataInbox_.code.length == 0) {
            revert InvalidConfig();
        }
        hook = hook_;
        lpManager = lpManager_;
        dataInbox = dataInbox_;
        emit ComponentsBound(hook_, lpManager_, dataInbox_);
    }

    /// @notice Sets a tier's quota multiplier and maximum number of listed securities.
    /// @param tierId Nonzero tier identifier.
    /// @param tierBps Volume multiplier in basis points, from 1 through 10,000.
    /// @param maxListed Maximum number of securities that may be listed in this tier.
    /// @param evidenceHash Nonzero digest of the policy evidence.
    function setTierPolicy(uint8 tierId, uint16 tierBps, uint32 maxListed, bytes32 evidenceHash) external onlyGovernor {
        TierPolicy storage tier = tiers[tierId];
        if (tierId == 0 || tierBps == 0 || tierBps > 10_000 || maxListed < tier.listedCount || evidenceHash == 0) {
            revert InvalidConfig();
        }
        tier.tierBps = tierBps;
        tier.maxListed = maxListed;
        emit TierPolicyChanged(tierId, tierBps, maxListed, evidenceHash);
    }

    /// @notice Returns the quota and listing-cap policy currently configured for `tierId`.
    /// @param tierId Tier identifier to query.
    /// @return Multiplier, capacity, and current listing count.
    function tierPolicy(uint8 tierId) external view returns (TierPolicy memory) {
        return tiers[tierId];
    }

    /// @notice Configures the participant SBT after checking that its required view methods respond.
    /// @param sbt_ SBT contract implementing `verify` and `paused`.
    /// @param tokenId_ Credential token ID checked for participants.
    /// @param evidenceHash Nonzero digest of the SBT configuration evidence.
    function setSbtConfig(address sbt_, uint256 tokenId_, bytes32 evidenceHash) external onlyGovernor {
        if (sbt_.code.length == 0 || evidenceHash == 0) revert InvalidConfig();
        // Validate both selectors at configuration time. This keeps a bad SBT
        // address from remaining latent until the first user operation.
        try ISmartWalletSbtV1(sbt_).paused() returns (bool) {}
        catch {
            revert InvalidConfig();
        }
        try ISmartWalletSbtV1(sbt_).verify(address(this), tokenId_) returns (bool) {}
        catch {
            revert InvalidConfig();
        }
        address oldSbt = address(participantSbt);
        uint256 oldTokenId = sbtTokenId;
        participantSbt = ISmartWalletSbtV1(sbt_);
        sbtTokenId = tokenId_;
        emit SbtConfigChanged(oldSbt, sbt_, oldTokenId, tokenId_, evidenceHash);
    }

    /// @notice Returns whether `owner` holds the configured credential, without checking global pause.
    /// @param owner Participant address whose credential is checked.
    /// @return Whether the configured SBT verifies the owner and token ID.
    function hasCredential(address owner) public view returns (bool) {
        if (address(participantSbt) == address(0)) revert SbtNotConfigured();
        return participantSbt.verify(owner, sbtTokenId);
    }

    /// @notice Returns whether SBT checks are active and `owner` holds the configured credential.
    /// @param owner Participant address whose eligibility is checked.
    /// @return Whether the SBT is unpaused and verifies the owner.
    function isEligible(address owner) external view returns (bool) {
        if (address(participantSbt) == address(0)) revert SbtNotConfigured();
        return !participantSbt.paused() && hasCredential(owner);
    }

    /// @notice Atomically lists a security and admits its first approved Currency.
    /// @param securityId Unique internal identifier for the security.
    /// @param symbolHash Unique digest of its display symbol or ticker.
    /// @param tierId Configured tier with available listing capacity.
    /// @param config Reviewed Token configuration bound to the new security.
    /// @param evidenceHash Nonzero digest of the admission evidence.
    function admitSecurity(
        bytes32 securityId,
        bytes32 symbolHash,
        uint8 tierId,
        TokenConfig calldata config,
        bytes32 evidenceHash
    ) external onlyRole(SYMBOL_ADMIN_ROLE) {
        if (
            securityId == 0 || symbolHash == 0 || evidenceHash == 0 || securities[securityId].securityId != 0
                || symbolToSecurity[symbolHash] != 0 || config.securityId != securityId
        ) revert InvalidConfig();
        _takeTierSlot(tierId);
        securities[securityId] = SecurityConfig(securityId, symbolHash, tierId, true, 0, 1);
        symbolToSecurity[symbolHash] = securityId;
        emit SecurityListed(securityId, symbolHash, tierId, evidenceHash);
        _registerToken(config, evidenceHash);
    }

    /// @notice Relists a delisted security under its existing symbol and tier.
    /// @param securityId Existing security to relist.
    /// @param evidenceHash Nonzero digest of the relisting evidence.
    function relistSecurity(bytes32 securityId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (config.securityId == 0 || config.listed || evidenceHash == 0) revert InvalidStatus();
        _takeTierSlot(config.tierId);
        config.listed = true;
        config.version++;
        emit SecurityListed(securityId, config.symbolHash, config.tierId, evidenceHash);
    }

    /// @notice Moves a listed security to another tier and updates both tier listing counts.
    /// @param securityId Listed security whose tier changes.
    /// @param tierId Configured destination tier with available capacity.
    /// @param evidenceHash Nonzero digest of the tier-change evidence.
    function setSecurityTier(bytes32 securityId, uint8 tierId, bytes32 evidenceHash)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed || config.tierId == tierId || evidenceHash == 0) revert InvalidStatus();
        _takeTierSlot(tierId);
        tiers[config.tierId].listedCount--;
        uint8 old = config.tierId;
        config.tierId = tierId;
        config.version++;
        emit SecurityTierChanged(securityId, old, tierId, evidenceHash);
    }

    /// @notice Delists a security only after all of its active pools have been disabled.
    /// @param securityId Listed security to remove from admission.
    /// @param evidenceHash Nonzero digest of the delisting evidence.
    function delistSecurity(bytes32 securityId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed || config.activePoolCount != 0 || evidenceHash == 0) revert InvalidStatus();
        config.listed = false;
        config.version++;
        tiers[config.tierId].listedCount--;
        emit SecurityDelisted(securityId, evidenceHash);
    }

    /// @notice Returns the stored listing, tier, version, and active-pool data for a security.
    /// @param securityId Security identifier to query.
    /// @return Stored security record; unknown IDs return a default record.
    function getSecurity(bytes32 securityId) external view returns (SecurityConfig memory) {
        return securities[securityId];
    }

    /// @notice Admits a quote token or another Currency for an already listed security.
    /// @param config Reviewed Token configuration; status must be APPROVED.
    /// @param evidenceHash Nonzero digest of the token admission evidence.
    function registerToken(TokenConfig calldata config, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        _registerToken(config, evidenceHash);
    }

    /// @dev Validates and stores an approved Currency without leaving a pending review state.
    function _registerToken(TokenConfig calldata config, bytes32 evidenceHash) private {
        if (
            config.poolCurrency == address(0) || config.status != TokenStatus.APPROVED || evidenceHash == 0
                || tokens[config.poolCurrency].poolCurrency != address(0) || config.poolDecimals > 18
                || config.reviewHash == 0 || config.poolCurrency.code.length == 0
        ) revert InvalidConfig();
        if (
            config.poolCurrency.codehash != config.poolRuntimeCodeHash
                || IERC20DecimalsV1(config.poolCurrency).decimals() != config.poolDecimals
        ) revert InvalidConfig();
        if (config.securityId == 0) {
            if (
                config.legalShareAdapter != address(0) || config.legalAdapterCodeHash != 0
                    || config.legalAdapterVersion != 0 || config.legalSharePolicyHash != 0
            ) revert InvalidConfig();
        } else {
            if (
                !securities[config.securityId].listed || config.legalShareAdapter.code.length == 0
                    || config.legalAdapterVersion != 1 || config.legalSharePolicyHash == 0
                    || config.legalShareAdapter.codehash != config.legalAdapterCodeHash
            ) {
                revert InvalidConfig();
            }
            _validateLegalShareAdapter(config.legalShareAdapter, config.poolCurrency, config.legalAdapterVersion);
        }
        tokens[config.poolCurrency] = config;
        emit TokenRegistered(config.poolCurrency, config.securityId, evidenceHash);
        emit TokenStatusChanged(
            config.poolCurrency, uint8(TokenStatus.ABSENT), uint8(TokenStatus.APPROVED), evidenceHash
        );
    }

    /// @notice Disables or re-enables an admitted token, enforcing approval prerequisites.
    /// @param currency Registered pool Currency to update.
    /// @param status APPROVED or DISABLED; ABSENT is not a valid transition.
    /// @param evidenceHash Nonzero digest of the status-change evidence.
    function setTokenStatus(address currency, TokenStatus status, bytes32 evidenceHash)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        TokenConfig storage config = tokens[currency];
        if (config.poolCurrency == address(0) || evidenceHash == 0 || config.status == status) revert InvalidStatus();
        if (status == TokenStatus.ABSENT) revert InvalidStatus();
        if (status == TokenStatus.APPROVED) {
            if (
                config.reviewHash == 0 || (config.securityId != 0 && config.legalSharePolicyHash == 0)
                    || config.poolCurrency.codehash != config.poolRuntimeCodeHash
            ) revert InvalidConfig();
            if (config.securityId != 0 && !securities[config.securityId].listed) revert InvalidStatus();
        }
        TokenStatus old = config.status;
        config.status = status;
        emit TokenStatusChanged(currency, uint8(old), uint8(status), evidenceHash);
    }

    /// @notice Replaces a security token's share adapter while its asset is paused for replacement.
    /// @param currency Registered stock Currency whose adapter is replaced.
    /// @param newAdapter Replacement direct legal-share adapter with the next version.
    /// @param evidenceHash Nonzero digest of the new conversion-policy evidence.
    function replaceLegalShareAdapter(address currency, address newAdapter, bytes32 evidenceHash)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        TokenConfig storage config = tokens[currency];
        if (
            config.poolCurrency == address(0) || config.securityId == 0 || newAdapter == config.legalShareAdapter
                || newAdapter.code.length == 0 || evidenceHash == 0 || !_assetPausedForReplacement(currency)
        ) revert InvalidConfig();
        uint32 nextVersion = config.legalAdapterVersion + 1;
        _validateLegalShareAdapter(newAdapter, currency, nextVersion);
        address oldAdapter = config.legalShareAdapter;
        config.legalShareAdapter = newAdapter;
        config.legalAdapterCodeHash = newAdapter.codehash;
        config.legalAdapterVersion = nextVersion;
        config.legalSharePolicyHash = evidenceHash;
        emit LegalShareAdapterChanged(currency, oldAdapter, newAdapter, nextVersion, evidenceHash);
    }

    /// @notice Returns the registered token configuration for `currency`.
    /// @param currency Pool Currency used as the Registry key.
    /// @return Stored token configuration; unknown addresses return a default record.
    function getToken(address currency) external view returns (TokenConfig memory) {
        return tokens[currency];
    }

    /// @notice Registers a pending pool for the LP Manager after validating its key and currencies.
    /// @param key Candidate V4 pool key.
    /// @return poolId Identifier derived from the full pool key.
    function registerPendingPool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (msg.sender != lpManager) revert InvalidPool();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != hook || c0 == address(0) || c0 >= c1 || key.fee >= 1_000_000 || key.tickSpacing < 1
                || key.tickSpacing > 32767 || tokens[c0].status != TokenStatus.APPROVED
                || tokens[c1].status != TokenStatus.APPROVED
        ) revert InvalidPool();
        bytes32 s0 = tokens[c0].securityId;
        bytes32 s1 = tokens[c1].securityId;
        if (s0 != 0 && s1 != 0) revert InvalidPool();
        poolId = PoolId.unwrap(key.toId());
        if (pools[poolId].status != PoolStatus.ABSENT) revert InvalidPool();
        pools[poolId] = PoolConfig(key, s0, s1, PoolStatus.PENDING, 1);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.ABSENT), uint8(PoolStatus.PENDING), 0);
    }

    /// @notice Activates a pending pool and increments its currencies' and security's active-pool counts.
    /// @param poolId Registered pending pool to activate.
    /// @param sqrtPriceX96 Initial price used by PoolManager.
    /// @param creator Address that created the pool.
    /// @param priceBasisHash Nonzero digest of the initial-price evidence.
    function markPoolActive(bytes32 poolId, uint160 sqrtPriceX96, address creator, bytes32 priceBasisHash) external {
        if (msg.sender != lpManager || pools[poolId].status != PoolStatus.PENDING) revert InvalidPool();
        PoolConfig storage pool = pools[poolId];
        pool.status = PoolStatus.ACTIVE;
        pool.version++;
        activePoolCountByCurrency[Currency.unwrap(pool.key.currency0)]++;
        activePoolCountByCurrency[Currency.unwrap(pool.key.currency1)]++;
        if (pool.securityId0 != 0) securities[pool.securityId0].activePoolCount++;
        if (pool.securityId1 != 0) securities[pool.securityId1].activePoolCount++;
        emit PoolInitialized(poolId, sqrtPriceX96, creator, priceBasisHash);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.PENDING), uint8(PoolStatus.ACTIVE), 0);
    }

    /// @notice Disables an active pool and decrements its currencies' and security's active-pool counts.
    /// @param poolId Active pool to disable.
    /// @param evidenceHash Nonzero digest of the disabling evidence.
    function disablePool(bytes32 poolId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.ACTIVE || evidenceHash == 0) revert InvalidStatus();
        pool.status = PoolStatus.DISABLED;
        pool.version++;
        activePoolCountByCurrency[Currency.unwrap(pool.key.currency0)]--;
        activePoolCountByCurrency[Currency.unwrap(pool.key.currency1)]--;
        if (pool.securityId0 != 0) securities[pool.securityId0].activePoolCount--;
        if (pool.securityId1 != 0) securities[pool.securityId1].activePoolCount--;
        emit PoolStatusChanged(poolId, uint8(PoolStatus.ACTIVE), uint8(PoolStatus.DISABLED), evidenceHash);
    }

    /// @notice Re-enables a disabled pool only when both tokens and listed securities remain valid.
    /// @param poolId Disabled pool to enable.
    /// @param evidenceHash Nonzero digest of the re-enablement evidence.
    function enablePool(bytes32 poolId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.DISABLED || evidenceHash == 0) revert InvalidStatus();
        address c0 = Currency.unwrap(pool.key.currency0);
        address c1 = Currency.unwrap(pool.key.currency1);
        if (
            tokens[c0].status != TokenStatus.APPROVED || tokens[c1].status != TokenStatus.APPROVED
                || (pool.securityId0 != 0 && !securities[pool.securityId0].listed)
                || (pool.securityId1 != 0 && !securities[pool.securityId1].listed)
        ) revert InvalidStatus();
        pool.status = PoolStatus.ACTIVE;
        pool.version++;
        if (!_isOperationAllowed(poolId, PauseMode.TRADE) || !_isOperationAllowed(poolId, PauseMode.LP)) {
            revert InvalidStatus();
        }
        activePoolCountByCurrency[c0]++;
        activePoolCountByCurrency[c1]++;
        if (pool.securityId0 != 0) securities[pool.securityId0].activePoolCount++;
        if (pool.securityId1 != 0) securities[pool.securityId1].activePoolCount++;
        emit PoolStatusChanged(poolId, uint8(PoolStatus.DISABLED), uint8(PoolStatus.ACTIVE), evidenceHash);
    }

    /// @notice Returns the registered key, securities, status, and version for a pool.
    /// @param poolId Pool identifier to query.
    /// @return Stored pool record; unknown IDs return a default record.
    function getPool(bytes32 poolId) external view returns (PoolConfig memory) {
        return pools[poolId];
    }

    /// @notice Returns whether the pool has been registered, regardless of its current status.
    /// @param poolId Pool identifier to query.
    /// @return Whether the pool status is not ABSENT.
    function isKnownPool(bytes32 poolId) external view returns (bool) {
        return pools[poolId].status != PoolStatus.ABSENT;
    }

    /// @notice Derives the market state from a known security's pause mask.
    /// @param securityId Security identifier to query.
    /// @return OPEN when no market pause applies, otherwise HALTED; unknown IDs revert.
    function marketStatus(bytes32 securityId) external view returns (MarketStatus) {
        if (securities[securityId].securityId == 0) revert InvalidConfig();
        return marketPauseMode[securityId] == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED;
    }

    /// @notice Applies the next valid market-state transition from the bound DataInbox.
    /// @param securityId Listed security whose market state changes.
    /// @param action Halt or resume action from the report.
    /// @param mode Operations affected by this action: TRADE, LP, or ALL.
    /// @param sequence Report sequence for this security.
    /// @param reportId Unique ID of the accepted MarketReport.
    function applyMarketStatus(
        bytes32 securityId,
        MarketAction action,
        PauseMode mode,
        uint64 sequence,
        bytes32 reportId
    ) external {
        if (
            msg.sender != dataInbox || securityId == 0 || !securities[securityId].listed
                || sequence <= marketSequence[securityId] || mode == PauseMode.NONE
        ) revert InvalidStatus();
        PauseMode oldMode = marketPauseMode[securityId];
        MarketStatus old = oldMode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED;
        PauseMode nextMode;
        if (action == MarketAction.HALT) nextMode = PauseMode(uint8(oldMode) | uint8(mode));
        else if (action == MarketAction.RESUME) nextMode = PauseMode(uint8(oldMode) & ~uint8(mode));
        else revert InvalidStatus();
        if (nextMode == oldMode) revert InvalidStatus();
        MarketStatus next = nextMode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED;
        marketPauseMode[securityId] = nextMode;
        marketSequence[securityId] = sequence;
        emit MarketStatusChanged(
            securityId, uint8(old), uint8(next), uint8(oldMode), uint8(nextMode), sequence, reportId
        );
    }

    /// @notice Opens a scoped emergency pause and returns its record ID.
    /// @param scope GLOBAL, SECURITY, TOKEN, or POOL pause scope.
    /// @param target Scope-specific target key; zero only for GLOBAL.
    /// @param mode TRADE, LP, or ALL; NONE cannot open a pause record.
    /// @param reasonCode Nonzero operational reason code.
    /// @param sourceHash Nonzero digest of the incident source material.
    /// @return recordId New emergency-pause record identifier.
    function addEmergencyPause(PauseScope scope, bytes32 target, PauseMode mode, bytes32 reasonCode, bytes32 sourceHash)
        external
        onlyRole(EMERGENCY_PAUSER_ROLE)
        returns (uint256 recordId)
    {
        if (
            mode == PauseMode.NONE || reasonCode == 0 || sourceHash == 0 || (scope == PauseScope.GLOBAL && target != 0)
                || (scope != PauseScope.GLOBAL && target == 0)
        ) revert InvalidConfig();
        recordId = nextPauseId++;
        emergencyPauses[recordId] =
            EmergencyPause(scope, target, mode, reasonCode, sourceHash, msg.sender, uint64(block.timestamp), true);
        activePauseCount[uint8(scope)][target][uint8(mode)]++;
        emit EmergencyPauseOpened(recordId, uint8(scope), target, uint8(mode), reasonCode);
    }

    /// @notice Closes an active emergency-pause record and decrements its scope's active count.
    /// @param recordId Active pause record to close.
    /// @param reasonCode Nonzero reason code for clearing the pause.
    function clearEmergencyPause(uint256 recordId, bytes32 reasonCode) external onlyRole(EMERGENCY_RESUMER_ROLE) {
        EmergencyPause storage record = emergencyPauses[recordId];
        if (!record.active || reasonCode == 0) revert InvalidStatus();
        record.active = false;
        activePauseCount[uint8(record.scope)][record.target][uint8(record.mode)]--;
        emit EmergencyPauseClosed(recordId, reasonCode);
    }

    /// @notice Returns whether a pool permits swaps after status and trading-pause checks.
    /// @param poolId Pool identifier to check.
    /// @return Whether pool and asset admission checks pass and no trading pause applies.
    function isTradable(bytes32 poolId) external view returns (bool) {
        return _isOperationAllowed(poolId, PauseMode.TRADE);
    }

    /// @notice Returns whether a pool permits ordinary LP operations after status and LP-pause checks.
    /// @param poolId Pool identifier to check.
    /// @return Whether pool and asset admission checks pass and no LP pause applies.
    function isLPAllowed(bytes32 poolId) external view returns (bool) {
        return _isOperationAllowed(poolId, PauseMode.LP);
    }

    /// @dev Applies common admission checks and pauses for exactly one operation type.
    function _isOperationAllowed(bytes32 poolId, PauseMode operation) private view returns (bool) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.ACTIVE) return false;
        address c0 = Currency.unwrap(pool.key.currency0);
        address c1 = Currency.unwrap(pool.key.currency1);
        if (tokens[c0].status != TokenStatus.APPROVED || tokens[c1].status != TokenStatus.APPROVED) return false;
        if (
            _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.POOL, poolId, operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(c0), operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(c1), operation)
        ) return false;
        if (pool.securityId0 != 0 && !_isSecurityAllowed(pool.securityId0, operation)) return false;
        if (pool.securityId1 != 0 && !_isSecurityAllowed(pool.securityId1, operation)) return false;
        return true;
    }

    /// @dev Admitted securities default to open and are blocked only by listing and matching pauses.
    function _isSecurityAllowed(bytes32 securityId, PauseMode operation) private view returns (bool) {
        return securities[securityId].listed && (uint8(marketPauseMode[securityId]) & uint8(operation)) == 0
            && !_isPaused(PauseScope.SECURITY, securityId, operation);
    }

    /// @dev Checks the tier is configured and below capacity, then reserves one listing slot.
    /// @param tierId Tier whose listing slot is reserved.
    function _takeTierSlot(uint8 tierId) private {
        TierPolicy storage tier = tiers[tierId];
        if (tierId == 0 || tier.tierBps == 0 || tier.listedCount >= tier.maxListed) revert InvalidConfig();
        tier.listedCount++;
    }

    /// @dev Verifies the adapter interface and that it reports the expected currency and version.
    /// @param adapter Adapter address being validated.
    /// @param currency Expected pool Currency.
    /// @param version Expected adapter version.
    function _validateLegalShareAdapter(address adapter, address currency, uint32 version) private view {
        IDirectLegalShareAdapter directAdapter = IDirectLegalShareAdapter(adapter);
        try directAdapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId) returns (bool supported) {
            if (!supported) revert InvalidConfig();
        } catch {
            revert InvalidConfig();
        }
        if (directAdapter.poolCurrency() != currency || directAdapter.adapterVersion() != version) {
            revert InvalidConfig();
        }
    }

    /// @dev Allows adapter replacement when no pool uses the currency or both operation types are emergency-paused.
    /// @param currency Pool Currency whose replacement conditions are checked.
    /// @return Whether no active pool uses the currency or global/token records cover both operation types.
    function _assetPausedForReplacement(address currency) private view returns (bool) {
        if (activePoolCountByCurrency[currency] == 0) return true;
        bytes32 target = _addressKey(currency);
        return (_isPaused(PauseScope.GLOBAL, 0, PauseMode.TRADE)
                || _isPaused(PauseScope.TOKEN, target, PauseMode.TRADE))
            && (_isPaused(PauseScope.GLOBAL, 0, PauseMode.LP) || _isPaused(PauseScope.TOKEN, target, PauseMode.LP));
    }

    /// @dev Checks whether the operation's exact mode or ALL has an active pause record.
    /// @param scope Pause scope to inspect.
    /// @param target Scope-specific target key.
    /// @param operation TRADE or LP operation to inspect.
    /// @return Whether the active pause count is nonzero.
    function _isPaused(PauseScope scope, bytes32 target, PauseMode operation) private view returns (bool) {
        return activePauseCount[uint8(scope)][target][uint8(operation)] != 0
            || activePauseCount[uint8(scope)][target][uint8(PauseMode.ALL)] != 0;
    }

    /// @dev Encodes an address as the bytes32 target key used by token-scoped pauses.
    /// @param a Address to encode.
    /// @return Address left-padded to bytes32.
    function _addressKey(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

```

### src/v1/legacy/IssuerShareSettlementAdapter.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAssetSettlementAdapter} from "tsv-v1/legacy/IAssetSettlementAdapter.sol";

/// @dev Defines the issuer share token methods used by the settlement adapter.
interface IBackedShares is IERC20 {
    /// @notice Returns the issuer's exact share units held by `account`.
    function sharesOf(address account) external view returns (uint256);

    /// @notice Transfers exact issuer-share units using the issuer's share-aware transfer method.
    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool);

    /// @notice Converts issuer-share units into the token's displayed underlying amount.
    function getUnderlyingAmountByShares(uint256 shares) external view returns (uint256);
}

/// @dev Defines the wrapped issuer token methods used for asset conversion.
interface IIssuerWrapped is IERC20 {
    /// @notice Returns the issuer asset wrapped by this token.
    function asset() external view returns (address);

    /// @notice Mints wrapped shares by pulling the corresponding underlying amount.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Burns wrapped shares and delivers their underlying representation.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Returns the total wrapped-share supply.
    function totalSupply() external view returns (uint256);
}

/// @dev Exposes the active asset operation used to authorize adapter settlement.
interface IActiveAssetOperation {
    /// @notice Returns the active router or LP operation context for a wrapped pool currency.
    /// @param operationId Operation identifier supplied by the settlement adapter caller.
    /// @param poolCurrency Wrapped currency whose operation context is requested.
    /// @return poolId Pool associated with the active operation.
    /// @return owner Original account whose assets are being moved.
    /// @return recipient Account that must receive redeemed assets.
    /// @return forceExit Whether the operation is an administrative forced exit.
    function activeAssetOperation(bytes32 operationId, address poolCurrency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit);
}

/// @notice Binds one issuer's variable-balance token to its existing stable wrapper.
contract IssuerShareSettlementAdapter is IAssetSettlementAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the requested operation is not valid in the current state or callback context.
    error InvalidOperation();
    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();
    /// @dev Reverts when the actual amount falls outside the caller supplied bounds.
    error SlippageExceeded();

    /// @dev Stores the amounts and snapshots prepared for an asset settlement operation.
    struct Prepared {
        /// @dev Identifier of the active operation.
        bytes32 operationId;
        /// @dev Account that initiated the active operation.
        address caller;
        /// @dev Issuer-share amount prepared for settlement.
        uint256 shares;
        /// @dev Adapter's wrapped-token balance captured before the operation.
        uint256 wrappedBefore;
        /// @dev Adapter's issuer-share balance captured before the operation.
        uint256 underlyingSharesBefore;
    }

    /// @dev Stores balances and conversion values captured before a token pull.
    struct PullSnapshot {
        /// @dev Owner's issuer-share balance before the pull.
        uint256 ownerShares;
        /// @dev Owner's displayed token balance before the pull.
        uint256 ownerDisplayed;
        /// @dev Adapter's issuer-share balance before the pull.
        uint256 adapterShares;
        /// @dev Vault's issuer-share balance before the pull.
        uint256 vaultShares;
        /// @dev Wrapped-token total supply before the pull.
        uint256 wrapperSupply;
        /// @dev Adapter's wrapped-token balance before the pull.
        uint256 adapterWrapped;
        /// @dev Receiver's wrapped-token balance before the pull.
        uint256 receiverWrapped;
    }

    /// @dev Stores balances and conversion values captured before a redemption.
    struct RedeemSnapshot {
        /// @dev Recipient's issuer-share balance before redemption.
        uint256 recipientShares;
        /// @dev Recipient's displayed token balance before redemption.
        uint256 recipientDisplayed;
        /// @dev Vault's issuer-share balance before redemption.
        uint256 vaultShares;
        /// @dev Wrapped-token total supply before redemption.
        uint256 wrapperSupply;
    }

    IBackedShares private immutable underlying;
    IIssuerWrapped private immutable wrapped;
    address public immutable router;
    address public immutable lpManager;
    Prepared private prepared;

    /// @notice Binds one issuer share token and wrapper to the Router and LP Manager that may use them.
    /// @param underlying_ Issuer token exposing share-aware transfers and conversions.
    /// @param wrapped_ Issuer wrapper used as the PoolManager Currency.
    /// @param router_ Authorized swap caller.
    /// @param lpManager_ Authorized liquidity caller.
    constructor(address underlying_, address wrapped_, address router_, address lpManager_) {
        if (
            underlying_.code.length == 0 || wrapped_.code.length == 0 || router_ == address(0)
                || lpManager_ == address(0) || underlying_ == wrapped_
                || IIssuerWrapped(wrapped_).asset() != underlying_
        ) revert InvalidOperation();
        underlying = IBackedShares(underlying_);
        wrapped = IIssuerWrapped(wrapped_);
        router = router_;
        lpManager = lpManager_;
    }

    /// @notice Returns the underlying issuer token used by the legacy path.
    function userToken() external view returns (address) {
        return address(underlying);
    }

    /// @notice Returns the wrapper token used as the legacy pool Currency.
    function poolCurrency() external view returns (address) {
        return address(wrapped);
    }

    /// @notice Pulls exact issuer shares, mints the same number of wrapped shares, and delivers them.
    /// @dev Checks share balances, wrapper supply, displayed debit, and every token balance change.
    /// @param owner Account whose shares are pulled.
    /// @param receiver Account receiving wrapped shares; must be the authorized calling manager.
    /// @param shares Exact number of shares to wrap.
    /// @param maxDisplayedDebit Maximum displayed underlying debit allowed for `owner`.
    /// @param operationId Active operation whose owner and pool currency must match.
    /// @return wrappedDelivered Wrapped shares transferred to `receiver`.
    function pullAndWrap(
        address owner,
        address receiver,
        uint256 shares,
        uint256 maxDisplayedDebit,
        bytes32 operationId
    ) external nonReentrant returns (uint256 wrappedDelivered) {
        (address contextOwner,,) = _requireContext(operationId);
        if (
            prepared.operationId != 0 || shares == 0 || owner == address(0) || owner == address(this)
                || owner != contextOwner || receiver != msg.sender || maxDisplayedDebit == 0
        ) revert InvalidOperation();

        PullSnapshot memory p = PullSnapshot(
            underlying.sharesOf(owner),
            underlying.balanceOf(owner),
            underlying.sharesOf(address(this)),
            underlying.sharesOf(address(wrapped)),
            wrapped.totalSupply(),
            wrapped.balanceOf(address(this)),
            wrapped.balanceOf(receiver)
        );

        if (!underlying.transferSharesFrom(owner, address(this), shares)) revert SettlementMismatch();
        if (
            p.ownerShares < shares || underlying.sharesOf(owner) != p.ownerShares - shares
                || underlying.sharesOf(address(this)) != p.adapterShares + shares
        ) revert SettlementMismatch();
        uint256 displayedAllowance = underlying.getUnderlyingAmountByShares(shares);
        if (displayedAllowance == 0) revert SettlementMismatch();
        IERC20(address(underlying)).forceApprove(address(wrapped), 0);
        IERC20(address(underlying)).forceApprove(address(wrapped), displayedAllowance);
        wrapped.mint(shares, address(this));
        IERC20(address(underlying)).forceApprove(address(wrapped), 0);
        if (
            underlying.sharesOf(address(this)) != p.adapterShares
                || underlying.sharesOf(address(wrapped)) != p.vaultShares + shares
                || wrapped.totalSupply() != p.wrapperSupply + shares
                || wrapped.balanceOf(address(this)) != p.adapterWrapped + shares
        ) revert SettlementMismatch();

        IERC20(address(wrapped)).safeTransfer(receiver, shares);
        if (
            wrapped.balanceOf(address(this)) != p.adapterWrapped
                || wrapped.balanceOf(receiver) != p.receiverWrapped + shares
        ) revert SettlementMismatch();
        uint256 ownerDisplayedAfter = underlying.balanceOf(owner);
        if (p.ownerDisplayed < ownerDisplayedAfter || p.ownerDisplayed - ownerDisplayedAfter > maxDisplayedDebit) {
            revert SlippageExceeded();
        }
        return shares;
    }

    /// @notice Records the expected redemption amount before the caller transfers wrapped shares in.
    /// @param shares Exact wrapped-share amount expected for redemption.
    /// @param operationId Active operation whose recipient must receive the underlying shares.
    function prepareReceive(uint256 shares, bytes32 operationId) external nonReentrant {
        (, address recipient,) = _requireContext(operationId);
        if (prepared.operationId != 0 || operationId == 0 || shares == 0 || recipient == address(0)) {
            revert InvalidOperation();
        }
        prepared = Prepared(
            operationId, msg.sender, shares, wrapped.balanceOf(address(this)), underlying.sharesOf(address(this))
        );
    }

    /// @notice Redeems the prepared wrapped shares and verifies exact share delivery and displayed-credit bounds.
    /// @param recipient Recipient bound by the active operation context.
    /// @param shares Exact wrapped-share amount previously prepared and transferred to this adapter.
    /// @param minDisplayedCredit Minimum displayed underlying balance increase; forced exits require zero.
    /// @param operationId Active operation that authorized the redemption.
    /// @return sharesDelivered Issuer shares delivered to `recipient`.
    function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
        external
        nonReentrant
        returns (uint256 sharesDelivered)
    {
        (, address contextRecipient, bool forceExit) = _requireContext(operationId);
        Prepared memory p = prepared;
        if (
            p.operationId != operationId || p.caller != msg.sender || p.shares != shares || shares == 0
                || contextRecipient != recipient || recipient == address(0) || (forceExit && minDisplayedCredit != 0)
                || wrapped.balanceOf(address(this)) != p.wrappedBefore + shares
        ) revert InvalidOperation();

        RedeemSnapshot memory s = RedeemSnapshot(
            underlying.sharesOf(recipient),
            underlying.balanceOf(recipient),
            underlying.sharesOf(address(wrapped)),
            wrapped.totalSupply()
        );

        wrapped.redeem(shares, recipient, address(this));
        if (
            underlying.sharesOf(recipient) != s.recipientShares + shares || s.vaultShares < shares
                || underlying.sharesOf(address(wrapped)) != s.vaultShares - shares || s.wrapperSupply < shares
                || wrapped.totalSupply() != s.wrapperSupply - shares
                || wrapped.balanceOf(address(this)) != p.wrappedBefore
                || underlying.sharesOf(address(this)) != p.underlyingSharesBefore
        ) revert SettlementMismatch();
        uint256 displayedAfter = underlying.balanceOf(recipient);
        if (displayedAfter < s.recipientDisplayed || displayedAfter - s.recipientDisplayed < minDisplayedCredit) {
            revert SlippageExceeded();
        }
        delete prepared;
        return shares;
    }

    /// @dev Checks the caller is a configured manager and that its active context names valid owner and recipient.
    /// @param operationId Operation ID to validate against the calling manager.
    /// @return owner Original owner recorded by the active operation.
    /// @return recipient Recipient recorded by the active operation.
    /// @return forceExit Whether the operation uses the forced-exit path.
    function _requireContext(bytes32 operationId)
        private
        view
        returns (address owner, address recipient, bool forceExit)
    {
        if (msg.sender != router && msg.sender != lpManager) revert Unauthorized();
        (bytes32 poolId, address o, address r, bool forced) =
            IActiveAssetOperation(msg.sender).activeAssetOperation(operationId, address(wrapped));
        if (poolId == 0 || o == address(0) || r == address(0)) revert InvalidOperation();
        return (o, r, forced);
    }
}

```

### src/v1/legacy/IAssetSettlementAdapter.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Defines asset preparation and settlement hooks for issuer-backed tokens.
interface IAssetSettlementAdapter {
    /// @notice Returns the user-facing token accepted by this legacy settlement adapter.
    function userToken() external view returns (address);

    /// @notice Returns the wrapped or pool Currency used for V4 settlement.
    function poolCurrency() external view returns (address);

    /// @notice Pulls user tokens and delivers the requested pool Currency to a receiver.
    /// @param owner User whose token balance is debited.
    /// @param receiver Address receiving the pool Currency.
    /// @param shares Pool-currency amount to deliver.
    /// @param maxDisplayedDebit Maximum user-token amount that may be pulled.
    /// @param operationId Identifier binding this transfer to its enclosing legacy operation.
    /// @return wrappedDelivered Actual pool-Currency amount delivered.
    function pullAndWrap(
        address owner,
        address receiver,
        uint256 shares,
        uint256 maxDisplayedDebit,
        bytes32 operationId
    ) external returns (uint256 wrappedDelivered);
    /// @notice Prepares the adapter to accept the specified pool-Currency amount for redemption.
    /// @param shares Pool-currency amount expected from the caller.
    /// @param operationId Identifier binding this preparation to its enclosing legacy operation.
    function prepareReceive(uint256 shares, bytes32 operationId) external;

    /// @notice Redeems pool Currency and delivers the underlying user token to a recipient.
    /// @param recipient Address receiving the user token.
    /// @param shares Pool-currency amount to redeem.
    /// @param minDisplayedCredit Minimum underlying-token amount that must be delivered.
    /// @param operationId Identifier binding this redemption to its enclosing legacy operation.
    /// @return sharesDelivered Actual pool-currency amount processed by the adapter.
    function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
        external
        returns (uint256 sharesDelivered);
}

```

### src/v1/libraries/ReportValidationLib.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pure validation shared by market, ADTV and quota report ingress.
library ReportValidationLib {
    /// @dev Reverts when the report fields or replay-protection metadata are invalid.
    error InvalidReport();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();

    /// @notice Enforces shared report identity, ordering, freshness, and deadline constraints.
    /// @param previousSequence Last accepted sequence for this report stream.
    /// @param previousSourceTimestamp Last accepted source timestamp for this stream.
    /// @param reportIdUsed Whether the report identifier has already been accepted.
    /// @param sourceTimestamp Timestamp when the source data was produced.
    /// @param submitDeadline Latest timestamp at which this report may be accepted.
    /// @param sequence Sequence supplied by the reporter for this stream.
    /// @param reportId Unique report identifier.
    /// @param sourceHash Digest of the report's supporting source material.
    /// @param currentTimestamp Current block timestamp supplied by the caller.
    function validate(
        uint64 previousSequence,
        uint64 previousSourceTimestamp,
        bool reportIdUsed,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        bytes32 sourceHash,
        uint256 currentTimestamp
    ) internal pure {
        if (
            reportId == 0 || sourceHash == 0 || reportIdUsed || sequence <= previousSequence
                || sourceTimestamp < previousSourceTimestamp
        ) revert InvalidReport();
        if (sourceTimestamp > currentTimestamp || currentTimestamp > submitDeadline) revert Expired();
    }
}

```

### src/v1/libraries/TradeDayLib.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Gregorian date math shared by trade-day and monthly report accounting.
library TradeDayLib {
    /// @dev Reverts when the supplied date or reporting period is invalid.
    error InvalidPeriod();

    /// @notice Converts a validated YYYYMMDD Gregorian date to days since the Unix epoch.
    /// @param date Calendar date encoded as YYYYMMDD.
    /// @return ordinal Zero-based day count from 1970-01-01.
    function dateToOrdinal(uint32 date) internal pure returns (uint256 ordinal) {
        uint256 year = date / 10_000;
        uint256 month = (date / 100) % 100;
        uint256 day = date % 100;
        if (year < 1970 || year > 9999 || month == 0 || month > 12 || day == 0) revert InvalidPeriod();
        uint256 daysInMonth = _daysInMonth(year, month);
        if (day > daysInMonth) revert InvalidPeriod();
        uint256 adjustedYear = month <= 2 ? year - 1 : year;
        uint256 era = adjustedYear / 400;
        uint256 yearOfEra = adjustedYear - era * 400;
        uint256 adjustedMonth = month > 2 ? month - 3 : month + 9;
        uint256 dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1;
        uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        ordinal = era * 146_097 + dayOfEra - 719_468;
    }

    /// @notice Converts days since the Unix epoch to a YYYYMMDD Gregorian date.
    /// @param ordinal Zero-based day count from 1970-01-01.
    /// @return Calendar date encoded as YYYYMMDD.
    function ordinalToDate(uint256 ordinal) internal pure returns (uint32) {
        uint256 z = ordinal + 719_468;
        uint256 era = z / 146_097;
        uint256 dayOfEra = z - era * 146_097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        uint256 year = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        uint256 day = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        uint256 month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        year += month <= 2 ? 1 : 0;
        if (year < 1970 || year > 9999) revert InvalidPeriod();
        return uint32(year * 10_000 + month * 100 + day);
    }

    /// @notice Returns the calendar month immediately before the month containing `day`.
    /// @param day Valid calendar date encoded as YYYYMMDD.
    /// @return Previous month encoded as YYYYMM.
    function previousMonth(uint32 day) internal pure returns (uint32) {
        uint256 year = day / 10_000;
        uint256 month = (day / 100) % 100;
        dateToOrdinal(day);
        if (month == 1) return uint32((year - 1) * 100 + 12);
        return uint32(year * 100 + month - 1);
    }

    /// @notice Checks whether a YYYYMM value is within the supported Gregorian range.
    /// @param monthId Candidate month encoded as YYYYMM.
    /// @return Whether the year and month are valid.
    function validMonth(uint32 monthId) internal pure returns (bool) {
        return monthId / 100 >= 1970 && monthId / 100 <= 9999 && monthId % 100 >= 1 && monthId % 100 <= 12;
    }

    /// @notice Safely narrows a timestamp to the 64-bit storage format.
    /// @param timestamp Timestamp in seconds since the Unix epoch.
    /// @return Timestamp represented as `uint64`.
    function timestamp64(uint256 timestamp) internal pure returns (uint64) {
        if (timestamp > type(uint64).max) revert InvalidPeriod();
        return uint64(timestamp);
    }

    /// @dev Returns the Gregorian month length, accounting for February's leap day.
    /// @param year Gregorian calendar year.
    /// @param month Month number from 1 through 12.
    /// @return Number of days in the month.
    function _daysInMonth(uint256 year, uint256 month) private pure returns (uint256) {
        if (month == 2) return _isLeapYear(year) ? 29 : 28;
        if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
        return 31;
    }

    /// @dev Applies the Gregorian leap-year rule.
    /// @param year Gregorian calendar year.
    /// @return Whether `year` contains February 29.
    function _isLeapYear(uint256 year) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }
}

```

### src/v1/libraries/TSVDirectSettlementLib.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Exact ERC-20 settlement helpers for TSV's direct-currency paths.
library TSVDirectSettlementLib {
    using SafeERC20 for IERC20;

    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();

    /// @notice Settles a PoolManager debt by pulling an exact ERC-20 amount from the payer.
    /// @dev Verifies payer debit, PoolManager credit, and the amount acknowledged by `settle`.
    /// @param poolManager V4 PoolManager with the outstanding currency debt.
    /// @param currency Currency whose debt is being settled.
    /// @param token ERC-20 address corresponding to `currency`.
    /// @param payer Address that approved the transfer.
    /// @param amount Exact amount to transfer and settle.
    function settleFrom(IPoolManager poolManager, Currency currency, address token, address payer, uint256 amount)
        internal
    {
        poolManager.sync(currency);
        uint256 payerBefore = IERC20(token).balanceOf(payer);
        uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
        IERC20(token).safeTransferFrom(payer, address(poolManager), amount);
        uint256 payerAfter = IERC20(token).balanceOf(payer);
        uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
        if (
            payerAfter > payerBefore || payerBefore - payerAfter != amount || poolAfter < poolBefore
                || poolAfter - poolBefore != amount || poolManager.settle() != amount
        ) revert SettlementMismatch();
    }

    /// @notice Takes an exact PoolManager credit and verifies both sides' balance changes.
    /// @param poolManager V4 PoolManager holding the currency credit.
    /// @param currency Currency being withdrawn.
    /// @param token ERC-20 address corresponding to `currency`.
    /// @param recipient Address receiving the transferred tokens.
    /// @param amount Exact amount to take and deliver.
    function takeTo(IPoolManager poolManager, Currency currency, address token, address recipient, uint256 amount)
        internal
    {
        uint256 poolBefore = IERC20(token).balanceOf(address(poolManager));
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        poolManager.take(currency, recipient, amount);
        uint256 poolAfter = IERC20(token).balanceOf(address(poolManager));
        uint256 recipientAfter = IERC20(token).balanceOf(recipient);
        if (
            poolAfter > poolBefore || poolBefore - poolAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert SettlementMismatch();
    }
}

```

### src/v1/periphery/TSVSwapRouterV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";

/// @notice One-pool credential-gated swap entry for direct users and approved external Adapters.
contract TSVSwapRouterV1 is TSVGoverned {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the swap request contains invalid amounts, bounds, or parameters.
    error InvalidRequest();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();
    /// @dev Reverts when the actual amount falls outside the caller supplied bounds.
    error SlippageExceeded();
    /// @dev Reverts when the input amount cannot be represented by the PoolManager delta type.
    error InputAmountTooLarge();
    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();
    /// @dev Reverts when a second operation was attempted while another operation is active.
    error Reentrancy();
    /// @dev Reverts when an address is not a valid external Adapter.
    error InvalidAdapter();
    /// @dev Reverts when the caller is not an approved external Adapter.
    error AdapterNotAllowed();

    uint160 private constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 private constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    bool private entered;

    /// @dev Appended after the existing Router storage for UUPS layout compatibility.
    mapping(address adapter => bool allowed) public isAdapterAllowed;

    /// @notice Emitted when a validated one-pool swap completed and its actual deltas were recorded.
    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    /// @notice Emitted when an approved Adapter settles a swap for an eligible user.
    event AdapterSwapExecuted(
        bytes32 indexed poolId,
        address indexed adapter,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    /// @notice Emitted when governance changes an external Adapter's authorization.
    event AdapterAuthorizationUpdated(address indexed adapter, bool allowed);

    /// @notice Initializes governance and binds the PoolManager, Registry, and Volume Ledger.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param poolManager_ V4 PoolManager used to execute swaps and settle deltas.
    /// @param registry_ Registry used for SBT eligibility and pool tradability checks.
    /// @param ledger_ Volume Ledger used to read the trade day for swap events.
    function initialize(address anchor, address poolManager_, address registry_, address ledger_) external initializer {
        __TSVGoverned_init(anchor);
        if (poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0) {
            revert InvalidRequest();
        }
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    /// @dev Prevents nested user swaps while the PoolManager invokes the unlock callback.
    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Executes a direct, single-pool swap with an exact input amount.
    /// @param request Pool, direction, input amount, minimum output, and deadline.
    /// @return actualIn Input Currency amount actually paid by the caller.
    /// @return actualOut Output Currency amount actually received by the caller.
    function swapExactInput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, true);
    }

    /// @notice Executes a direct, single-pool swap for an exact output amount.
    /// @param request Pool, direction, output amount, maximum input, and deadline.
    /// @return actualIn Input Currency amount actually paid by the caller.
    /// @return actualOut Output Currency amount actually received by the caller.
    function swapExactOutput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, false);
    }

    /// @notice Executes an exact-input swap for an eligible user through an approved external Adapter.
    /// @dev The Adapter is the settlement participant and receives both output and any positive delta.
    ///      The Adapter must derive `participant` from the authenticated DEX Router caller marker.
    /// @param request Pool, direction, exact input, minimum output, and deadline.
    /// @param participant Original caller whose SBT eligibility is checked.
    /// @return actualIn Input Currency amount actually paid by the Adapter.
    /// @return actualOut Output Currency amount received by the Adapter.
    function swapExactInputFromAdapter(SwapRequest calldata request, address participant)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (!isAdapterAllowed[msg.sender]) revert AdapterNotAllowed();

        return _swapWithSettlement(request, true, participant, msg.sender, msg.sender);
    }

    /// @notice Adds or removes an external Adapter from the swap allowlist.
    /// @dev A contract address is required when enabling an Adapter; revocation remains possible after code removal.
    /// @param adapter External Adapter address.
    /// @param allowed True to authorize; false to revoke.
    function setAdapterAllowed(address adapter, bool allowed) external onlyGovernor {
        if (adapter == address(0) || (allowed && adapter.code.length == 0)) revert InvalidAdapter();
        isAdapterAllowed[adapter] = allowed;
        emit AdapterAuthorizationUpdated(adapter, allowed);
    }

    /// @notice Executes the validated swap and settles both currency deltas during PoolManager unlock.
    /// @dev Accepts callbacks only from the configured PoolManager while a router call is active.
    /// @param data Encoded swap request, settlement participant, and exact-input mode supplied by `_swap`.
    /// @return Encoded actual input, actual output, and the PoolManager balance delta.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !entered) revert Unauthorized();
        (SwapRequest memory request, address settlementParticipant, bool exactInput) =
            abi.decode(data, (SwapRequest, address, bool));
        uint160 sqrtPriceLimitX96 = request.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            request.zeroForOne,
            exactInput ? -int256(uint256(request.amountSpecified)) : int256(uint256(request.amountSpecified)),
            sqrtPriceLimitX96
        );
        BalanceDelta delta = poolManager.swap(request.key, params, bytes(""));
        int128 inDelta = request.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = request.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert SlippageExceeded();
        if (inDelta == type(int128).min) revert InputAmountTooLarge();
        uint256 actualIn = uint256(-int256(inDelta));
        uint256 actualOut = uint256(int256(outDelta));
        if (exactInput) {
            if (actualIn > request.amountSpecified || actualOut < request.limitAmount) revert SlippageExceeded();
        } else if (actualOut != request.amountSpecified || actualIn > request.limitAmount) {
            revert SlippageExceeded();
        }

        _settle(request.key.currency0, delta.amount0(), settlementParticipant);
        _settle(request.key.currency1, delta.amount1(), settlementParticipant);
        return abi.encode(actualIn, actualOut, delta);
    }

    /// @dev Validates the caller and request, runs the PoolManager unlock, and emits the executed delta.
    /// @param request User-supplied one-pool swap parameters.
    /// @param exactInput True for exact input; false for exact output.
    /// @return actualIn Input Currency amount actually paid.
    /// @return actualOut Output Currency amount actually received.
    function _swap(SwapRequest calldata request, bool exactInput)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swapWithSettlement(request, exactInput, msg.sender, msg.sender, address(0));
    }

    /// @dev Validates the credential subject and runs the swap while settling through `settlementParticipant`.
    /// @param request Validated one-pool swap parameters.
    /// @param exactInput True for exact-input swaps; false for exact-output swaps.
    /// @param participant Address whose SBT eligibility is checked and identified as the trader.
    /// @param settlementParticipant Address that pays and receives PoolManager deltas.
    /// @param adapter Approved Adapter address, or zero for a direct user swap.
    function _swapWithSettlement(
        SwapRequest memory request,
        bool exactInput,
        address participant,
        address settlementParticipant,
        address adapter
    ) private returns (uint256 actualIn, uint256 actualOut) {
        bytes32 poolId = _validate(request, participant);
        bytes memory result = poolManager.unlock(abi.encode(request, settlementParticipant, exactInput));
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        (, uint32 day) = ledger.currentTradeDay();
        emit SwapExecuted(poolId, participant, request.zeroForOne, delta.amount0(), delta.amount1(), day);
        if (adapter != address(0)) {
            emit AdapterSwapExecuted(
                poolId, adapter, participant, request.zeroForOne, delta.amount0(), delta.amount1(), day
            );
        }
    }

    /// @dev Enforces deadline, amount bounds, participant eligibility, and current pool tradability.
    /// @param request Swap parameters to validate.
    /// @param participant Address whose credential is checked and who is identified as the trader.
    /// @return poolId Identifier derived from the request's PoolKey.
    function _validate(SwapRequest memory request, address participant) private view returns (bytes32 poolId) {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
        if (participant == address(0) || !registry.isEligible(participant)) revert Unauthorized();
        poolId = PoolId.unwrap(request.key.toId());
        if (!registry.isTradable(poolId)) revert InvalidPool();
    }

    /// @dev Pays a negative delta from the participant or takes a positive delta to the participant.
    /// @param currency Currency whose delta is being settled.
    /// @param delta Signed PoolManager delta for that Currency.
    /// @param participant User or Adapter that pays or receives the Currency.
    function _settle(Currency currency, int128 delta, address participant) private {
        address token = Currency.unwrap(currency);
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        if (delta < 0) {
            TSVDirectSettlementLib.settleFrom(poolManager, currency, token, participant, amount);
        } else {
            TSVDirectSettlementLib.takeTo(poolManager, currency, token, participant, amount);
        }
    }
}

```

### src/v1/periphery/TSVLPManagerV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPBounds, LPContext, LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";

/// @notice The sole V4 position owner for TSV LPs; each position has a unique V4 salt.
contract TSVLPManagerV1 is TSVGoverned, ERC721Upgradeable {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the position is unknown or its requested state change is invalid.
    error InvalidPosition();
    /// @dev Reverts when the pool is unknown, mismatched, or unavailable for the requested operation.
    error InvalidPool();
    /// @dev Reverts when the operation deadline has passed.
    error Expired();
    /// @dev Reverts when the position has no fees available to collect.
    error NoFees();
    /// @dev Reverts when the actual amount falls outside the caller supplied bounds.
    error SlippageExceeded();
    /// @dev Reverts when the input amount cannot be represented by the PoolManager delta type.
    error InputAmountTooLarge();
    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();
    /// @dev Reverts when a second operation was attempted while another operation is active.
    error Reentrancy();
    /// @dev Reverts when the LP receipt cannot be approved or transferred.
    error NonTransferable();

    /// @dev Stores the owner and liquidity accounting for an LP position.
    struct Position {
        /// @dev Account that owns the non-transferable position receipt.
        address owner;
        /// @dev Exact V4 pool key used by this position.
        PoolKey key;
        /// @dev Lower tick bound of the position range.
        int24 tickLower;
        /// @dev Upper tick bound of the position range.
        int24 tickUpper;
        /// @dev Unique salt used to identify this position in PoolManager.
        bytes32 salt;
        /// @dev Current liquidity held by this position.
        uint128 liquidity;
        /// @dev Whether the position remains open.
        bool active;
    }

    /// @dev Collects the pool and liquidity parameters for an LP position change.
    struct ModifyRequest {
        /// @dev Position being modified.
        uint256 positionId;
        /// @dev Operation mode validated by the Hook.
        LPOperationMode mode;
        /// @dev Signed liquidity change passed to PoolManager.
        int256 liquidityDelta;
        /// @dev Raw-unit settlement bounds and operation deadline.
        LPBounds bounds;
    }

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    uint256 public nextPositionId;
    mapping(uint256 => Position) private positions;
    LPContext private activeContext;
    bytes32 private activeRequestHash;
    bool private entered;

    /// @notice Emitted when a new LP position was opened and its receipt was minted.
    event PositionOpened(uint256 indexed positionId, address indexed owner, bytes32 indexed poolId, uint128 liquidity);
    /// @notice Emitted when liquidity in an LP position was changed.
    event PositionChanged(uint256 indexed positionId, uint128 oldLiquidity, uint128 newLiquidity);
    /// @notice Emitted when accrued fees were collected for an LP position.
    event FeesCollected(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    /// @notice Emitted when an LP position was closed and its receipt was burned.
    event PositionClosed(uint256 indexed positionId, address indexed owner, bool forced, bytes32 reasonCode);

    /// @notice Initializes the nontransferable LP Receipt and binds the PoolManager and Registry.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    /// @param poolManager_ V4 PoolManager that stores all TSV positions.
    /// @param registry_ Registry used for SBT and pool-status checks.
    function initialize(address anchor, address poolManager_, address registry_) external initializer {
        __TSVGoverned_init(anchor);
        __ERC721_init("TSV LP Receipt", "TSVLP");
        if (poolManager_.code.length == 0 || registry_.code.length == 0) revert InvalidPool();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        nextPositionId = 1;
    }

    /// @dev Prevents nested position operations while the PoolManager invokes `unlockCallback`.
    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Registers and initializes a pool, then marks it active in the same transaction.
    /// @param key V4 pool key whose currencies and Hook have been approved by the Registry.
    /// @param sqrtPriceX96 Initial Q64.96 square-root price passed to PoolManager.
    /// @param priceBasisHash Nonzero digest of the evidence supporting the initial price.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes32 priceBasisHash)
        external
        nonReentrant
        onlyRole(POOL_CREATOR_ROLE)
    {
        if (priceBasisHash == 0) revert InvalidPool();
        bytes32 poolId = registry.registerPendingPool(key);
        poolManager.initialize(key, sqrtPriceX96);
        registry.markPoolActive(poolId, sqrtPriceX96, msg.sender, priceBasisHash);
    }

    /// @notice Opens a positive-liquidity position and mints its nontransferable Receipt to the caller.
    /// @param key Active pool permitting ordinary LP operations.
    /// @param tickLower Lower tick boundary, aligned to the pool's tick spacing.
    /// @param tickUpper Upper tick boundary, aligned to the pool's tick spacing.
    /// @param liquidity Positive liquidity amount to add.
    /// @param bounds Per-Currency maximum input, minimum output, and deadline.
    /// @return positionId Identifier of the newly opened TSV position.
    function openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        LPBounds calldata bounds
    ) external nonReentrant returns (uint256 positionId) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        _requireUserPool(poolId, bounds.deadline);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidPosition();
        _validateTicks(key, tickLower, tickUpper);
        positionId = nextPositionId++;
        positions[positionId] = Position(msg.sender, key, tickLower, tickUpper, bytes32(positionId), 0, true);
        _modify(positionId, poolId, LPOperationMode.OPEN, int256(uint256(liquidity)), bounds);
        positions[positionId].liquidity = liquidity;
        _mint(msg.sender, positionId);
        emit PositionOpened(positionId, msg.sender, poolId, liquidity);
    }

    /// @notice Adds liquidity to a position owned by the eligible caller.
    /// @param positionId Existing active position to increase.
    /// @param liquidity Positive liquidity amount to add.
    /// @param bounds Per-Currency maximum input, minimum output, and deadline.
    function increaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external nonReentrant {
        (Position storage p, bytes32 poolId) = _requireOwner(positionId, bounds.deadline);
        if (
            liquidity == 0 || liquidity > uint128(type(int128).max)
                || uint256(p.liquidity) + liquidity > uint256(uint128(type(int128).max))
        ) {
            revert InvalidPosition();
        }
        uint128 old = p.liquidity;
        _modify(positionId, poolId, LPOperationMode.INCREASE, int256(uint256(liquidity)), bounds);
        p.liquidity = old + liquidity;
        emit PositionChanged(positionId, old, p.liquidity);
    }

    /// @notice Removes part of a position while keeping its remaining liquidity positive.
    /// @param positionId Existing active position to decrease.
    /// @param liquidity Positive liquidity amount to remove, strictly below the full position amount.
    /// @param bounds Per-Currency maximum input, minimum output, and deadline.
    function decreaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external nonReentrant {
        (Position storage p, bytes32 poolId) = _requireOwner(positionId, bounds.deadline);
        if (liquidity == 0 || liquidity >= p.liquidity) revert InvalidPosition();
        uint128 old = p.liquidity;
        _modify(positionId, poolId, LPOperationMode.DECREASE, -int256(uint256(liquidity)), bounds);
        p.liquidity = old - liquidity;
        emit PositionChanged(positionId, old, p.liquidity);
    }

    /// @notice Collects accrued fees from an active position without changing its liquidity.
    /// @param positionId Existing active position whose fees are collected.
    /// @param bounds Per-Currency settlement bounds and deadline.
    function collectFees(uint256 positionId, LPBounds calldata bounds) external nonReentrant {
        (Position storage p, bytes32 poolId) = _requireOwner(positionId, bounds.deadline);
        if (p.liquidity == 0) revert InvalidPosition();
        BalanceDelta delta = _modify(positionId, poolId, LPOperationMode.COLLECT, 0, bounds);
        if (delta.amount0() <= 0 && delta.amount1() <= 0) revert NoFees();
        emit FeesCollected(positionId, _positive(delta.amount0()), _positive(delta.amount1()));
    }

    /// @notice Removes all liquidity, settles the resulting deltas, and burns the caller's Receipt.
    /// @param positionId Active position owned by the caller.
    /// @param bounds Per-Currency settlement bounds and deadline.
    function closePosition(uint256 positionId, LPBounds calldata bounds) external nonReentrant {
        (Position storage p, bytes32 poolId) = _requireOwner(positionId, bounds.deadline);
        _modify(positionId, poolId, LPOperationMode.CLOSE, -int256(uint256(p.liquidity)), bounds);
        _close(positionId, p, false, 0);
    }

    /// @notice Closes a position under the forced-exit role and returns assets to its original owner.
    /// @dev The revoke executor may act only after the owner loses the SBT credential; admin authority is separate.
    /// @param positionId Active position to close.
    /// @param minPoolOut0 Minimum currency0 amount that must reach the original owner.
    /// @param minPoolOut1 Minimum currency1 amount that must reach the original owner.
    /// @param reasonCode Nonzero code describing the forced-exit reason.
    /// @param evidenceHash Nonzero digest of the supporting evidence.
    function forceExit(
        uint256 positionId,
        uint256 minPoolOut0,
        uint256 minPoolOut1,
        bytes32 reasonCode,
        bytes32 evidenceHash
    ) external nonReentrant {
        Position storage p = positions[positionId];
        if (!p.active || p.liquidity == 0 || reasonCode == 0 || evidenceHash == 0) revert InvalidPosition();
        if (
            !hasRole(FORCE_EXIT_ADMIN_ROLE, msg.sender)
                && (!hasRole(REVOKE_EXIT_EXECUTOR_ROLE, msg.sender) || registry.hasCredential(p.owner))
        ) {
            revert Unauthorized();
        }
        bytes32 poolId = PoolId.unwrap(p.key.toId());
        if (!registry.isKnownPool(poolId)) revert InvalidPool();
        LPBounds memory bounds;
        bounds.minPoolOut0 = minPoolOut0;
        bounds.minPoolOut1 = minPoolOut1;
        bounds.deadline = uint64(block.timestamp);
        _modify(positionId, poolId, LPOperationMode.FORCE_EXIT, -int256(uint256(p.liquidity)), bounds);
        _close(positionId, p, true, reasonCode);
    }

    /// @notice Returns the stored owner, pool, range, salt, liquidity, and active state of a position.
    /// @param positionId Position identifier to query.
    /// @return Stored position record; unknown IDs return a default record.
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /// @notice Exposes the current single-operation context for the Hook during PoolManager unlock.
    /// @return Pool, position, ticks, operation mode, salt, and liquidity delta being validated.
    function activeLPContext() external view returns (LPHookContext memory) {
        if (!entered || activeContext.positionId == 0) revert InvalidPosition();
        return LPHookContext(
            activeContext.poolId,
            activeContext.tickLower,
            activeContext.tickUpper,
            activeContext.mode,
            activeContext.salt,
            activeContext.liquidityDelta
        );
    }

    /// @notice Reverts because LP Receipts cannot be approved for transfer.
    function approve(address, uint256) public pure override {
        revert NonTransferable();
    }

    /// @notice Reverts because LP Receipts cannot be approved for transfer.
    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }

    /// @notice Reverts because LP Receipts are permanently bound to their original owner.
    function transferFrom(address, address, uint256) public pure override {
        revert NonTransferable();
    }

    /// @notice Reverts because LP Receipts are permanently bound to their original owner.
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert NonTransferable();
    }

    /// @dev Allows mint and burn while rejecting every transfer between nonzero owners.
    /// @param to Destination address, or zero when burning.
    /// @param tokenId Receipt identifier being updated.
    /// @param auth Authorization address checked by ERC-721.
    /// @return from Previous Receipt owner.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    /// @notice Reports supported ERC-721 and AccessControl interfaces.
    /// @param interfaceId Interface identifier to check.
    /// @return Whether the inherited contracts support `interfaceId`.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Applies one position modification and settles both PoolManager currency deltas.
    /// @dev Accepts only the PoolManager callback bound to the currently active request hash.
    /// @param data Encoded `ModifyRequest` supplied by `_modify`.
    /// @return Encoded `BalanceDelta` returned to the initiating position operation.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || !entered || activeContext.positionId == 0
                || keccak256(data) != activeRequestHash
        ) {
            revert Unauthorized();
        }
        ModifyRequest memory request = abi.decode(data, (ModifyRequest));
        if (block.timestamp > request.bounds.deadline) revert Expired();
        Position storage p = positions[request.positionId];
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(p.tickLower, p.tickUpper, request.liquidityDelta, p.salt);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(p.key, params, bytes(""));
        _settle(
            p.key.currency0,
            delta.amount0(),
            request.bounds.maxPoolIn0,
            request.bounds.minPoolOut0,
            p.owner,
            request.mode
        );
        _settle(
            p.key.currency1,
            delta.amount1(),
            request.bounds.maxPoolIn1,
            request.bounds.minPoolOut1,
            p.owner,
            request.mode
        );
        return abi.encode(delta);
    }

    /// @dev Sets the Hook context, executes one PoolManager unlock, and clears transient operation state.
    /// @param positionId Position whose liquidity is being modified.
    /// @param poolId Pool identifier used to bind the Hook callback.
    /// @param mode Operation type checked by the Hook.
    /// @param liquidityDelta Signed liquidity change sent to PoolManager.
    /// @param bounds Per-Currency settlement limits and deadline.
    /// @return delta Actual PoolManager balance delta for both currencies.
    function _modify(
        uint256 positionId,
        bytes32 poolId,
        LPOperationMode mode,
        int256 liquidityDelta,
        LPBounds memory bounds
    ) private returns (BalanceDelta delta) {
        Position storage p = positions[positionId];
        activeContext = LPContext(poolId, positionId, p.tickLower, p.tickUpper, mode, p.salt, liquidityDelta);
        ModifyRequest memory request = ModifyRequest(positionId, mode, liquidityDelta, bounds);
        activeRequestHash = keccak256(abi.encode(request));
        bytes memory result = poolManager.unlock(abi.encode(request));
        delta = abi.decode(result, (BalanceDelta));
        delete activeContext;
        delete activeRequestHash;
    }

    /// @dev Applies slippage bounds and settles the signed delta directly with the position owner.
    /// @param currency Currency whose delta is being settled.
    /// @param delta Signed PoolManager delta for that Currency.
    /// @param maxIn Maximum amount that may be pulled from the owner.
    /// @param minOut Minimum amount that must be delivered to the owner.
    /// @param owner Original owner who funds or receives the position assets.
    /// @param mode LP operation mode that controls allowed delta directions.
    function _settle(
        Currency currency,
        int128 delta,
        uint256 maxIn,
        uint256 minOut,
        address owner,
        LPOperationMode mode
    ) private {
        address token = Currency.unwrap(currency);
        if (delta < 0 && (mode == LPOperationMode.FORCE_EXIT || mode == LPOperationMode.COLLECT)) {
            revert SlippageExceeded();
        }
        if (delta == type(int128).min) revert InputAmountTooLarge();
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        if (delta < 0 && amount > maxIn) revert SlippageExceeded();
        if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
        if (delta < 0) {
            TSVDirectSettlementLib.settleFrom(poolManager, currency, token, owner, amount);
        } else if (delta > 0) {
            TSVDirectSettlementLib.takeTo(poolManager, currency, token, owner, amount);
        }
    }

    /// @dev Requires an unexpired request, an active SBT credential, and a pool permitting ordinary LP operations.
    /// @param poolId Pool identifier for the operation.
    /// @param deadline Latest timestamp at which the operation may execute.
    function _requireUserPool(bytes32 poolId, uint64 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!registry.isEligible(msg.sender)) revert Unauthorized();
        if (!registry.isLPAllowed(poolId)) revert InvalidPool();
    }

    /// @dev Verifies the caller owns the active Receipt before applying the common user and pool checks.
    /// @param positionId Position and Receipt identifier.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @return p Stored position record.
    /// @return poolId Pool identifier derived from the stored PoolKey.
    function _requireOwner(uint256 positionId, uint64 deadline)
        private
        view
        returns (Position storage p, bytes32 poolId)
    {
        p = positions[positionId];
        if (!p.active || p.liquidity == 0 || p.owner != msg.sender || ownerOf(positionId) != p.owner) {
            revert InvalidPosition();
        }
        poolId = PoolId.unwrap(p.key.toId());
        _requireUserPool(poolId, deadline);
    }

    /// @dev Enforces an ordered tick range within TickMath limits and aligned to pool spacing.
    /// @param key Pool key supplying the tick spacing.
    /// @param lower Lower tick boundary.
    /// @param upper Upper tick boundary.
    function _validateTicks(PoolKey calldata key, int24 lower, int24 upper) private pure {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % key.tickSpacing != 0
                || upper % key.tickSpacing != 0
        ) revert InvalidPosition();
    }

    /// @dev Marks a position inactive, burns its nontransferable Receipt, and emits its close reason.
    /// @param positionId Position and Receipt identifier.
    /// @param p Stored position record being closed.
    /// @param forced Whether closure came from the forced-exit path.
    /// @param reasonCode Forced-exit reason, or zero for a user close.
    function _close(uint256 positionId, Position storage p, bool forced, bytes32 reasonCode) private {
        address owner = p.owner;
        p.liquidity = 0;
        p.active = false;
        _burn(positionId);
        emit PositionClosed(positionId, owner, forced, reasonCode);
    }

    /// @dev Returns a positive signed delta as uint256 and maps zero or negative values to zero.
    /// @param value Signed PoolManager delta.
    /// @return Positive magnitude, or zero when `value` is not positive.
    function _positive(int128 value) private pure returns (uint256) {
        return value > 0 ? uint256(int256(value)) : 0;
    }
}

```

### src/v1/adapters/ERC8056DirectLegalShareAdapter.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

interface IERC8056DirectMultiplierSource {
    function decimals() external view returns (uint8);
    function uiMultiplier() external view returns (uint256);
}

/// @notice Converts raw ERC-8056 token amounts using the multiplier active at call time.
contract ERC8056DirectLegalShareAdapter is IDirectLegalShareAdapter {
    error InvalidAdapterConfig();
    error InvalidCurrency();
    error InvalidRate();

    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    constructor(address currency_, uint32 version_) {
        if (currency_ == address(0) || currency_.code.length == 0 || version_ == 0) revert InvalidAdapterConfig();
        uint8 decimals_ = IERC8056DirectMultiplierSource(currency_).decimals();
        if (decimals_ > 18) revert InvalidAdapterConfig();
        poolCurrency = currency_;
        adapterVersion = version_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDirectLegalShareAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Converts raw token units using the multiplier active at this call.
    function toLegalShares(address currency, uint256 rawAmount)
        external
        view
        override
        returns (uint256 legalSharesWad)
    {
        if (rawAmount == 0) return 0;
        (uint256 multiplier, uint8 decimals_) = _currentMultiplier(currency);
        legalSharesWad = Math.mulDiv(rawAmount, multiplier, 10 ** uint256(decimals_));
        if (legalSharesWad == 0) revert InvalidRate();
    }

    function _currentMultiplier(address currency) private view returns (uint256 multiplier, uint8 decimals_) {
        if (currency != poolCurrency) revert InvalidCurrency();

        IERC8056DirectMultiplierSource token = IERC8056DirectMultiplierSource(currency);
        multiplier = token.uiMultiplier();
        decimals_ = token.decimals();

        if (multiplier == 0 || decimals_ > 18) revert InvalidAdapterConfig();
    }
}

```

### src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @dev Exposes share-to-underlying conversion data from the issuer token.
interface IBackedShareConversionSource {
    /// @notice Returns the number of decimals used by the issuer's share representation.
    function decimals() external view returns (uint8);

    /// @notice Converts a wrapped-share amount to its underlying legal-share amount.
    function getUnderlyingAmountByShares(uint256 sharesAmount) external view returns (uint256 underlyingAmount);
}

/// @dev Exposes the underlying asset associated with the wrapped token.
interface IBackedWrappedAsset {
    /// @notice Returns the underlying asset represented by this wrapped token.
    function asset() external view returns (address);

    /// @notice Returns the wrapped token's decimal precision.
    function decimals() external view returns (uint8);
}

/// @notice Converts wrapped Backed shares by calling the issuer token's live conversion method.
/// @dev The returned underlying amount is the legal-share amount in WAD for the reviewed wTSLAx setup.
contract BackedAutoFeeLegalShareAdapter is IDirectLegalShareAdapter {
    /// @dev Reverts when the adapter configuration is invalid or incomplete.
    error InvalidAdapterConfig();
    /// @dev Reverts when the requested Currency does not match the configured adapter Currency.
    error InvalidCurrency();
    /// @dev Reverts when the issuer conversion returned an invalid legal-share amount.
    error InvalidConversion();

    address public immutable userToken;
    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    /// @notice Binds the wrapped pool currency to its issuer conversion source and adapter version.
    /// @param underlying_ Issuer token that exposes the live share conversion method.
    /// @param wrapped_ Token used as the pool currency and returned by the issuer wrapper.
    /// @param version_ Reviewed adapter version recorded by the Registry.
    constructor(address underlying_, address wrapped_, uint32 version_) {
        if (
            underlying_ == address(0) || wrapped_ == address(0) || underlying_ == wrapped_ || version_ == 0
                || underlying_.code.length == 0 || wrapped_.code.length == 0
        ) revert InvalidAdapterConfig();
        if (
            IBackedWrappedAsset(wrapped_).asset() != underlying_
                || IBackedShareConversionSource(underlying_).decimals() != 18
                || IBackedWrappedAsset(wrapped_).decimals() != 18
        ) revert InvalidAdapterConfig();
        userToken = underlying_;
        poolCurrency = wrapped_;
        adapterVersion = version_;
    }

    /// @notice Reports support for the direct legal-share adapter and ERC-165 interfaces.
    /// @param interfaceId Interface identifier to check.
    /// @return True when this adapter implements the requested interface.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDirectLegalShareAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Converts a pool-currency amount to its live legal-share amount in WAD.
    /// @param currency Currency supplied by the caller; must equal `poolCurrency`.
    /// @param rawAmount Amount in the pool currency's raw units.
    /// @return legalSharesWad Underlying legal shares returned by the issuer conversion source.
    function toLegalShares(address currency, uint256 rawAmount)
        external
        view
        override
        returns (uint256 legalSharesWad)
    {
        if (currency != poolCurrency) revert InvalidCurrency();
        if (rawAmount == 0) return 0;

        legalSharesWad = IBackedShareConversionSource(userToken).getUnderlyingAmountByShares(rawAmount);
        if (legalSharesWad == 0) revert InvalidConversion();
    }
}

```

### src/v1/deployment/TSVERC1967Proxy.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @notice Stable selector for implementation inspection even when logic is broken.
contract TSVERC1967Proxy is ERC1967Proxy {
    /// @dev Reverts when proxy initialization data must not be empty.
    error EmptyInitializationData();

    /// @notice Deploys an ERC-1967 proxy and requires nonempty initialization calldata.
    /// @param implementation Initial logic contract.
    /// @param data Initialization call encoded for the implementation.
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {
        if (data.length == 0) revert EmptyInitializationData();
    }

    /// @notice Returns the implementation address stored in the ERC-1967 slot.
    /// @return Current proxy logic address.
    function tsvImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}

```

### src/v1/deployment/TSVHookProxyFactoryV1.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @notice CREATE2 deployment for the V4 hook proxy permission address.
/// @notice Predicts and deploys TSV Hook proxies whose CREATE2 address has the required V4 hook flags.
contract TSVHookProxyFactoryV1 {
    /// @dev Reverts when the supplied implementation address is invalid.
    error InvalidImplementation();
    /// @dev Reverts when the Hook proxy address does not contain the required V4 permission bits.
    error InvalidHookAddress();

    uint160 public constant REQUIRED_HOOK_FLAGS = 0x3FFF;
    uint160 private constant FLAG_MASK = 0x3FFF;

    /// @notice Emitted when a Hook proxy was deployed at the supplied CREATE2 salt.
    event HookProxyDeployed(address indexed proxy, address indexed implementation, bytes32 indexed salt);

    /// @notice Computes the CREATE2 address for the proxy deployment parameters.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization calldata embedded in the proxy constructor.
    /// @param salt CREATE2 salt used for deployment.
    /// @return Address that `deploy` will create for these parameters.
    function predict(address implementation, bytes calldata initData, bytes32 salt) public view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(TSVERC1967Proxy).creationCode, abi.encode(implementation, initData)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Deploys the Hook proxy only when its predicted address has all required permission bits.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization calldata embedded in the proxy constructor.
    /// @param salt CREATE2 salt used for deployment.
    /// @return proxy Address of the newly deployed proxy.
    function deploy(address implementation, bytes calldata initData, bytes32 salt) external returns (address proxy) {
        if (implementation.code.length == 0 || initData.length == 0) revert InvalidImplementation();
        if ((uint160(predict(implementation, initData, salt)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookAddress();
        }
        proxy = address(new TSVERC1967Proxy{salt: salt}(implementation, initData));
        emit HookProxyDeployed(proxy, implementation, salt);
    }
}

```

### src/v1/governance/TSVGovernanceAnchor.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Exposes the governance anchor bound to a core proxy.
interface IAnchoredProxyV1 {
    /// @notice Returns the fixed Anchor address stored by a business proxy.
    function governanceAnchor() external view returns (address);

    /// @notice Upgrades a business proxy and optionally initializes the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @dev Exposes the component links maintained by the Registry.
interface IRegistryLinksV1 {
    /// @notice Returns the Registry's configured Hook.
    function hook() external view returns (address);

    /// @notice Returns the Registry's configured LP Manager.
    function lpManager() external view returns (address);

    /// @notice Returns the Registry's configured DataInbox.
    function dataInbox() external view returns (address);
}

/// @dev Exposes the Registry, Hook and Inbox links maintained by the Ledger.
interface ILedgerLinksV1 {
    /// @notice Returns the Ledger's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Ledger's configured Hook writer.
    function hook() external view returns (address);

    /// @notice Returns the Ledger's configured DataInbox writer.
    function dataInbox() external view returns (address);
}

/// @dev Exposes the Registry and Ledger links maintained by the data Inbox.
interface IInboxLinksV1 {
    /// @notice Returns the DataInbox's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the DataInbox's configured Volume Ledger.
    function ledger() external view returns (address);
}

/// @dev Exposes the component links maintained by the Hook.
interface IHookLinksV1 {
    /// @notice Returns the Hook's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Hook's configured Volume Ledger.
    function ledger() external view returns (address);

    /// @notice Returns the Hook's authorized Swap Router.
    function router() external view returns (address);

    /// @notice Returns the Hook's authorized LP Manager.
    function lpManager() external view returns (address);

    /// @notice Returns the Hook's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @dev Exposes the component links maintained by the Swap Router.
interface IRouterLinksV1 {
    /// @notice Returns the Router's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the Router's configured Volume Ledger.
    function ledger() external view returns (address);

    /// @notice Returns the Router's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @dev Exposes the component links maintained by the LP Manager.
interface ILpLinksV1 {
    /// @notice Returns the LP Manager's configured Registry.
    function registry() external view returns (address);

    /// @notice Returns the LP Manager's configured PoolManager.
    function poolManager() external view returns (address);
}

/// @notice Fixed governance root storing identities and the global upgrade switch for all six business proxies.
contract TSVGovernanceAnchor {
    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the governance identities or business-proxy bindings are inconsistent.
    error InvalidBundle();
    /// @dev Reverts when the proposal is unknown, stale, expired, or not approved for execution.
    error InvalidProposal();
    /// @dev Reverts when the Guardian has frozen all business-proxy upgrades.
    error UpgradeFrozen();
    /// @dev Reverts when a freeze transition lacks evidence or references a stale freeze.
    error InvalidFreeze();

    address public governor;
    address public guardian;
    address public immutable recoveryCouncil;
    uint64 public epoch;
    uint64 public guardianEpoch;
    bool public proxiesBound;
    address[6] public proxies;

    /// @dev Captures the identities and epochs approved for an identity recovery.
    struct RecoveryProposal {
        address newGovernor;
        address newGuardian;
        uint64 epoch;
        uint64 guardianEpoch;
        bytes32 evidenceHash;
        bool active;
        bool approved;
    }

    mapping(bytes32 => RecoveryProposal) public recoveries;
    bool public upgradeContextActive;
    /// @notice Guardian-controlled switch covering every business-proxy upgrade entry point.
    bool public upgradesFrozen;
    /// @notice Monotonically increasing identifier for freeze incidents.
    uint64 public freezeEpoch;
    bytes32 public freezeId;

    event UpgradesFrozen(bytes32 indexed id, address indexed guardian, bytes32 reasonHash);
    event UpgradesUnfrozen(bytes32 indexed id, address indexed guardian, bytes32 evidenceHash);

    /// @notice Freezes single and batch upgrades. Business operations and recovery remain available.
    function freezeUpgrades(bytes32 reasonHash) external returns (bytes32 id) {
        if (msg.sender != guardian) revert Unauthorized();
        if (upgradesFrozen || reasonHash == 0) revert InvalidFreeze();
        ++freezeEpoch;
        id = keccak256(abi.encode(block.chainid, address(this), freezeEpoch, guardian, reasonHash));
        freezeId = id;
        upgradesFrozen = true;
        emit UpgradesFrozen(id, msg.sender, reasonHash);
    }

    /// @notice Reopens upgrades only when the current Guardian explicitly resolves the current freeze.
    function unfreezeUpgrades(bytes32 expectedFreezeId, bytes32 evidenceHash) external {
        if (msg.sender != guardian) revert Unauthorized();
        if (!upgradesFrozen || expectedFreezeId != freezeId || evidenceHash == 0) revert InvalidFreeze();
        upgradesFrozen = false;
        emit UpgradesUnfrozen(freezeId, msg.sender, evidenceHash);
    }

    event BatchUpgraded(address indexed governor, uint256 count);

    /// @notice Upgrades up to six bound business proxies atomically in one Governor transaction.
    /// @dev Upgrade initializers receive this Anchor as msg.sender.
    function upgradeBatch(address[] calldata targets, address[] calldata implementations, bytes[] calldata initData)
        external
    {
        if (msg.sender != governor) revert Unauthorized();
        if (upgradesFrozen) revert UpgradeFrozen();
        if (
            !proxiesBound || upgradeContextActive || targets.length == 0 || targets.length > 6
                || targets.length != implementations.length || targets.length != initData.length
        ) revert InvalidBundle();
        for (uint256 i; i < targets.length; ++i) {
            bool bound;
            for (uint256 j; j < 6; ++j) {
                if (targets[i] == proxies[j]) bound = true;
            }
            if (!bound || implementations[i].code.length == 0) revert InvalidBundle();
            for (uint256 j; j < i; ++j) {
                if (targets[i] == targets[j]) revert InvalidBundle();
            }
        }
        upgradeContextActive = true;
        for (uint256 i; i < targets.length; ++i) {
            IAnchoredProxyV1(targets[i]).upgradeToAndCall(implementations[i], initData[i]);
        }
        upgradeContextActive = false;
        emit BatchUpgraded(msg.sender, targets.length);
    }

    /// @notice Emitted when the six business proxies were bound to the governance anchor.
    event ProxiesBound(address[6] proxies);
    /// @notice Emitted when the governance anchor guardian was synchronized.
    event GuardianSynced(address indexed oldGuardian, address indexed newGuardian, uint64 guardianEpoch);

    /// @notice Sets the initial independent governance identities; the Anchor itself is not upgradeable.
    constructor(address governor_, address guardian_, address recoveryCouncil_) {
        if (
            governor_ == address(0) || guardian_ == address(0) || recoveryCouncil_ == address(0)
                || governor_ == guardian_ || governor_ == recoveryCouncil_ || guardian_ == recoveryCouncil_
        ) revert InvalidBundle();
        guardian = guardian_;
        recoveryCouncil = recoveryCouncil_;
        governor = governor_;
    }

    event RecoveryProposed(bytes32 indexed id, address newGovernor, address newGuardian, bytes32 evidenceHash);
    event RecoveryApprovalChanged(bytes32 indexed id, bool approved);
    event RecoveryCancelled(bytes32 indexed id);
    event AuthoritiesRecovered(
        address indexed oldGovernor, address indexed newGovernor, address newGuardian, bytes32 evidenceHash
    );

    /// @notice Permanently binds and cross-checks the six business proxy addresses.
    /// @dev Array order is Registry, Ledger, DataInbox, Hook, Router, and LP Manager.
    /// @param addresses Six deployed business proxies in the required component order.
    function bindProxies(address[6] calldata addresses) external {
        if (msg.sender != governor || proxiesBound) revert Unauthorized();
        for (uint256 i; i < 6; ++i) {
            if (addresses[i].code.length == 0 || IAnchoredProxyV1(addresses[i]).governanceAnchor() != address(this)) {
                revert InvalidBundle();
            }
            for (uint256 j; j < i; ++j) {
                if (addresses[i] == addresses[j]) revert InvalidBundle();
            }
            proxies[i] = addresses[i];
        }
        if (
            IRegistryLinksV1(addresses[0]).hook() != addresses[3]
                || IRegistryLinksV1(addresses[0]).lpManager() != addresses[5]
                || IRegistryLinksV1(addresses[0]).dataInbox() != addresses[2]
                || ILedgerLinksV1(addresses[1]).registry() != addresses[0]
                || ILedgerLinksV1(addresses[1]).hook() != addresses[3]
                || ILedgerLinksV1(addresses[1]).dataInbox() != addresses[2]
                || IInboxLinksV1(addresses[2]).registry() != addresses[0]
                || IInboxLinksV1(addresses[2]).ledger() != addresses[1]
                || IHookLinksV1(addresses[3]).registry() != addresses[0]
                || IHookLinksV1(addresses[3]).ledger() != addresses[1]
                || IHookLinksV1(addresses[3]).router() != addresses[4]
                || IHookLinksV1(addresses[3]).lpManager() != addresses[5]
                || IRouterLinksV1(addresses[4]).registry() != addresses[0]
                || IRouterLinksV1(addresses[4]).ledger() != addresses[1]
                || ILpLinksV1(addresses[5]).registry() != addresses[0]
                || IHookLinksV1(addresses[3]).poolManager() != IRouterLinksV1(addresses[4]).poolManager()
                || IHookLinksV1(addresses[3]).poolManager() != ILpLinksV1(addresses[5]).poolManager()
        ) revert InvalidBundle();
        proxiesBound = true;
        emit ProxiesBound(addresses);
    }

    /// @notice Proposes a narrowly scoped Governor/Guardian recovery as the Recovery Council.
    function proposeRecovery(address newGovernor, address newGuardian, bytes32 salt, bytes32 evidenceHash)
        external
        returns (bytes32 id)
    {
        if (msg.sender != recoveryCouncil || salt == 0 || evidenceHash == 0) revert Unauthorized();
        _validateRecovery(newGovernor, newGuardian);
        id = keccak256(
            abi.encode(block.chainid, address(this), epoch, guardianEpoch, newGovernor, newGuardian, salt, evidenceHash)
        );
        if (recoveries[id].active) revert InvalidProposal();
        recoveries[id] = RecoveryProposal(newGovernor, newGuardian, epoch, guardianEpoch, evidenceHash, true, false);
        emit RecoveryProposed(id, newGovernor, newGuardian, evidenceHash);
    }

    /// @notice Approves a current recovery as the current Guardian.
    function approveRecovery(bytes32 id) external {
        if (msg.sender != guardian) revert Unauthorized();
        RecoveryProposal storage p = recoveries[id];
        if (!p.active || p.epoch != epoch || p.guardianEpoch != guardianEpoch) revert InvalidProposal();
        p.approved = true;
        emit RecoveryApprovalChanged(id, true);
    }

    /// @notice Revokes the Guardian's approval without cancelling the Council's proposal.
    function revokeRecoveryApproval(bytes32 id) external {
        if (msg.sender != guardian || !recoveries[id].approved) revert Unauthorized();
        recoveries[id].approved = false;
        emit RecoveryApprovalChanged(id, false);
    }

    /// @notice Cancels a pending recovery as the Recovery Council.
    function cancelRecovery(bytes32 id) external {
        if (msg.sender != recoveryCouncil || !recoveries[id].active) revert Unauthorized();
        recoveries[id].active = false;
        emit RecoveryCancelled(id);
    }

    /// @notice Atomically applies a Council-proposed, current-Guardian-approved identity recovery.
    function executeRecovery(bytes32 id) external {
        RecoveryProposal storage p = recoveries[id];
        if (upgradeContextActive || !p.active || !p.approved || p.epoch != epoch || p.guardianEpoch != guardianEpoch) {
            revert InvalidProposal();
        }
        _validateRecovery(p.newGovernor, p.newGuardian);
        p.active = false;
        p.approved = false;
        address oldGovernor = governor;
        address oldGuardian = guardian;
        governor = p.newGovernor;
        if (p.newGuardian != oldGuardian) {
            guardian = p.newGuardian;
            ++guardianEpoch;
            emit GuardianSynced(oldGuardian, guardian, guardianEpoch);
        }
        ++epoch;
        emit AuthoritiesRecovered(oldGovernor, p.newGovernor, p.newGuardian, p.evidenceHash);
    }

    function _validateRecovery(address newGovernor, address newGuardian) private view {
        address currentGovernor = governor;
        if (
            newGovernor == address(0) || newGuardian == address(0) || newGovernor == newGuardian
                || newGovernor == recoveryCouncil || newGuardian == recoveryCouncil || newGovernor == guardian
                || newGuardian == currentGovernor || (newGovernor == currentGovernor && newGuardian == guardian)
        ) revert InvalidBundle();
    }
}

```

### src/v1/governance/TSVGoverned.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Shared UUPS and role-control base for TSV business proxies.
/// @dev The current Governor upgrades in one transaction while the fixed Anchor's global upgrade switch is open.
abstract contract TSVGoverned is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Reverts when the caller is not authorized to upgrade this contract.
    error UnauthorizedUpgrade();
    /// @dev Reverts when the Guardian has frozen every upgrade entry point.
    error UpgradeFrozen();
    /// @dev Reverts when the requested role change targets a protected role.
    error ProtectedRole();
    /// @dev Reverts when the governance contract addresses or links are invalid.
    error InvalidGovernance();

    bytes32 public constant SYMBOL_ADMIN_ROLE = keccak256("SYMBOL_ADMIN_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant HALT_REPORTER_ROLE = keccak256("HALT_REPORTER_ROLE");
    bytes32 public constant VOLUME_ORACLE_ROLE = keccak256("VOLUME_ORACLE_ROLE");
    bytes32 public constant EMERGENCY_PAUSER_ROLE = keccak256("EMERGENCY_PAUSER_ROLE");
    bytes32 public constant EMERGENCY_RESUMER_ROLE = keccak256("EMERGENCY_RESUMER_ROLE");
    bytes32 public constant REVOKE_EXIT_EXECUTOR_ROLE = keccak256("REVOKE_EXIT_EXECUTOR_ROLE");
    bytes32 public constant FORCE_EXIT_ADMIN_ROLE = keccak256("FORCE_EXIT_ADMIN_ROLE");

    TSVGovernanceAnchor public governanceAnchor;

    /// @dev Locks the implementation contract; proxy instances initialize their own storage.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes role storage and verifies the supplied governance root matches the configured identities.
    /// @param anchor_ Governance Anchor that stores the active Governor and global upgrade switch.
    function __TSVGoverned_init(address anchor_) internal onlyInitializing {
        if (anchor_.code.length == 0) revert InvalidGovernance();
        TSVGovernanceAnchor root = TSVGovernanceAnchor(anchor_);
        address governor = root.governor();
        address guardian = root.guardian();
        address council = root.recoveryCouncil();
        if (
            governor == address(0) || guardian == address(0) || council == address(0) || governor == guardian
                || governor == council || guardian == council
        ) {
            revert InvalidGovernance();
        }
        __AccessControl_init();
        governanceAnchor = root;
    }

    /// @dev Restricts the function to the Governor currently stored in the fixed Anchor.
    modifier onlyGovernor() {
        if (msg.sender != governanceAnchor.governor()) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        _;
    }

    /// @notice Checks a role, resolving the default admin dynamically to the current Governor.
    /// @param role Role identifier being queried.
    /// @param account Account whose role membership is queried.
    /// @return Whether the account currently holds the role.
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            return account != address(0) && account == governanceAnchor.governor();
        }
        return super.hasRole(role, account);
    }

    /// @notice Grants a business role; the default-admin role remains anchored to the Governor.
    /// @param role Role identifier to grant.
    /// @param account Account receiving the role.
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.grantRole(role, account);
    }

    /// @notice Revokes a business role; the default-admin role cannot be changed through AccessControl.
    /// @param role Role identifier to revoke.
    /// @param account Account losing the role.
    function revokeRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.revokeRole(role, account);
    }

    /// @notice Renounces a business role while protecting the Governor-controlled default-admin role.
    /// @param role Role identifier to renounce.
    /// @param account Account renouncing the role; AccessControl requires it to equal the caller.
    function renounceRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        super.renounceRole(role, account);
    }

    /// @dev Rejects internal attempts to assign the protected default-admin role.
    /// @param role Role identifier to grant.
    /// @param account Account receiving the role.
    /// @return Whether membership changed.
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._grantRole(role, account);
    }

    /// @dev Rejects internal attempts to revoke the protected default-admin role.
    /// @param role Role identifier to revoke.
    /// @param account Account losing the role.
    /// @return Whether membership changed.
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) revert ProtectedRole();
        return super._revokeRole(role, account);
    }

    /// @dev Allows the Governor or its active Anchor batch only while global upgrades are unfrozen.
    function _authorizeUpgrade(address) internal view virtual override {
        if (
            msg.sender != governanceAnchor.governor()
                && !(msg.sender == address(governanceAnchor) && governanceAnchor.upgradeContextActive())
        ) {
            revert UnauthorizedUpgrade();
        }
        if (governanceAnchor.upgradesFrozen()) revert UpgradeFrozen();
    }
}

```

### src/v1/interfaces/IDirectLegalShareAdapter.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Direct conversion interface used by Hook swap accounting.
interface IDirectLegalShareAdapter is IERC165 {
    /// @notice Returns the pool Currency to which this adapter is bound.
    function poolCurrency() external view returns (address);

    /// @notice Returns the reviewed conversion-policy version.
    function adapterVersion() external view returns (uint32);

    /// @notice Converts an amount of the bound Currency into legal shares expressed in WAD.
    /// @param currency Currency being converted; implementations must enforce their configured asset.
    /// @param rawAmount Amount of Currency in its raw token units.
    /// @return legalSharesWad Legal-share amount used by TSV volume accounting.
    function toLegalShares(address currency, uint256 rawAmount) external view returns (uint256 legalSharesWad);
}

```

### script/DeployGovernanceV1.s.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Deploys the fixed governance Anchor with its three independent identities.
contract DeployGovernanceV1 is ScriptEnvironment {
    error InvalidDeploymentInput();

    function run() external returns (TSVGovernanceAnchor anchor) {
        uint256 deployerKey = _envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address governor = _envAddress("TSV_GOVERNOR");
        address guardian = _envAddress("TSV_GUARDIAN");
        address council = _envAddress("TSV_RECOVERY_COUNCIL");
        if (block.chainid != _envUint("TSV_CHAIN_ID")) revert InvalidDeploymentInput();

        vm.startBroadcast(deployerKey);
        anchor = new TSVGovernanceAnchor(governor, guardian, council);
        vm.stopBroadcast();
        if (
            anchor.governor() != governor || anchor.guardian() != guardian || anchor.upgradesFrozen()
                || anchor.recoveryCouncil() != council
        ) revert InvalidDeploymentInput();
        console2.log("GovernanceAnchor", address(anchor));
    }
}

```

### script/check-test-layout.py — SECURITY REVIEW

```py
#!/usr/bin/env python3
"""Reject shared fixtures containing tests and suites inheriting executable test suites."""

from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
test_root = root / "test"
sources = {path: path.read_text() for path in test_root.rglob("*.sol")}
test_contracts = set()
errors = []

for path, source in sources.items():
    if path.name.endswith(".t.sol"):
        contracts = list(re.finditer(r"\bcontract\s+(\w+)\s+is\s+([^\{]+)\{", source))
        for index, match in enumerate(contracts):
            end = contracts[index + 1].start() if index + 1 < len(contracts) else len(source)
            if re.search(r"\bfunction\s+(?:test\w*|invariant\w*)\s*\(", source[match.end():end]):
                test_contracts.add(match.group(1))
    if "helpers" in path.relative_to(test_root).parts and re.search(r"\bfunction\s+(?:test\w*|invariant\w*)\s*\(", source):
        errors.append(f"{path.relative_to(root)}: shared helpers must not contain executable tests")

for path, source in sources.items():
    for match in re.finditer(r"\bcontract\s+(\w+)\s+is\s+([^\{]+)\{", source):
        inherited = set(re.findall(r"\b\w+\b", match.group(2))) & test_contracts
        if inherited:
            errors.append(f"{path.relative_to(root)}: {match.group(1)} inherits executable suite {', '.join(sorted(inherited))}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

print(f"Test layout valid: {len(test_contracts)} suites; fixtures contain no tests; no suite inheritance.")

```

### script/VerifyDeploymentV1.s.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @notice Read-only post-deployment check. Role, report, asset and issuer evidence remain manifest gates.
contract VerifyDeploymentV1 is ScriptEnvironment {
    /// @dev Reverts when a deployment address, code hash, or governance link does not match the manifest.
    error VerificationFailed();

    /// @notice Verifies governance bindings, proxy links, code hashes and implementation addresses.
    /// @dev Reads the expected deployment manifest values from environment variables and reverts on mismatch.
    function run() external view {
        if (block.chainid != _envUint("TSV_CHAIN_ID")) revert VerificationFailed();
        TSVGovernanceAnchor anchor = TSVGovernanceAnchor(_envAddress("TSV_GOVERNANCE_ANCHOR"));
        address[6] memory a = [
            _envAddress("TSV_REGISTRY"),
            _envAddress("TSV_VOLUME_LEDGER"),
            _envAddress("TSV_DATA_INBOX"),
            _envAddress("TSV_HOOK"),
            _envAddress("TSV_SWAP_ROUTER"),
            _envAddress("TSV_LP_MANAGER")
        ];
        _checkGovernance(anchor, a);
        _checkLinks(a);
        _checkImplementations(a);
        console2.log("TSV governance, six proxy links, code hashes and implementation addresses verified.");
    }

    /// @dev Checks the Anchor's governance links and confirms all six proxies are bound to it.
    /// @param anchor Governance anchor expected to control the deployed proxies.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkGovernance(TSVGovernanceAnchor anchor, address[6] memory a) private view {
        if (
            address(anchor).code.length == 0 || !anchor.proxiesBound()
                || anchor.governor() != _envAddress("TSV_GOVERNOR") || anchor.guardian() != _envAddress("TSV_GUARDIAN")
                || anchor.recoveryCouncil() != _envAddress("TSV_RECOVERY_COUNCIL")
        ) revert VerificationFailed();
        for (uint256 i; i < 6; ++i) {
            if (
                a[i].code.length == 0 || anchor.proxies(i) != a[i]
                    || address(TSVRegistryV1(a[i]).governanceAnchor()) != address(anchor)
                    || !TSVRegistryV1(a[i]).hasRole(bytes32(0), anchor.governor())
            ) revert VerificationFailed();
        }
    }

    /// @dev Checks cross-contract links, external code hashes, SBT configuration and Hook permission bits.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkLinks(address[6] memory a) private view {
        TSVRegistryV1 registry = TSVRegistryV1(a[0]);
        TSVVolumeLedgerV1 ledger = TSVVolumeLedgerV1(a[1]);
        TSVDataInboxV1 inbox = TSVDataInboxV1(a[2]);
        TSVHookV1 hook = TSVHookV1(a[3]);
        TSVSwapRouterV1 router = TSVSwapRouterV1(a[4]);
        TSVLPManagerV1 lp = TSVLPManagerV1(a[5]);
        address poolManager = _envAddress("TSV_POOL_MANAGER");
        address sbt = _envAddress("TSV_SBT");
        if (
            poolManager.code.length == 0 || sbt.code.length == 0
                || poolManager.codehash != _envBytes32("TSV_POOL_MANAGER_CODEHASH")
                || sbt.codehash != _envBytes32("TSV_SBT_CODEHASH") || address(registry.participantSbt()) != sbt
                || registry.sbtTokenId() != _envUint("TSV_SBT_TOKEN_ID") || registry.hook() != a[3]
                || registry.lpManager() != a[5] || registry.dataInbox() != a[2] || address(ledger.registry()) != a[0]
                || ledger.hook() != a[3] || ledger.dataInbox() != a[2] || address(inbox.registry()) != a[0]
                || address(inbox.ledger()) != a[1] || address(hook.poolManager()) != poolManager
                || address(hook.registry()) != a[0] || address(hook.ledger()) != a[1] || hook.router() != a[4]
                || hook.lpManager() != a[5] || address(router.poolManager()) != poolManager
                || address(router.registry()) != a[0] || address(router.ledger()) != a[1]
                || address(lp.poolManager()) != poolManager || address(lp.registry()) != a[0]
                || (uint160(a[3]) & 0x3FFF) != 0x3FFF
        ) revert VerificationFailed();
    }

    /// @dev Compares each proxy's implementation and implementation code hash with the deployment manifest.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkImplementations(address[6] memory a) private view {
        address[6] memory expected = [
            _envAddress("TSV_REGISTRY_IMPLEMENTATION"),
            _envAddress("TSV_VOLUME_LEDGER_IMPLEMENTATION"),
            _envAddress("TSV_DATA_INBOX_IMPLEMENTATION"),
            _envAddress("TSV_HOOK_IMPLEMENTATION"),
            _envAddress("TSV_SWAP_ROUTER_IMPLEMENTATION"),
            _envAddress("TSV_LP_MANAGER_IMPLEMENTATION")
        ];
        for (uint256 i; i < 6; ++i) {
            if (
                expected[i].code.length == 0 || expected[i].codehash != _envBytes32(_hashEnvName(i))
                    || TSVERC1967Proxy(payable(a[i])).tsvImplementation() != expected[i]
            ) revert VerificationFailed();
        }
    }

    /// @dev Maps a proxy index to the environment variable containing its implementation code hash.
    /// @param i Proxy index in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    /// @return Environment variable name for the implementation code hash.
    function _hashEnvName(uint256 i) private pure returns (string memory) {
        if (i == 0) return "TSV_REGISTRY_IMPLEMENTATION_CODEHASH";
        if (i == 1) return "TSV_VOLUME_LEDGER_IMPLEMENTATION_CODEHASH";
        if (i == 2) return "TSV_DATA_INBOX_IMPLEMENTATION_CODEHASH";
        if (i == 3) return "TSV_HOOK_IMPLEMENTATION_CODEHASH";
        if (i == 4) return "TSV_SWAP_ROUTER_IMPLEMENTATION_CODEHASH";
        return "TSV_LP_MANAGER_IMPLEMENTATION_CODEHASH";
    }
}

```

### script/DeployCoreV1.s.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @notice Deploys six initialized business proxies with an actual CREATE2 Hook address.
/// @dev Governance binding, SBT configuration and asset approvals remain separate governance transactions.
contract DeployCoreV1 is ScriptEnvironment {
    /// @dev Reverts when the chain, external contracts, code hashes, or governance links are invalid.
    error InvalidDeploymentInput();
    /// @dev Reverts when a deployed address or linked component differs from its prediction.
    error AddressPredictionMismatch();
    /// @dev Reverts when no salt produces a Hook proxy address with all required V4 permission bits.
    error HookSaltNotFound();

    uint160 private constant HOOK_FLAGS = 0x3FFF;
    uint256 private constant MAX_SALT_ATTEMPTS = 500_000;

    /// @dev Captures environment-provided dependencies and configuration for the core deployment.
    struct Input {
        /// @dev V4 PoolManager used by the Hook, Router and LP Manager.
        address poolManager;
        /// @dev Expected deployed bytecode hash for `poolManager`.
        bytes32 poolManagerCodeHash;
        /// @dev Fixed governance root storing identities and the global upgrade switch.
        TSVGovernanceAnchor anchor;
        /// @dev Participant SBT used by the Registry for credential checks.
        address sbt;
        /// @dev Expected deployed bytecode hash for `sbt`.
        bytes32 sbtCodeHash;
        /// @dev SBT token identifier required for participant eligibility.
        uint256 sbtTokenId;
        /// @dev UTC seconds after midnight at which a trade day begins.
        uint32 dayStartOffset;
    }

    /// @dev Collects deployed proxy addresses, implementation addresses and the Hook salt.
    struct Deployment {
        /// @dev Deployed Registry proxy.
        TSVRegistryV1 registry;
        /// @dev Deployed volume Ledger proxy.
        TSVVolumeLedgerV1 ledger;
        /// @dev Deployed report Inbox proxy.
        TSVDataInboxV1 inbox;
        /// @dev Deployed Swap Router proxy.
        TSVSwapRouterV1 router;
        /// @dev Deployed LP Manager proxy.
        TSVLPManagerV1 lpManager;
        /// @dev Deployed Hook proxy.
        TSVHookV1 hook;
        /// @dev Factory used to deploy the Hook proxy.
        TSVHookProxyFactoryV1 hookFactory;
        /// @dev CREATE2 salt that produced the Hook's V4 permission address.
        bytes32 hookSalt;
        /// @dev Implementation addresses corresponding to each proxy.
        Implementations implementations;
    }

    /// @dev Stores implementation addresses corresponding to the core proxy contracts.
    struct Implementations {
        /// @dev Registry implementation address.
        address registry;
        /// @dev Volume Ledger implementation address.
        address ledger;
        /// @dev Data Inbox implementation address.
        address inbox;
        /// @dev Swap Router implementation address.
        address router;
        /// @dev LP Manager implementation address.
        address lpManager;
        /// @dev Hook implementation address.
        address hook;
    }

    /// @notice Deploys and initializes the six core proxy contracts and their implementations.
    /// @dev Reads deployment inputs from the environment and checks the predicted CREATE2 Hook address.
    /// @return d The deployed proxies, Hook factory, salt and implementation addresses.
    function run() external returns (Deployment memory d) {
        uint256 deployerKey = _envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        Input memory input = _loadInput();
        _checkInput(input);

        vm.startBroadcast(deployerKey);
        _deployBase(input, d);
        vm.stopBroadcast();

        _deployDependent(input, d, deployerKey, deployer);
        _logDeployment(d);
    }

    /// @dev Deploys the Registry, Ledger and Inbox proxies plus implementations for dependent components.
    /// @param input Validated addresses and configuration used to initialize the core proxies.
    /// @param d Deployment record populated with proxy and implementation addresses.
    function _deployBase(Input memory input, Deployment memory d) private {
        d.implementations.registry = address(new TSVRegistryV1());
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.registry, abi.encodeCall(TSVRegistryV1.initialize, (address(input.anchor)))
                )
            )
        );
        d.implementations.ledger = address(new TSVVolumeLedgerV1());
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.ledger,
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize, (address(input.anchor), address(d.registry), input.dayStartOffset)
                    )
                )
            )
        );
        d.implementations.inbox = address(new TSVDataInboxV1());
        d.inbox = TSVDataInboxV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.inbox,
                    abi.encodeCall(
                        TSVDataInboxV1.initialize, (address(input.anchor), address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.implementations.router = address(new TSVSwapRouterV1());
        d.implementations.lpManager = address(new TSVLPManagerV1());
        d.implementations.hook = address(new TSVHookV1());
        d.hookFactory = new TSVHookProxyFactoryV1();
    }

    /// @dev Predicts dependent proxy addresses, deploys Router, LP Manager and a flag-compatible Hook.
    /// @param input Validated external dependencies and governance configuration.
    /// @param d Deployment record populated by the base deployment stage.
    /// @param deployerKey Private key used to broadcast the dependent deployments.
    /// @param deployer Address whose next CREATE nonces determine Router and LP Manager addresses.
    function _deployDependent(Input memory input, Deployment memory d, uint256 deployerKey, address deployer) private {
        uint64 nextNonce = vm.getNonce(deployer);
        address predictedRouter = vm.computeCreateAddress(deployer, nextNonce);
        address predictedLpManager = vm.computeCreateAddress(deployer, uint256(nextNonce) + 1);
        bytes memory hookInitData = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(input.anchor),
                input.poolManager,
                address(d.registry),
                address(d.ledger),
                predictedRouter,
                predictedLpManager
            )
        );
        address predictedHook;
        (d.hookSalt, predictedHook) = _mineHook(d.hookFactory, d.implementations.hook, hookInitData);

        vm.startBroadcast(deployerKey);
        d.router = TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.router,
                    abi.encodeCall(
                        TSVSwapRouterV1.initialize,
                        (address(input.anchor), input.poolManager, address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.lpManager = TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.lpManager,
                    abi.encodeCall(
                        TSVLPManagerV1.initialize, (address(input.anchor), input.poolManager, address(d.registry))
                    )
                )
            )
        );
        d.hook = TSVHookV1(d.hookFactory.deploy(d.implementations.hook, hookInitData, d.hookSalt));
        vm.stopBroadcast();

        if (
            address(d.router) != predictedRouter || address(d.lpManager) != predictedLpManager
                || address(d.hook) != predictedHook || (uint160(address(d.hook)) & HOOK_FLAGS) != HOOK_FLAGS
                || TSVERC1967Proxy(payable(address(d.hook))).tsvImplementation() != d.implementations.hook
                || d.hook.router() != address(d.router) || d.hook.lpManager() != address(d.lpManager)
                || address(d.lpManager.registry()) != address(d.registry)
        ) revert AddressPredictionMismatch();
    }

    /// @dev Prints proxy addresses, implementation addresses, the Hook salt and required follow-up steps.
    /// @param d Deployment record to log.
    function _logDeployment(Deployment memory d) private pure {
        console2.log("Registry", address(d.registry));
        console2.log("VolumeLedger", address(d.ledger));
        console2.log("DataInbox", address(d.inbox));
        console2.log("SwapRouter", address(d.router));
        console2.log("LPManager and Receipt", address(d.lpManager));
        console2.log("Hook", address(d.hook));
        console2.log("HookFactory", address(d.hookFactory));
        console2.log("RegistryImplementation", d.implementations.registry);
        console2.log("VolumeLedgerImplementation", d.implementations.ledger);
        console2.log("DataInboxImplementation", d.implementations.inbox);
        console2.log("SwapRouterImplementation", d.implementations.router);
        console2.log("LPManagerImplementation", d.implementations.lpManager);
        console2.log("HookImplementation", d.implementations.hook);
        console2.log("Hook CREATE2 salt:");
        console2.logBytes32(d.hookSalt);
        console2.log(
            "Governance must bind Anchor proxies, Registry/Ledger, configure SBT and grant roles before opening assets."
        );
    }

    /// @dev Loads addresses, code hashes, SBT identity and trade-day offset from environment variables.
    /// @return input Deployment configuration read from the environment.
    function _loadInput() internal view returns (Input memory input) {
        input.poolManager = _envAddress("TSV_POOL_MANAGER");
        input.poolManagerCodeHash = _envBytes32("TSV_POOL_MANAGER_CODEHASH");
        input.anchor = TSVGovernanceAnchor(_envAddress("TSV_GOVERNANCE_ANCHOR"));
        input.sbt = _envAddress("TSV_SBT");
        input.sbtCodeHash = _envBytes32("TSV_SBT_CODEHASH");
        input.sbtTokenId = _envUint("TSV_SBT_TOKEN_ID");
        uint256 offset = _envUint("TSV_DAY_START_OFFSET_SECONDS");
        if (offset >= 86_400) revert InvalidDeploymentInput();
        input.dayStartOffset = uint32(offset);
    }

    /// @dev Verifies chain, code hashes and the pre-bound governance relationships before broadcasting.
    /// @param input Deployment configuration to validate.
    function _checkInput(Input memory input) internal view {
        if (
            block.chainid != _envUint("TSV_CHAIN_ID") || input.poolManager.code.length == 0
                || input.poolManagerCodeHash == 0 || input.poolManager.codehash != input.poolManagerCodeHash
                || input.sbt.code.length == 0 || input.sbtCodeHash == 0 || input.sbt.codehash != input.sbtCodeHash
                || address(input.anchor).code.length == 0 || input.anchor.proxiesBound()
                || input.anchor.governor() != _envAddress("TSV_GOVERNOR")
                || input.anchor.guardian() != _envAddress("TSV_GUARDIAN")
                || input.anchor.recoveryCouncil() != _envAddress("TSV_RECOVERY_COUNCIL")
        ) revert InvalidDeploymentInput();
        try ISmartWalletSbtV1(input.sbt).paused() returns (bool) {}
        catch {
            revert InvalidDeploymentInput();
        }
        try ISmartWalletSbtV1(input.sbt).verify(address(this), input.sbtTokenId) returns (bool) {}
        catch {
            revert InvalidDeploymentInput();
        }
    }

    /// @dev Searches salts until the predicted proxy address has the required Uniswap V4 Hook permission bits.
    /// @param factory Factory used to calculate deterministic proxy addresses.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization call encoded for the Hook proxy.
    /// @return salt Salt that produces an address with all required Hook flags.
    /// @return predicted Predicted Hook proxy address for the selected salt.
    function _mineHook(TSVHookProxyFactoryV1 factory, address implementation, bytes memory initData)
        private
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < MAX_SALT_ATTEMPTS; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(implementation, initData, salt);
            if ((uint160(predicted) & HOOK_FLAGS) == HOOK_FLAGS && predicted.code.length == 0) {
                return (salt, predicted);
            }
        }
        revert HookSaltNotFound();
    }
}

```

### script/ScriptEnvironment.sol — SECURITY REVIEW

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

/// @dev Environment readers can be overridden with isolated inputs in script tests.
abstract contract ScriptEnvironment is Script {
    function _envAddress(string memory name) internal view virtual returns (address) {
        return vm.envAddress(name);
    }

    function _envBytes32(string memory name) internal view virtual returns (bytes32) {
        return vm.envBytes32(name);
    }

    function _envUint(string memory name) internal view virtual returns (uint256) {
        return vm.envUint(name);
    }
}

```

### test/README.md — TEST SCENARIO COVERAGE ONLY

```md
# 测试目录与维护方式

测试按业务场景组织。共享 fixture 只准备环境和提供构造/快照/断言工具，不包含 `test*` 或 `invariant*`；测试套件只继承 fixture，避免继承另一个套件后重复执行。

尚待补测和验收的工作统一记录在[测试缺口清单](../docs/TEST_GAPS_V1.md)，按固定 ID 管理；已执行结果见[覆盖矩阵](../docs/TEST_COVERAGE_V1.md)。

## 从哪里开始

| 要验证的行为 | 目录 / 文件 |
| --- | --- |
| Governor 单笔升级、Guardian 冻结、身份恢复、角色保护、代理绑定、批量升级、治理事件 | `unit/v1/governance/` |
| 交易 + LP 随机序列、独立仓位/额度/资产模型 | `integration/local/trading/StatefulTradingLP.t.sol` |
| 固定区块链上 DexRouter/授权合约 → 测试 Adapter → TSV/V4/LP | `integration/xlayer/DexRouterFlow.t.sol` |
| 治理随机操作序列 | `unit/v1/governance/StatefulGovernance.t.sol` |
| CREATE/CREATE2 预测与 Hook 权限地址 | `unit/v1/deployment/HookFactory.t.sol` |
| 证券/Token/池准入与业务暂停 | `unit/v1/registry/` |
| ADTV、quota、市场报告、拆并股系数和 UTC 日切 | `unit/v1/reports/` |
| 拆/并股系数、边界/拒绝、真实 V4 自动生效 | `unit/v1/reports/SplitFactor*.t.sol`、`integration/local/operations/SplitFactorFlows.t.sol` |
| 报告/日切随机交错与独立季度日历模型 | `unit/v1/reports/StatefulOperations.t.sol` |
| 真实 V4 下的报告更正、跨月、20/28 小时过渡日、上下架及 Adapter 变更 | `integration/local/operations/` |
| 成交量计量、共享额度和交易暂停门禁 | `unit/v1/trading/VolumeAccounting.t.sol` |
| 法律股数换算 | `unit/v1/adapters/` |
| 真实 V4 直接/Adapter 交易、精确输入/输出、结算失败回滚 | `integration/local/trading/` |
| 仓位生命周期、Position ID、Receipt、强制退出 | `integration/local/liquidity/` |
| 六组件 V2 迁移、已有资金/业务状态保留、冻结中恢复 | `integration/local/governance/` |
| 真实 V4 准入和暂停门禁 | `integration/local/registry/` |
| 历史结算 Adapter | `unit/legacy/`，不计入当前 V1 交易路径覆盖 |

后续交易用例放入 `unit/v1/trading/` 或 `integration/local/trading/`；治理用例放入对应的 `governance/`。固定区块 DEX 集成已在 `integration/xlayer/` 落地；真实生产资产/TSV 与多签演练仍按 `integration/governance/` 及发布清单另行验收。不要创建始终通过或自动跳过的占位测试。

## 公共环境

| Fixture / helper | 用途 |
| --- | --- |
| `helpers/v1/GovernanceFixture.sol` | 固定 Anchor、独立 Guardian/Council、单个 Registry 代理 |
| `helpers/v1/SixProxyFixture.sol` | 六个真实 UUPS 代理和组件链接；Hook 地址安装用于权限单元测试，CREATE2 由部署套件验证 |
| `helpers/v1/FoundationFixture.sol` | Registry、Ledger、Inbox 与准入/报告构造工具 |
| `helpers/v1/OperationsFixture.sol` / `OperationsMocks.sol` | 报告元数据、失败状态快照与区分 tokenId 的 SBT 故障夹具 |
| `helpers/v1/SplitFactorFixture.sol` | 继承运营环境，集中构造系数报告及接受/拒绝状态快照 |
| `helpers/v1/OperationsHandler.sol` | 八类报告/额度/系数/时间/排期/权限操作；独立维护 ADTV、quota、线性因子检查点、去重、来源序号和 UTC 日期/边界 |
| `helpers/v1/ProtocolFixture.sol` | 真实本地 V4 PoolManager、行为 mock、已注资的 LP 仓位 |
| `helpers/v1/GovernanceUpgradeMocks.sol` | 追加存储的兼容 V2、失败迁移、外部写入、授权回调和角色测试替身 |
| `helpers/v1/TradingLPHandler.sol` | 十类操作混合序列；独立计算每笔法定股数、每日额度、两 owner 的仓位/Receipt、资产守恒及 V4 零欠款 |
| `helpers/v1/DexRouterTestAdapter.sol` | 测试用 DEX callback、认证参与者、精确授权/结算及部分成交退款 |
| `helpers/v1/GovernanceHandler.sol` | 独立维护身份、审批、冻结与实现地址模型；随机合法/非法调用后比较实际状态 |

`GovernorExecutor` 验证合约账户调用治理入口及授权回调，不代表 Safe 或生产多签的签名、门槛、模块和执行方式已经验证。V2 替身证明示例布局的兼容性，每个真实候选版本仍需单独核验布局和迁移。

## 常用命令

也可在仓库根目录执行 `make test`、`make test-governance`、`make test-trading`、`make test-liquidity`、`make test-operations`、`make test-invariants`、`make test-xlayer` 或 `make check`。各领域快捷命令同时选择对应的单元与本地集成用例。

```sh
# 目录规则和全套不联网回归（包含治理、交易/LP invariant）
python3 script/check-test-layout.py
forge test --summary

# 分层运行
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary

# 单独运行治理、交易和仓位测试
forge test --match-path 'test/unit/v1/governance/*.t.sol'
forge test --match-path 'test/integration/local/trading/*.t.sol'
forge test --match-path 'test/integration/local/liquidity/*.t.sol'
make test-operations
# 系数专项和独立运营模型
forge test --match-contract 'TSV(SplitFactor.*|StatefulOperations)Test' --fuzz-seed 0x20261004

# 随机序列：默认每项性质 64 轮，每轮 32 步；提高强度或复现失败
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract TSVStatefulGovernanceTest
forge test --match-contract TSVStatefulTradingLPTest --fuzz-seed <失败日志中的seed>
forge test --match-contract TSVStatefulOperationsTest --fuzz-seed <失败日志中的seed>

# 固定区块链上 DEX 集成；可选设置 XLAYER_RPC_URL 为同链 archive RPC
make test-xlayer

# 插桩覆盖率；行/分支覆盖率不能替代业务场景和状态序列检查
make coverage
forge fmt --check
git diff --check
```

## 新用例怎么写

1. 按业务行为选择目录，一个文件聚焦一类规则，一个测试聚焦一个成功或失败原因。
2. 名称写清动作与预期，例如 `testReproposingCancelledProposalRequiresFreshGuardianApproval`。矩阵/随机测试说明生成范围与共同规则。
3. 按“准备 → 操作 → 验证”书写；先构造参数，再设置 `vm.prank`/`vm.expectRevert`，避免参数中的外部 getter 或新部署消耗下一次调用的作弊码。
4. 跨 `vm.warp` 多次生成报告/请求时用 `vm.getBlockTimestamp()` 取得当前时间，避免优化器缓存测试合约内的 `block.timestamp`。已定义错误时校验具体 selector；失败交易同时比较实现地址、业务快照和外部写入，不能只检查发生回滚。
5. 新增共享 mock 放在 `helpers/v1/`。优先复用原子性快照和请求构造器，避免把业务断言藏在部署测试里。
6. 新增生产环境用例必须记录链、固定区块、地址/codehash、真实多签配置和受控测试账户；缺少配置时保留待验收说明，不伪装成通过结果。

全部原有具名用例保留，Position ID 套件改为继承无用例的 `ProtocolFixture`，不再重复执行整套协议集成测试。通过数量因此不能直接与旧目录中的继承计数比较。

覆盖矩阵、实际执行记录与未验收边界见 [TEST_COVERAGE_V1.md](../docs/TEST_COVERAGE_V1.md)。覆盖率只能辅助发现未触达路径；不能用单一百分比代表全部场景已验证。

运营入口逐项 review、新增用例和链下验收缺口见 [OPERATIONS_TEST_REVIEW_V1.md](../docs/OPERATIONS_TEST_REVIEW_V1.md)。运营单元 fixture 的 Hook 写入只验证账本，资金完整路径使用 `integration/local/operations/` 中的真实 V4。

覆盖率使用独立的 `coverage` profile（`out/coverage`、`cache/coverage`），避免插桩编译反复使普通测试缓存失效。首次完整 via-IR 编译较久，后续仅修改的套件需要重编译。

```

### test/unit/legacy/TSVIssuerAdapter.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";
import {IssuerShareSettlementAdapter, IActiveAssetOperation} from "tsv-v1/legacy/IssuerShareSettlementAdapter.sol";

/// @dev Exercises issuer-share settlement and redemption behavior.
contract TSVIssuerAdapterTest is Test, IActiveAssetOperation {
    bytes32 private constant OP = keccak256("operation");
    bytes32 private constant POOL = keccak256("pool");
    V1MockIssuerShares internal underlying;
    V1MockIssuerWrapped internal wrapped;
    IssuerShareSettlementAdapter internal adapter;
    address internal alice;
    bool internal forced;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public {
        alice = makeAddr("alice");
        underlying = new V1MockIssuerShares();
        wrapped = new V1MockIssuerWrapped(underlying);
        adapter = new IssuerShareSettlementAdapter(address(underlying), address(wrapped), address(this), address(this));
        underlying.mintShares(alice, 10e18);
        underlying.setMultiplier(0.9e18, 7);
        vm.prank(alice);
        underlying.approve(address(adapter), type(uint256).max);
    }

    /// @dev Returns the active issuer-asset operation context used by the adapter.
    function activeAssetOperation(bytes32 operationId, address currency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit)
    {
        if (operationId != OP || currency != address(wrapped)) return (0, address(0), address(0), false);
        return (POOL, alice, alice, forced);
    }

    /// @dev Verifies wrapping and redeeming preserve exact shares and enforce display bounds.
    function testWrapThenRedeemExactSharesAndDisplayBounds() public {
        uint256 ownerSharesBefore = underlying.sharesOf(alice);
        uint256 ownerDisplayedBefore = underlying.balanceOf(alice);
        assertEq(adapter.pullAndWrap(alice, address(this), 3e18, 2.7e18, OP), 3e18);
        assertEq(ownerSharesBefore - underlying.sharesOf(alice), 3e18);
        assertEq(ownerDisplayedBefore - underlying.balanceOf(alice), 2.7e18);
        assertEq(underlying.sharesOf(address(wrapped)), 3e18);
        assertEq(wrapped.balanceOf(address(this)), 3e18);

        adapter.prepareReceive(3e18, OP);
        wrapped.transfer(address(adapter), 3e18);
        assertEq(adapter.redeemAndDeliver(alice, 3e18, 2.7e18, OP), 3e18);
        assertEq(underlying.sharesOf(alice), ownerSharesBefore);
        assertEq(underlying.sharesOf(address(wrapped)), 0);
        assertEq(wrapped.totalSupply(), 0);
    }

    /// @dev Verifies an excessive displayed-debit limit reverts without moving shares.
    function testDisplayedDebitLimitRevertsWithoutMovingShares() public {
        uint256 beforeShares = underlying.sharesOf(alice);
        vm.expectRevert(IssuerShareSettlementAdapter.SlippageExceeded.selector);
        adapter.pullAndWrap(alice, address(this), 3e18, 2.6e18, OP);
        assertEq(underlying.sharesOf(alice), beforeShares);
        assertEq(wrapped.totalSupply(), 0);
    }

    /// @dev Verifies a refused forced delivery rolls back the entire operation.
    function testForcedDeliveryRefusalRollsBackWholeOperation() public {
        adapter.pullAndWrap(alice, address(this), 3e18, 2.7e18, OP);
        forced = true;
        underlying.setBlocked(alice, true);
        uint256 beforeWrapped = wrapped.balanceOf(address(this));
        uint256 beforeOwnerShares = underlying.sharesOf(alice);
        vm.expectRevert();
        this.redeemAtomically(3e18);
        assertEq(wrapped.balanceOf(address(this)), beforeWrapped);
        assertEq(wrapped.balanceOf(address(adapter)), 0);
        assertEq(underlying.sharesOf(alice), beforeOwnerShares);
        assertEq(underlying.sharesOf(address(wrapped)), 3e18);
    }

    /// @dev Runs a redemption inside the adapter operation context and enforces atomic delivery.
    function redeemAtomically(uint256 shares) external {
        adapter.prepareReceive(shares, OP);
        wrapped.transfer(address(adapter), shares);
        adapter.redeemAndDeliver(alice, shares, 0, OP);
    }
}

```

### test/unit/v1/adapters/BackedAdapter.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVBackedAdapterTest scenarios; inherited fixtures contain no test functions.
contract TSVBackedAdapterTest is FoundationFixture {
    /// @dev Verifies the backed adapter reads the issuer conversion when the swap occurs.
    function testBackedAdapterCallsIssuerConversionAtTheTimeOfSwap() public {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped wrapped = new V1MockIssuerWrapped(underlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(underlying), address(wrapped), 1);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 3e18);
        underlying.setMultiplier(0.9e18, 7);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.7e18);
        underlying.setMultiplier(0.8e18, 8);
        assertEq(adapter.toLegalShares(address(wrapped), 3e18), 2.4e18);
    }

    /// @dev Verifies the backed adapter validates Currency and accepts a zero amount.
    function testBackedAdapterValidatesCurrencyAndAllowsZeroAmount() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        assertEq(adapter.toLegalShares(address(stock), 0), 0);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidCurrency.selector);
        adapter.toLegalShares(address(quote), 1e18);
    }

    /// @dev Verifies the backed adapter rejects a wrapped-token asset mismatch.
    function testBackedAdapterRejectsWrappedAssetMismatch() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped otherWrapped = new V1MockIssuerWrapped(otherUnderlying);
        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidAdapterConfig.selector);
        new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(otherWrapped), 1);
    }

    /// @dev Verifies the backed adapter rejects zero conversion and reports its direct interface.
    function testBackedAdapterRejectsZeroConversionAndDeclaresDirectInterface() public {
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        stockUnderlying.setMultiplier(0, 1);

        vm.expectRevert(BackedAutoFeeLegalShareAdapter.InvalidConversion.selector);
        adapter.toLegalShares(address(stock), 1);
        assertTrue(adapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId));
    }
}

```

### test/unit/v1/adapters/ERC8056DirectLegalShareAdapter.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC8056TestToken} from "../../../../lib/TestToken/erc8056/ERC8056TestToken.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

contract ERC8056DirectLegalShareAdapterTest is Test {
    function testConvertsUsingMultiplierActiveAtCallTime() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);

        assertEq(adapter.toLegalShares(address(token), 3e18), 3e18);
        token.setUIMultiplier(2e18, block.timestamp + 10);
        assertEq(adapter.toLegalShares(address(token), 3e18), 3e18);

        vm.warp(block.timestamp + 10);
        assertEq(adapter.toLegalShares(address(token), 3e18), 6e18);
    }

    function testScalesUsingTokenDecimals() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 6, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);

        assertEq(adapter.toLegalShares(address(token), 1_500_001), 1_500_001e12);
    }

    function testUsesFloorRounding() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);
        token.setUIMultiplier(5e17, block.timestamp + 1);
        vm.warp(block.timestamp + 1);

        assertEq(adapter.toLegalShares(address(token), 3), 1);
    }

    function testZeroRawAmountConvertsToZero() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);

        assertEq(adapter.toLegalShares(address(token), 0), 0);
    }

    function testRejectsOtherCurrency() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056TestToken other = new ERC8056TestToken("Other", "OTH", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidCurrency.selector);
        adapter.toLegalShares(address(other), 1e18);
    }

    function testDeclaresDirectAdapterInterface() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token), 1);

        assertTrue(adapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId));
    }

    function testRejectsDecimalsAboveSupportedBound() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 19, 0);

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidAdapterConfig.selector);
        new ERC8056DirectLegalShareAdapter(address(token), 1);
    }
}

```

### test/unit/v1/deployment/HookFactory.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @dev Exercises CREATE/CREATE2 address prediction and Hook proxy deployment only.
contract TSVHookFactoryTest is Test {
    /// @dev Collects the deployments and dependencies shared by Hook factory tests.
    struct Base {
        /// @dev Governance anchor for the fixture.
        TSVGovernanceAnchor anchor;
        /// @dev Registry proxy used by the core components.
        TSVRegistryV1 registry;
        /// @dev Volume Ledger proxy used by the Hook and Inbox.
        TSVVolumeLedgerV1 ledger;
        /// @dev Data Inbox proxy used for test report submission.
        TSVDataInboxV1 inbox;
        /// @dev Swap Router implementation deployed for the fixture.
        address routerImpl;
        /// @dev LP Manager implementation deployed for the fixture.
        address lpImpl;
        /// @dev Hook implementation deployed for the fixture.
        address hookImpl;
        /// @dev Factory used to deploy the Hook proxy at a V4-compatible address.
        TSVHookProxyFactoryV1 factory;
        /// @dev Swap Router proxy used by the deployed Hook.
        TSVSwapRouterV1 router;
        /// @dev LP Manager proxy used by the deployed Hook.
        TSVLPManagerV1 lp;
        /// @dev Hook proxy deployed for the fixture.
        TSVHookV1 hook;
    }

    /// @dev Verifies proxy rejects empty initialization data.
    function testProxyRejectsEmptyInitializationData() public {
        TSVHookV1 implementation = new TSVHookV1();

        vm.expectRevert(TSVERC1967Proxy.EmptyInitializationData.selector);
        new TSVERC1967Proxy(address(implementation), "");
    }

    /// @dev Verifies mined proxy has V4 permissions and stable implementation getter.
    function testMinedProxyHasV4PermissionsAndStableImplementationGetter() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        Base memory d = _makeGovernance();
        vm.etch(address(0xBEEF), hex"00");
        vm.etch(address(0xF00D), hex"00");
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize,
            (address(d.anchor), address(this), address(this), address(this), address(0xBEEF), address(0xF00D))
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(address(implementation), initData, salt);
            if ((uint160(predicted) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predicted) & 0x3FFF, 0x3FFF);
        address proxy = factory.deploy(address(implementation), initData, salt);
        assertEq(proxy, predicted);
        assertEq(TSVERC1967Proxy(payable(proxy)).tsvImplementation(), address(implementation));
        assertEq(address(TSVHookV1(proxy).governanceAnchor()), address(d.anchor));
        assertTrue(TSVHookV1(proxy).hasRole(0, address(this)));
        vm.expectRevert();
        factory.deploy(address(implementation), initData, salt);
    }

    /// @dev Verifies wrong permission salt reverts.
    function testWrongPermissionSaltReverts() public {
        TSVHookProxyFactoryV1 factory = new TSVHookProxyFactoryV1();
        TSVHookV1 implementation = new TSVHookV1();
        bytes memory initData = abi.encodeCall(
            TSVHookV1.initialize, (address(1), address(4), address(5), address(6), address(7), address(8))
        );
        bytes32 salt;
        while ((uint160(factory.predict(address(implementation), initData, salt)) & 0x3FFF) == 0x3FFF) {
            salt = bytes32(uint256(salt) + 1);
        }
        vm.expectRevert(TSVHookProxyFactoryV1.InvalidHookAddress.selector);
        factory.deploy(address(implementation), initData, salt);
    }

    /// @dev Verifies six proxy deployment uses actual predicted addresses.
    function testSixProxyDeploymentUsesActualPredictedAddresses() public {
        vm.warp(1_800_000_000);
        Base memory d = _deployBase();
        uint64 nextNonce = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), nextNonce);
        address predictedLp = vm.computeCreateAddress(address(this), uint256(nextNonce) + 1);
        bytes memory hookInit = abi.encodeCall(
            TSVHookV1.initialize,
            (address(d.anchor), address(this), address(d.registry), address(d.ledger), predictedRouter, predictedLp)
        );
        bytes32 salt;
        address predictedHook;
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predictedHook = d.factory.predict(d.hookImpl, hookInit, salt);
            if ((uint160(predictedHook) & 0x3FFF) == 0x3FFF) break;
        }
        assertEq(uint160(predictedHook) & 0x3FFF, 0x3FFF);

        TSVSwapRouterV1 router = _deployRouter(d);
        TSVLPManagerV1 lp = _deployLp(d);
        TSVHookV1 hook = TSVHookV1(d.factory.deploy(d.hookImpl, hookInit, salt));

        assertEq(address(router), predictedRouter);
        assertEq(address(lp), predictedLp);
        assertEq(address(hook), predictedHook);
        assertEq(hook.router(), address(router));
        assertEq(hook.lpManager(), address(lp));
        d.registry.bindComponents(address(hook), address(lp), address(d.inbox));
        d.ledger.bindWriters(address(hook), address(d.inbox));
        assertEq(d.registry.hook(), address(hook));
        assertEq(d.ledger.hook(), address(hook));
        address[6] memory addresses =
            [address(d.registry), address(d.ledger), address(d.inbox), address(hook), address(router), address(lp)];
        address[6] memory wrongAddresses;
        for (uint256 i; i < 6; ++i) {
            wrongAddresses[i] = addresses[i];
        }
        wrongAddresses[5] = address(router);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        d.anchor.bindProxies(wrongAddresses);
        d.anchor.bindProxies(addresses);
        assertTrue(d.anchor.proxiesBound());
        d.router = router;
        d.lp = lp;
        d.hook = hook;
    }

    /// @dev Deploys the base contracts shared by the Hook factory scenario.
    function _deployBase() private returns (Base memory d) {
        d = _makeGovernance();
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(d.anchor)))
                )
            )
        );
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(d.anchor), address(d.registry), uint32(0)))
                )
            )
        );
        d.inbox = TSVDataInboxV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(
                        TSVDataInboxV1.initialize, (address(d.anchor), address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.routerImpl = address(new TSVSwapRouterV1());
        d.lpImpl = address(new TSVLPManagerV1());
        d.hookImpl = address(new TSVHookV1());
        d.factory = new TSVHookProxyFactoryV1();
    }

    /// @dev Deploys and initializes the Swap Router proxy for the fixture.
    function _deployRouter(Base memory d) private returns (TSVSwapRouterV1) {
        return TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    d.routerImpl,
                    abi.encodeCall(
                        TSVSwapRouterV1.initialize,
                        (address(d.anchor), address(this), address(d.registry), address(d.ledger))
                    )
                )
            )
        );
    }

    /// @dev Deploys and initializes the LP Manager proxy for the fixture.
    function _deployLp(Base memory d) private returns (TSVLPManagerV1) {
        return TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.lpImpl,
                    abi.encodeCall(TSVLPManagerV1.initialize, (address(d.anchor), address(this), address(d.registry)))
                )
            )
        );
    }

    /// @dev Deploys and links the governance contracts required by the fixture.
    function _makeGovernance() private returns (Base memory d) {
        d.anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
    }
}

```

### test/unit/v1/governance/RecoveryAcrossProxies.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

contract TSVRecoveryAcrossProxiesTest is SixProxyFixture {
    function testGovernorRecoveryUpdatesAllSixProxiesAndPreservesBusinessRoles() public {
        address guardian = anchor.guardian();
        address council = anchor.recoveryCouncil();
        address nextGovernor = makeAddr("next-governor");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("governor-recovery-risk"));
        vm.prank(council);
        bytes32 id =
            anchor.proposeRecovery(nextGovernor, guardian, keccak256("recovery-salt"), keccak256("recovery-evidence"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), nextGovernor);
        assertEq(anchor.epoch(), 1);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        assertEq(anchor.freezeEpoch(), 1);
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
        for (uint256 i; i < 6; ++i) {
            TSVGoverned proxy = TSVGoverned(businessProxies[i]);
            address implementation = TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation();
            assertEq(address(proxy.governanceAnchor()), address(anchor));
            assertFalse(proxy.hasRole(0, address(this)));
            assertTrue(proxy.hasRole(0, nextGovernor));
            vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
            proxy.upgradeToAndCall(implementation, "");
            vm.prank(nextGovernor);
            vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
            proxy.upgradeToAndCall(implementation, "");
        }
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(guardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        TSVRegistryV1 newImplementation = new TSVRegistryV1();
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(address(newImplementation), "");
        assertEq(TSVERC1967Proxy(payable(address(registry))).tsvImplementation(), address(newImplementation));
    }
}

```

### test/unit/v1/governance/DirectUpgrade.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {V1RegistryUpgradeMock} from "../../../helpers/v1/DirectUpgradeMock.sol";

/// @dev TSVDirectUpgradeTest scenarios; inherited fixtures contain no test functions.
contract TSVDirectUpgradeTest is GovernanceFixture {
    function testUpgradeInitializationFailureRollsBackImplementationAndStorage() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address oldImplementation = proxy.tsvImplementation();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        vm.expectRevert(V1RegistryUpgradeMock.UpgradeInitFailed.selector);
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, true)));
        assertEq(proxy.tsvImplementation(), oldImplementation);
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(registry.governanceAnchor()), address(anchor));
        assertTrue(registry.hasRole(0, address(this)));
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (99, false)));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 99);
    }

    function testNonGovernorRolesCannotUpgrade() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        TSVRegistryV1 next = new TSVRegistryV1();
        address operator = makeAddr("operator");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), operator);
        address[4] memory callers = [guardian, council, operator, makeAddr("outsider")];
        address oldImplementation = proxy.tsvImplementation();
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
            registry.upgradeToAndCall(address(next), "");
            assertEq(proxy.tsvImplementation(), oldImplementation);
        }
    }

    function testInvalidImplementationDoesNotChangeProxy() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address oldImplementation = proxy.tsvImplementation();
        vm.expectRevert();
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(anchor), "");
        assertEq(proxy.tsvImplementation(), oldImplementation);
        vm.expectRevert();
        TSVRegistryV1(address(proxy)).upgradeToAndCall(makeAddr("no-code"), "");
        assertEq(proxy.tsvImplementation(), oldImplementation);
    }

    function testGovernorUpgradeAndInitializationCompleteInOneCall() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        uint256 timestamp = block.timestamp;
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, false)));
        assertEq(proxy.tsvImplementation(), address(next));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 42);
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(registry.governanceAnchor()), address(anchor));
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
        assertEq(block.timestamp, timestamp);
        assertFalse(anchor.upgradesFrozen());
    }
}

```

### test/unit/v1/governance/BatchBoundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {
    GovernanceMigrationV2,
    RegistryV2,
    LedgerV2,
    MigrationJournal,
    WrongUUIDImplementation,
    GovernorExecutor
} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGovernanceAnchor, IAnchoredProxyV1} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Batch input validation, migration authorization, atomic rollback and callback boundaries.
contract TSVBatchBoundariesTest is SixProxyFixture {
    function testBatchRejectsEmptyAndOversizedPlans() public {
        UpgradePlan memory empty = _currentPlan(0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(empty);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(new address[](7), new address[](7), new bytes[](7));
        assertFalse(anchor.upgradeContextActive());
    }

    function testBatchRejectsMismatchedInitializationDataLength() public {
        UpgradePlan memory plan = _currentPlan(2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(plan.targets, plan.implementations, new bytes[](1));
        _assertImplementations(plan);
    }

    function testBatchRejectsImplementationWithoutCode() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory invalid = _currentPlan(2);
        invalid.implementations[1] = makeAddr("no-code");
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(invalid);
        _assertImplementations(old);
    }

    function testBatchRejectsNonUUPSImplementationAndRollsBackEarlierUpgrade() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory invalid = _currentPlan(2);
        invalid.implementations[0] = address(new RegistryV2());
        invalid.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        invalid.implementations[1] = address(anchor);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(anchor)));
        _execute(invalid);
        _assertImplementations(old);
    }

    function testBatchRejectsWrongProxiableUUID() public {
        UpgradePlan memory old = _currentPlan(1);
        UpgradePlan memory invalid = _currentPlan(1);
        invalid.implementations[0] = address(new WrongUUIDImplementation());
        vm.expectRevert(
            abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(uint256(1)))
        );
        _execute(invalid);
        _assertImplementations(old);
    }

    function testSixProxiesUpgradeToDistinctV2ImplementationsAndMigrateOnce() public {
        UpgradePlan memory old = _currentPlan(6);
        UpgradePlan memory plan = _v2Plan();
        _execute(plan);
        _assertImplementations(plan);
        for (uint256 i; i < 6; ++i) {
            assertNotEq(plan.implementations[i], old.implementations[i]);
            GovernanceMigrationV2 migrated = GovernanceMigrationV2(plan.targets[i]);
            assertEq(migrated.migrationMarker(), 42);
            assertEq(migrated.migrationCaller(), address(anchor));
            assertTrue(TSVGoverned(plan.targets[i]).hasRole(bytes32(0), address(this)));
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            migrated.initializeV2(99, false);
        }
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(ledger.registry()), address(registry));
        assertEq(lp.nextPositionId(), 1);
    }

    function testFuzzFailureAtAnyBatchPositionRollsBackExternalWritesAndAllowsRetry(uint8 failurePosition) public {
        failurePosition = uint8(bound(failurePosition, 0, 5));
        UpgradePlan memory old = _currentPlan(6);
        UpgradePlan memory plan = _v2Plan();
        MigrationJournal journal = new MigrationJournal();
        for (uint256 i; i < 6; ++i) {
            plan.calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeAndRecord, (journal, 42));
        }
        plan.calls[failurePosition] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, true));
        vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        _execute(plan);
        _assertImplementations(old);
        assertEq(journal.entries(), 0, "external writes survived failed batch");
        plan.calls[failurePosition] = abi.encodeCall(GovernanceMigrationV2.initializeAndRecord, (journal, 99));
        _execute(plan);
        _assertImplementations(plan);
        assertEq(journal.entries(), 6);
        assertEq(GovernanceMigrationV2(plan.targets[failurePosition]).migrationMarker(), 99);
    }

    function testBatchAuthorityTransfersToRecoveredGovernor() public {
        address next = makeAddr("next-governor");
        _recoverGovernor(next);
        UpgradePlan memory plan = _currentPlan(1);
        plan.implementations[0] = address(new RegistryV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        address[4] memory callers = [address(this), guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            _execute(plan);
        }
        vm.prank(next);
        _execute(plan);
        _assertImplementations(plan);
    }

    function testUninitializedV2MigrationRequiresGovernorOrActiveAnchorBatch() public {
        RegistryV2 next = new RegistryV2();
        registry.upgradeToAndCall(address(next), "");
        GovernanceMigrationV2 migrated = GovernanceMigrationV2(address(registry));
        address[4] memory callers = [guardian, council, makeAddr("outsider"), address(anchor)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(GovernanceMigrationV2.UnauthorizedMigration.selector);
            migrated.initializeV2(42, false);
            assertEq(migrated.migrationMarker(), 0);
        }
        migrated.initializeV2(99, false);
        assertEq(migrated.migrationMarker(), 99);
        assertEq(migrated.migrationCaller(), address(this));
    }

    function testContractGovernorCanUpgradeDirectlyAndExecuteBatch() public {
        GovernorExecutor executor = new GovernorExecutor(address(this));
        _recoverGovernor(address(executor));
        RegistryV2 next = new RegistryV2();
        executor.execute(
            address(registry),
            abi.encodeCall(
                IAnchoredProxyV1.upgradeToAndCall,
                (address(next), abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false)))
            )
        );
        assertEq(GovernanceMigrationV2(address(registry)).migrationCaller(), address(executor));
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[1] = address(new LedgerV2());
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (99, false));
        executor.execute(
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (plan.targets, plan.implementations, plan.calls))
        );
        _assertImplementations(plan);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationCaller(), address(anchor));
    }

    function testNestedBatchFromGovernorCallbackIsRejectedAndOuterBatchRollsBack() public {
        GovernorExecutor executor = new GovernorExecutor(address(this));
        _recoverGovernor(address(executor));
        executor.armCallback(address(ledger));
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        plan.implementations[1] = address(new LedgerV2());
        bytes memory nestedBatch =
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (old.targets, old.implementations, old.calls));
        plan.calls[1] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(executor), abi.encodeCall(GovernorExecutor.execute, (address(anchor), nestedBatch)))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        executor.execute(
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (plan.targets, plan.implementations, plan.calls))
        );
        _assertImplementations(old);
    }

    function testGuardianFreezeDuringMigrationRejectsRemainingUpgradeAndRollsBackEntireTransaction() public {
        GovernorExecutor guardianContract = new GovernorExecutor(address(this));
        bytes32 id = _proposeRecovery(address(this), address(guardianContract), "guardian-contract");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        guardianContract.armCallback(address(registry));
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        bytes memory freeze = abi.encodeCall(TSVGovernanceAnchor.freezeUpgrades, (keccak256("callback-freeze")));
        plan.calls[0] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(guardianContract), abi.encodeCall(GovernorExecutor.execute, (address(anchor), freeze)))
        );
        plan.implementations[1] = address(new LedgerV2());
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        _execute(plan);
        _assertImplementations(old);
        assertFalse(anchor.upgradesFrozen());
        assertEq(anchor.freezeEpoch(), 0);
        assertEq(anchor.freezeId(), bytes32(0));
    }

    function _v2Plan() private returns (UpgradePlan memory plan) {
        plan = _currentPlan(6);
        address[6] memory implementations = UpgradeDeployment.deployV2();
        for (uint256 i; i < 6; ++i) {
            plan.implementations[i] = implementations[i];
            plan.calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        }
    }

    function _recoverGovernor(address next) private {
        bytes32 id = _proposeRecovery(next, guardian, "contract-or-new-governor");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
    }
}

```

### test/unit/v1/governance/StatefulGovernance.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {GovernanceHandler} from "../../../helpers/v1/GovernanceHandler.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";

/// @dev Random interleavings of recovery, freezes and upgrades must agree with the independent model.
contract TSVStatefulGovernanceTest is SixProxyFixture {
    GovernanceHandler internal handler;

    function setUp() public override {
        super.setUp();
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), council);
        address[6] memory originals;
        for (uint256 i; i < 6; ++i) {
            originals[i] = _implementation(businessProxies[i]);
        }
        handler = new GovernanceHandler(anchor, businessProxies, originals, UpgradeDeployment.deployV2());
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = GovernanceHandler.propose.selector;
        selectors[1] = GovernanceHandler.approve.selector;
        selectors[2] = GovernanceHandler.revoke.selector;
        selectors[3] = GovernanceHandler.cancel.selector;
        selectors[4] = GovernanceHandler.recover.selector;
        selectors[5] = GovernanceHandler.freeze.selector;
        selectors[6] = GovernanceHandler.unfreeze.selector;
        selectors[7] = GovernanceHandler.upgradeSingle.selector;
        selectors[8] = GovernanceHandler.upgradeBatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantIdentitiesAndEpochsMatchApprovedRecoveries() public view {
        assertEq(anchor.governor(), handler.modelGovernor());
        assertEq(anchor.guardian(), handler.modelGuardian());
        assertEq(anchor.recoveryCouncil(), council);
        assertEq(anchor.epoch(), handler.modelEpoch());
        assertEq(anchor.guardianEpoch(), handler.modelGuardianEpoch());
    }

    function invariantFreezeOnlyChangesThroughCurrentGuardianTransitions() public view {
        assertEq(anchor.upgradesFrozen(), handler.modelFrozen());
        assertEq(anchor.freezeId(), handler.modelFreezeId());
        assertEq(anchor.freezeEpoch(), handler.modelFreezeEpoch());
    }

    function invariantImplementationsOnlyChangeThroughAuthorizedUnfrozenUpgrades() public view {
        for (uint256 i; i < 6; ++i) {
            assertEq(_implementation(businessProxies[i]), handler.expectedImplementations(i));
        }
        assertFalse(anchor.upgradeContextActive());
    }

    function invariantBindingsAndBusinessRolesSurviveAllGovernanceSequences() public view {
        assertTrue(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), businessProxies[i]);
            assertEq(address(TSVGoverned(businessProxies[i]).governanceAnchor()), address(anchor));
            assertTrue(TSVGoverned(businessProxies[i]).hasRole(bytes32(0), handler.modelGovernor()));
            assertFalse(TSVGoverned(businessProxies[i]).hasRole(bytes32(0), council));
        }
        assertTrue(registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), council));
    }

    /// @dev Guarantees the model exercises successful recovery, stale approval rejection and freeze paths.
    function testModelTraversesRecoveryAndRejectsStaleApprovalWhileFrozen() public {
        handler.propose(2, false);
        handler.propose(2, true);
        handler.approve(1, 0);
        handler.approve(1, 1);
        handler.freeze(1);
        handler.recover(3, 0);
        handler.recover(3, 1);
        handler.upgradeSingle(0, 0);
        handler.upgradeBatch(0, 5);
        assertEq(handler.successfulRecoveries(), 1);
        assertEq(handler.successfulUpgrades(), 0);
        handler.unfreeze(0, false, false);
        handler.unfreeze(1, true, false);
        handler.unfreeze(1, false, false);
        handler.upgradeBatch(0, 5);
        assertEq(handler.successfulUpgrades(), 6);
        invariantIdentitiesAndEpochsMatchApprovedRecoveries();
        invariantFreezeOnlyChangesThroughCurrentGuardianTransitions();
        invariantImplementationsOnlyChangeThroughAuthorizedUnfrozenUpgrades();
        invariantBindingsAndBusinessRolesSurviveAllGovernanceSequences();
    }
}

```

### test/unit/v1/governance/Initialization.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev TSVGovernanceInitializationTest scenarios; inherited fixtures contain no test functions.
contract TSVGovernanceInitializationTest is GovernanceFixture {
    function testGovernanceIdentitiesAreStoredDirectlyInAnchor() public view {
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.recoveryCouncil(), council);
        assertFalse(anchor.upgradesFrozen());
        assertEq(anchor.freezeEpoch(), 0);
    }

    function testProxyInitializationRejectsMissingOrConflictingAnchorGovernor() public {
        address[3] memory governors = [address(0), guardian, council];
        for (uint256 i; i < governors.length; ++i) {
            vm.mockCall(address(anchor), abi.encodeWithSignature("governor()"), abi.encode(governors[i]));
            // Deploy the implementation before setting the expected proxy initialization revert.
            TSVRegistryV1 implementation = new TSVRegistryV1();
            vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
            new TSVERC1967Proxy(address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor))));
            vm.clearMockedCalls();
        }
    }

    function testAnchorConstructorRejectsEveryZeroIdentity() public {
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(0), guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), address(0), council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), guardian, address(0));
    }

    function testAnchorConstructorRejectsEveryPairOfOverlappingIdentities() public {
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(guardian, guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(council, guardian, council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        new TSVGovernanceAnchor(address(this), council, council);
    }

    function testProxyInitializationRejectsAnchorWithoutCode() public {
        TSVRegistryV1 implementation = new TSVRegistryV1();
        vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
        new TSVERC1967Proxy(
            address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (makeAddr("missing-anchor")))
        );
    }

    function testProxyInitializationRejectsInvalidGuardianAndCouncil() public {
        bytes4[2] memory getters = [bytes4(keccak256("guardian()")), bytes4(keccak256("recoveryCouncil()"))];
        address[3] memory invalid = [address(0), address(this), council];
        TSVRegistryV1 implementation = new TSVRegistryV1();
        for (uint256 field; field < getters.length; ++field) {
            for (uint256 i; i < invalid.length; ++i) {
                address value = field == 1 && i == 2 ? guardian : invalid[i];
                vm.mockCall(address(anchor), abi.encodeWithSelector(getters[field]), abi.encode(value));
                vm.expectRevert(TSVGoverned.InvalidGovernance.selector);
                new TSVERC1967Proxy(
                    address(implementation), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                );
                vm.clearMockedCalls();
            }
        }
    }
}

```

### test/unit/v1/governance/Freeze.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {V1RegistryUpgradeMock} from "../../../helpers/v1/DirectUpgradeMock.sol";

/// @dev TSVFreezeTest scenarios; inherited fixtures contain no test functions.
contract TSVFreezeTest is GovernanceFixture {
    function testGuardianFreezeBlocksUpgradeBeforeProxyBindingAndUnfreezeRestoresIt() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        address oldImplementation = proxy.tsvImplementation();
        V1RegistryUpgradeMock next = new V1RegistryUpgradeMock();
        vm.prank(guardian);
        bytes32 id = anchor.freezeUpgrades(keccak256("governor-compromised"));
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), id);
        assertEq(anchor.freezeEpoch(), 1);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (42, false)));
        assertEq(proxy.tsvImplementation(), oldImplementation);
        assertEq(registry.nextPauseId(), 1);
        assertFalse(anchor.proxiesBound());
        vm.prank(guardian);
        anchor.unfreezeUpgrades(id, keccak256("risk-resolved"));
        assertFalse(anchor.upgradesFrozen());
        registry.upgradeToAndCall(address(next), abi.encodeCall(V1RegistryUpgradeMock.initializeV2, (99, false)));
        assertEq(V1RegistryUpgradeMock(address(proxy)).upgradeMarker(), 99);
    }

    function testOnlyCurrentGuardianCanFreezeAndUnfreeze() public {
        address[3] memory callers = [address(this), council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.freezeUpgrades(keccak256("reason"));
        }
        vm.prank(guardian);
        bytes32 id = anchor.freezeUpgrades(keccak256("reason"));
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.unfreezeUpgrades(id, keccak256("evidence"));
            assertTrue(anchor.upgradesFrozen());
        }
    }

    function testFreezeTransitionsRequireEvidenceAndCurrentIncident() public {
        vm.startPrank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.freezeUpgrades(0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(0, keccak256("evidence"));
        bytes32 first = anchor.freezeUpgrades(keccak256("same-reason"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.freezeUpgrades(keccak256("other-reason"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(first, 0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(keccak256("wrong-id"), keccak256("evidence"));
        anchor.unfreezeUpgrades(first, keccak256("evidence"));
        bytes32 second = anchor.freezeUpgrades(keccak256("same-reason"));
        assertNotEq(first, second);
        assertEq(anchor.freezeEpoch(), 2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidFreeze.selector);
        anchor.unfreezeUpgrades(first, keccak256("evidence"));
        assertTrue(anchor.upgradesFrozen());
        anchor.unfreezeUpgrades(second, keccak256("evidence"));
        vm.stopPrank();
    }
}

```

### test/unit/v1/governance/Recovery.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

/// @dev TSVRecoveryTest scenarios; inherited fixtures contain no test functions.
contract TSVRecoveryTest is GovernanceFixture {
    function testGovernorRecoveryPreservesFreezeUntilGuardianExplicitlyUnfreezes() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        TSVRegistryV1 next = new TSVRegistryV1();
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("compromised-governor"));
        address nextGovernor = makeAddr("recovered-governor");
        bytes32 recovery = _proposeRecovery(nextGovernor, guardian, "frozen-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(recovery);
        anchor.executeRecovery(recovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        assertEq(anchor.freezeEpoch(), 1);
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(next), "");
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(guardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(nextGovernor);
        TSVRegistryV1(address(proxy)).upgradeToAndCall(address(next), "");
        assertEq(proxy.tsvImplementation(), address(next));
    }

    function testGuardianRecoveryPreservesFreezeAndTransfersUnfreezeControl() public {
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("incident"));
        address nextGuardian = makeAddr("recovered-guardian");
        bytes32 recovery = _proposeRecovery(address(this), nextGuardian, "guardian-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(recovery);
        anchor.executeRecovery(recovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        vm.prank(nextGuardian);
        anchor.unfreezeUpgrades(freeze, keccak256("evidence"));
        assertFalse(anchor.upgradesFrozen());
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.freezeUpgrades(keccak256("incident"));
        vm.prank(nextGuardian);
        anchor.freezeUpgrades(keccak256("incident"));
    }

    function testRecoveryRequiresCurrentGuardianApprovalAndRevocationIsEffective() public {
        TSVERC1967Proxy proxy = _newRegistryProxy();
        address nextGovernor = makeAddr("next-governor");
        address nextGuardian = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(nextGovernor, nextGuardian, "recovery");
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), nextGovernor);
        assertEq(anchor.guardian(), nextGuardian);
        assertEq(anchor.guardianEpoch(), 1);
        assertEq(anchor.epoch(), 1);
        TSVRegistryV1 registry = TSVRegistryV1(address(proxy));
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, nextGovernor));
        TSVRegistryV1 next = new TSVRegistryV1();
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        registry.upgradeToAndCall(address(next), "");
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(address(next), "");
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testCancelledRecoveryCannotChangeIdentitiesOrFreeze() public {
        vm.prank(guardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("incident"));
        bytes32 id = _proposeRecovery(makeAddr("new-governor"), makeAddr("new-guardian"), "cancelled");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.guardianEpoch(), 0);
        assertEq(anchor.epoch(), 0);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }

    function testRecoveryRotationInvalidatesOtherApprovals() public {
        bytes32 first = _proposeRecovery(address(this), makeAddr("guardian1"), "first");
        bytes32 second = _proposeRecovery(address(this), makeAddr("guardian2"), "second");
        vm.prank(guardian);
        anchor.approveRecovery(first);
        vm.prank(guardian);
        anchor.approveRecovery(second);
        anchor.executeRecovery(first);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(second);
        vm.prank(makeAddr("guardian1"));
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(second);
    }

    function testRecoveryProposalRejectsUnauthorizedOrConflictingIdentities() public {
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.proposeRecovery(makeAddr("new-governor"), guardian, keccak256("salt"), keccak256("evidence"));
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(council, guardian, keccak256("salt"), keccak256("evidence"));
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(guardian, makeAddr("new-guardian"), keccak256("salt"), keccak256("evidence"));
    }

    function testRecoveryCannotBeApprovedByGovernorCouncilOrOutsider() public {
        bytes32 id = _proposeRecovery(makeAddr("new-governor"), guardian, "approval");
        address[3] memory callers = [address(this), council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.approveRecovery(id);
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
            anchor.executeRecovery(id);
        }
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.epoch(), 0);
    }
}

```

### test/unit/v1/governance/FreezeAcrossProxies.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";

import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

contract TSVFreezeAcrossProxiesTest is SixProxyFixture {
    function testGuardianFreezeCoversAllSixProxiesAndBatch() public {
        address[] memory targets = new address[](6);
        address[] memory implementations = new address[](6);
        bytes[] memory initData = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            targets[i] = businessProxies[i];
            implementations[i] = TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation();
        }
        vm.prank(anchor.guardian());
        bytes32 id = anchor.freezeUpgrades(keccak256("governor-risk"));
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
            TSVGoverned(businessProxies[i]).upgradeToAndCall(implementations[i], "");
            assertEq(TSVERC1967Proxy(payable(businessProxies[i])).tsvImplementation(), implementations[i]);
        }
        vm.expectRevert(TSVGovernanceAnchor.UpgradeFrozen.selector);
        anchor.upgradeBatch(targets, implementations, initData);
        assertFalse(anchor.upgradeContextActive());
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(id, keccak256("evidence"));
        vm.prank(anchor.guardian());
        anchor.unfreezeUpgrades(id, keccak256("evidence"));
        // Reopening the global switch restores the complete six-proxy batch entry point.
        anchor.upgradeBatch(targets, implementations, initData);
        assertFalse(anchor.upgradesFrozen());
    }
}

```

### test/unit/v1/governance/ProxyBinding.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Binding is permanent and any failed validation must leave the Anchor unbound.
contract TSVProxyBindingTest is SixProxyFixture {
    function _bindInSetUp() internal pure override returns (bool) {
        return false;
    }

    function testOnlyGovernorCanBindProxies() public {
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.bindProxies(businessProxies);
        }
        _assertUnbound();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testProxiesCannotBeReboundEvenByGovernor() public {
        anchor.bindProxies(businessProxies);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testFuzzBindingRejectsMissingCodeAtAnyPosition(uint8 position, bool zeroAddress) public {
        position = uint8(bound(position, 0, 5));
        address[6] memory invalid = businessProxies;
        invalid[position] = zeroAddress ? address(0) : makeAddr("missing-proxy");
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(invalid);
        _assertUnbound();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testFuzzBindingRejectsDifferentAnchorAtAnyPosition(uint8 position) public {
        position = uint8(bound(position, 0, 5));
        vm.mockCall(
            businessProxies[position],
            abi.encodeWithSignature("governanceAnchor()"),
            abi.encode(makeAddr("other-anchor"))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(businessProxies);
        _assertUnbound();
        vm.clearMockedCalls();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testBindingRejectsDuplicateProxyAndWrongOrder() public {
        address[6] memory invalid = businessProxies;
        invalid[5] = invalid[4];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(invalid);
        _assertUnbound();
        invalid = businessProxies;
        (invalid[1], invalid[2]) = (invalid[2], invalid[1]);
        // The swapped contracts do not expose the required component ABI.
        vm.expectRevert();
        anchor.bindProxies(invalid);
        _assertUnbound();
    }

    function testEveryBrokenCrossLinkRollsBackAndCanBeRetried() public {
        uint8[17] memory owners = [0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 3, 3, 4, 4, 5, 4, 5];
        string[17] memory getters = [
            "hook()",
            "lpManager()",
            "dataInbox()",
            "registry()",
            "hook()",
            "dataInbox()",
            "registry()",
            "ledger()",
            "registry()",
            "ledger()",
            "router()",
            "lpManager()",
            "registry()",
            "ledger()",
            "registry()",
            "poolManager()",
            "poolManager()"
        ];
        for (uint256 i; i < owners.length; ++i) {
            vm.mockCall(
                businessProxies[owners[i]], abi.encodeWithSignature(getters[i]), abi.encode(makeAddr("wrong-link"))
            );
            vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
            anchor.bindProxies(businessProxies);
            _assertUnbound();
            vm.clearMockedCalls();
        }
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testBatchCannotRunBeforeBinding() public {
        UpgradePlan memory plan = _currentPlan(1);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(plan);
    }

    function _assertUnbound() private view {
        assertFalse(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), address(0), "partial binding survived revert");
        }
    }

    function _assertBound() private view {
        assertTrue(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), businessProxies[i]);
        }
    }
}

```

### test/unit/v1/governance/BusinessRoles.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {GovernedRoleHarness} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev TSVBusinessRolesTest scenarios; inherited fixtures contain no test functions.
contract TSVBusinessRolesTest is FoundationFixture {
    /// @dev Verifies business Governor recovery updates the dynamically resolved admin.
    function testBusinessGovernorRecoveryChangesDynamicAdmin() public {
        address next = makeAddr("new-governor");
        assertTrue(registry.hasRole(0, address(this)));
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, keccak256("foundation-recovery"), keccak256("recovery"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertFalse(registry.hasRole(0, address(this)));
        assertTrue(registry.hasRole(0, next));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
    }

    function testDefaultAdminCannotBeGranted() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.grantRole(bytes32(0), council);
        assertFalse(registry.hasRole(bytes32(0), council));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
    }

    function testDefaultAdminCannotBeRevoked() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.revokeRole(bytes32(0), address(this));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
    }

    function testDefaultAdminCannotBeRenounced() public {
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        registry.renounceRole(bytes32(0), address(this));
        assertTrue(registry.hasRole(bytes32(0), address(this)));
        assertFalse(registry.hasRole(bytes32(0), address(0)));
    }

    function testInternalRolePathsAlsoProtectDefaultAdmin() public {
        GovernedRoleHarness implementation = new GovernedRoleHarness();
        GovernedRoleHarness harness = GovernedRoleHarness(
            address(
                new TSVERC1967Proxy(
                    address(implementation), abi.encodeCall(GovernedRoleHarness.initialize, (address(anchor)))
                )
            )
        );
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        harness.internalGrant(bytes32(0), council);
        vm.expectRevert(TSVGoverned.ProtectedRole.selector);
        harness.internalRevoke(bytes32(0), address(this));
        bytes32 role = keccak256("TEST_BUSINESS_ROLE");
        harness.internalGrant(role, council);
        assertTrue(harness.hasRole(role, council));
        harness.internalRevoke(role, council);
        assertFalse(harness.hasRole(role, council));
    }

    function testBusinessRolesCanBeGrantedRevokedAndRenounced() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        assertTrue(registry.hasRole(role, council));
        registry.revokeRole(role, council);
        assertFalse(registry.hasRole(role, council));
        registry.grantRole(role, council);
        vm.prank(council);
        registry.renounceRole(role, council);
        assertFalse(registry.hasRole(role, council));
    }

    function testBusinessRoleRenunciationCannotRemoveSomeoneElse() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        vm.prank(guardian);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        registry.renounceRole(role, council);
        assertTrue(registry.hasRole(role, council));
    }

    function testOnlyGovernorCanGrantOrRevokeBusinessRoles() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        registry.grantRole(role, council);
        for (uint256 i; i < callers.length; ++i) {
            bytes memory errorData = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], bytes32(0)
            );
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.grantRole(role, guardian);
            vm.prank(callers[i]);
            vm.expectRevert(errorData);
            registry.revokeRole(role, council);
        }
        assertFalse(registry.hasRole(role, guardian));
        assertTrue(registry.hasRole(role, council));
    }

    function testRecoveryTransfersRoleManagementAndGovernorConfiguration() public {
        address next = makeAddr("new-governor");
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, council);
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, keccak256("roles"), keccak256("evidence"));
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0));
        vm.expectRevert(denied);
        registry.grantRole(role, guardian);
        vm.expectRevert(denied);
        registry.revokeRole(role, council);
        vm.expectRevert(denied);
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
        vm.startPrank(next);
        registry.grantRole(role, guardian);
        registry.revokeRole(role, council);
        registry.setTierPolicy(2, 25, 1, keccak256("tier2"));
        vm.stopPrank();
        assertTrue(registry.hasRole(role, guardian));
        assertFalse(registry.hasRole(role, council));
        // An explicitly granted business role survives identity recovery independently.
        assertTrue(registry.hasRole(role, address(this)));
    }
}

```

### test/unit/v1/governance/Events.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Observable governance records used by incident tracking and proposal indexing.
contract TSVGovernanceEventsTest is SixProxyFixture {
    function _bindInSetUp() internal pure override returns (bool) {
        return false;
    }

    function testBindingAndBatchEventsIdentifyActualProxiesAndGovernor() public {
        vm.expectEmit(false, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.ProxiesBound(businessProxies);
        anchor.bindProxies(businessProxies);
        UpgradePlan memory plan = _currentPlan(2);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.BatchUpgraded(address(this), 2);
        _execute(plan);
    }

    function testFreezeAndUnfreezeEventsContainIncidentAndEvidence() public {
        bytes32 reason = keccak256("risk");
        bytes32 evidence = keccak256("resolved");
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(anchor), uint64(1), guardian, reason));
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.UpgradesFrozen(expectedId, guardian, reason);
        vm.prank(guardian);
        assertEq(anchor.freezeUpgrades(reason), expectedId);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.UpgradesUnfrozen(expectedId, guardian, evidence);
        vm.prank(guardian);
        anchor.unfreezeUpgrades(expectedId, evidence);
    }

    function testProposalApprovalRevocationAndCancellationEvents() public {
        address next = makeAddr("next-governor");
        bytes32 salt = keccak256("event-salt");
        bytes32 evidence = keccak256("event-evidence");
        bytes32 expectedId =
            keccak256(abi.encode(block.chainid, address(anchor), uint64(0), uint64(0), next, guardian, salt, evidence));
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryProposed(expectedId, next, guardian, evidence);
        vm.prank(council);
        bytes32 id = anchor.proposeRecovery(next, guardian, salt, evidence);
        assertEq(id, expectedId);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryApprovalChanged(id, true);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryApprovalChanged(id, false);
        vm.prank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectEmit(true, false, false, true, address(anchor));
        emit TSVGovernanceAnchor.RecoveryCancelled(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
    }

    function testRecoveryEventsContainOldAndNewIdentitiesAndGuardianEpoch() public {
        address nextGovernor = makeAddr("next-governor");
        address nextGuardian = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(nextGovernor, nextGuardian, "events");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.GuardianSynced(guardian, nextGuardian, 1);
        vm.expectEmit(true, true, false, true, address(anchor));
        emit TSVGovernanceAnchor.AuthoritiesRecovered(address(this), nextGovernor, nextGuardian, keccak256("evidence"));
        anchor.executeRecovery(id);
    }
}

```

### test/unit/v1/governance/BatchUpgrade.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {RegistryV2, LedgerV2, GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Each test starts from a fresh fixture and checks one batch rule.
contract TSVBatchUpgradeTest is SixProxyFixture {
    function testTwoProxyMigrationRollsBackAndCanRetryWithAnchorCaller() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, true));
        vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        _execute(plan);
        _assertImplementations(old);
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (99, false));
        _execute(plan);
        _assertImplementations(plan);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationMarker(), 99);
        assertEq(GovernanceMigrationV2(address(ledger)).migrationCaller(), address(anchor));
        assertEq(registry.nextPauseId(), 1);
        assertEq(address(ledger.registry()), address(registry));
    }

    function testApprovedRecoveryCannotExecuteDuringBatchMigration() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        bytes32 id = _proposeRecovery(address(this), makeAddr("next-guardian"), "batch-recovery");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        plan.calls[1] = abi.encodeCall(
            GovernanceMigrationV2.initializeWithCall,
            (address(anchor), abi.encodeCall(TSVGovernanceAnchor.executeRecovery, (id)))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        _execute(plan);
        _assertImplementations(old);
        assertEq(anchor.epoch(), 0);
        assertEq(anchor.guardian(), guardian);
        (,,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertTrue(approved);
        anchor.executeRecovery(id);
        assertEq(anchor.epoch(), 1);
    }

    function testOnlyGovernorCanStartBatch() public {
        UpgradePlan memory plan = _twoProxyMigration();
        UpgradePlan memory old = _currentPlan(2);
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            _execute(plan);
        }
        _assertImplementations(old);
    }

    function testBatchRejectsDuplicateTarget() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.targets[1] = plan.targets[0];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(old);
    }

    function testBatchRejectsUnboundTarget() public {
        UpgradePlan memory old = _currentPlan(2);
        UpgradePlan memory plan = _twoProxyMigration();
        plan.targets[1] = plan.implementations[1];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(old);
    }

    function testBatchRejectsMismatchedImplementationArrayLength() public {
        UpgradePlan memory old = _currentPlan(2);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.upgradeBatch(old.targets, new address[](1), old.calls);
        _assertImplementations(old);
    }

    function testAnchorCannotUpgradeOutsideActiveBatch() public {
        UpgradePlan memory old = _currentPlan(1);
        RegistryV2 next = new RegistryV2();
        vm.prank(address(anchor));
        vm.expectRevert(TSVGoverned.UnauthorizedUpgrade.selector);
        registry.upgradeToAndCall(address(next), "");
        _assertImplementations(old);
    }

    function _twoProxyMigration() private returns (UpgradePlan memory plan) {
        plan = _currentPlan(2);
        plan.implementations[0] = address(new RegistryV2());
        plan.implementations[1] = address(new LedgerV2());
        plan.calls[0] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
        plan.calls[1] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, false));
    }
}

```

### test/unit/v1/governance/RecoveryLifecycle.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Invalid inputs, competing proposals and authority changes around recovery.
contract TSVRecoveryLifecycleTest is GovernanceFixture {
    bytes32 internal constant EVIDENCE = keccak256("recovery-evidence");
    bytes32 internal constant SALT = keccak256("recovery-salt");

    function testProposalRequiresNonzeroSaltAndEvidence() public {
        address next = makeAddr("next-governor");
        vm.startPrank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.proposeRecovery(next, guardian, bytes32(0), EVIDENCE);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.proposeRecovery(next, guardian, SALT, bytes32(0));
        vm.stopPrank();
        assertEq(anchor.epoch(), 0);
    }

    function testRecoveryRejectsZeroAndEqualIdentities() public {
        _rejectIdentities(address(0), guardian);
        _rejectIdentities(makeAddr("next-governor"), address(0));
        _rejectIdentities(makeAddr("same-identity"), makeAddr("same-identity"));
    }

    function testRecoveryCannotAssignCouncilToEitherOtherRole() public {
        _rejectIdentities(council, guardian);
        _rejectIdentities(makeAddr("next-governor"), council);
    }

    function testRecoveryCannotSwapExistingGovernorAndGuardianRoles() public {
        _rejectIdentities(guardian, makeAddr("next-guardian"));
        _rejectIdentities(makeAddr("next-governor"), address(this));
    }

    function testRecoveryMustChangeAtLeastOneIdentity() public {
        _rejectIdentities(address(this), guardian);
    }

    function testOnlyCouncilCanProposeAndCancel() public {
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), guardian, "pending");
        address[3] memory callers = [address(this), guardian, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.proposeRecovery(makeAddr("another-governor"), guardian, SALT, EVIDENCE);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.cancelRecovery(id);
            vm.stopPrank();
        }
        (,,,,, bool active,) = anchor.recoveries(id);
        assertTrue(active);
    }

    function testUnknownProposalCannotBeApprovedRevokedCancelledOrExecuted() public {
        bytes32 id = keccak256("unknown");
        vm.startPrank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        vm.stopPrank();
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testActiveDuplicateProposalIsRejectedWithoutLosingApproval() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "duplicate");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.proposeRecovery(next, guardian, keccak256("duplicate"), keccak256("evidence"));
        (,,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertTrue(approved);
    }

    function testReproposingCancelledProposalRequiresFreshGuardianApproval() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "reused-salt");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        assertEq(_proposeRecovery(next, guardian, "reused-salt"), id);
        (,,,,, bool active, bool approved) = anchor.recoveries(id);
        assertTrue(active);
        assertFalse(approved);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.prank(guardian);
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        assertEq(anchor.governor(), next);
    }

    function testGovernorOnlyRecoveryInvalidatesCompetingApproval() public {
        bytes32 first = _proposeRecovery(makeAddr("governor-one"), guardian, "first");
        bytes32 second = _proposeRecovery(makeAddr("governor-two"), guardian, "second");
        vm.startPrank(guardian);
        anchor.approveRecovery(first);
        anchor.approveRecovery(second);
        vm.stopPrank();
        anchor.executeRecovery(first);
        assertEq(anchor.epoch(), 1);
        assertEq(anchor.guardianEpoch(), 0);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(second);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(second);
    }

    function testGuardianCandidateCannotApproveItsOwnRecovery() public {
        address next = makeAddr("next-guardian");
        bytes32 id = _proposeRecovery(address(this), next, "guardian");
        vm.prank(next);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.approveRecovery(id);
        (,,,,,, bool approved) = anchor.recoveries(id);
        assertFalse(approved);
    }

    function testOldGuardianCannotApproveOrRevokeNewProposal() public {
        address next = makeAddr("next-guardian");
        bytes32 rotate = _proposeRecovery(address(this), next, "rotate");
        vm.prank(guardian);
        anchor.approveRecovery(rotate);
        anchor.executeRecovery(rotate);
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), next, "new-proposal");
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.approveRecovery(id);
        vm.prank(next);
        anchor.approveRecovery(id);
        vm.prank(guardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        (,,,,,, bool approved) = anchor.recoveries(id);
        assertTrue(approved);
    }

    function testAnyoneCanExecuteApprovedRecoveryButItCannotBeReplayed() public {
        address next = makeAddr("next-governor");
        bytes32 id = _proposeRecovery(next, guardian, "permissionless-execution");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.startPrank(makeAddr("executor"));
        anchor.executeRecovery(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
        vm.stopPrank();
        assertEq(anchor.governor(), next);
        (,,,,, bool active, bool approved) = anchor.recoveries(id);
        assertFalse(active);
        assertFalse(approved);
    }

    function testCancelledApprovalCanBeCleanedUpWithoutReactivatingProposal() public {
        bytes32 id = _proposeRecovery(makeAddr("next-governor"), guardian, "cancel");
        vm.prank(guardian);
        anchor.approveRecovery(id);
        vm.prank(council);
        anchor.cancelRecovery(id);
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.cancelRecovery(id);
        vm.startPrank(guardian);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.revokeRecoveryApproval(id);
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.approveRecovery(id);
        vm.stopPrank();
        vm.expectRevert(TSVGovernanceAnchor.InvalidProposal.selector);
        anchor.executeRecovery(id);
    }

    function testProposalIdsAreSeparatedByAnchorAndChain() public {
        address next = makeAddr("next-governor");
        bytes32 first = _proposeRecovery(next, guardian, "domain");
        TSVGovernanceAnchor other = new TSVGovernanceAnchor(address(this), guardian, council);
        vm.prank(council);
        bytes32 differentAnchor = other.proposeRecovery(next, guardian, keccak256("domain"), keccak256("evidence"));
        vm.chainId(block.chainid + 1);
        bytes32 differentChain = _proposeRecovery(next, guardian, "domain");
        assertNotEq(first, differentAnchor);
        assertNotEq(first, differentChain);
    }

    function _rejectIdentities(address nextGovernor, address nextGuardian) private {
        vm.prank(council);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.proposeRecovery(nextGovernor, nextGuardian, SALT, EVIDENCE);
        assertEq(anchor.governor(), address(this));
        assertEq(anchor.guardian(), guardian);
        assertEq(anchor.epoch(), 0);
    }
}

```

### test/unit/v1/governance/DeploymentChecks.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {DeployGovernanceV1} from "../../../../script/DeployGovernanceV1.s.sol";
import {DeployCoreV1} from "../../../../script/DeployCoreV1.s.sol";
import {VerifyDeploymentV1} from "../../../../script/VerifyDeploymentV1.s.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @dev Per-instance inputs avoid process-global environment races between parallel tests.
abstract contract ScriptInputStore {
    mapping(string => string) private inputs;

    function setInput(string memory name, string memory value) external {
        inputs[name] = value;
    }

    function _input(string memory name) internal view returns (string memory) {
        return inputs[name];
    }
}

contract DeployCoreValidationHarness is DeployCoreV1, ScriptInputStore {
    function checkEnvironment() external view {
        _checkInput(_loadInput());
    }

    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

contract VerifyDeploymentHarness is VerifyDeploymentV1, ScriptInputStore {
    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

contract GovernanceDeploymentHarness is DeployGovernanceV1, ScriptInputStore {
    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

/// @dev Actual deployment validators and manifest verification against the local protocol fixture.
contract TSVDeploymentChecksTest is ProtocolFixture {
    DeployCoreValidationHarness internal coreValidator;
    VerifyDeploymentHarness internal verifier;

    function setUp() public override {
        super.setUp();
        coreValidator = new DeployCoreValidationHarness();
        verifier = new VerifyDeploymentHarness();
        _setEnvironment();
    }

    function testCoreDeploymentAcceptsValidUnboundEnvironment() public view {
        coreValidator.checkEnvironment();
    }

    function testCoreDeploymentRejectsWrongChain() public {
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsAlreadyBoundAnchor() public {
        anchor.bindProxies(_proxies());
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsMissingExternalCode() public {
        _setInput("TSV_POOL_MANAGER", vm.toString(makeAddr("missing-pool-manager")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_SBT", vm.toString(makeAddr("missing-sbt")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_GOVERNANCE_ANCHOR", vm.toString(makeAddr("missing-anchor")));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsWrongExternalCodeHashes() public {
        _setInput("TSV_POOL_MANAGER_CODEHASH", vm.toString(keccak256("wrong-manager-code")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_SBT_CODEHASH", vm.toString(keccak256("wrong-sbt-code")));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsEveryMismatchedGovernanceIdentity() public {
        string[3] memory names = ["TSV_GOVERNOR", "TSV_GUARDIAN", "TSV_RECOVERY_COUNCIL"];
        for (uint256 i; i < names.length; ++i) {
            _setInput(names[i], vm.toString(makeAddr("unexpected-identity")));
            _expectInvalidCoreInput();
            _setEnvironment();
        }
    }

    function testCoreDeploymentRejectsFailingSbtSelectors() public {
        sbt.setFailReads(false, true);
        _expectInvalidCoreInput();
        sbt.setFailReads(true, false);
        _expectInvalidCoreInput();
    }

    function testFuzzCoreDeploymentRejectsOffsetOutsideOneDay(uint64 offset) public {
        _setInput("TSV_DAY_START_OFFSET_SECONDS", vm.toString(bound(offset, 86_400, type(uint64).max)));
        _expectInvalidCoreInput();
    }

    function testGovernanceDeploymentRejectsWrongChainBeforeBroadcast() public {
        GovernanceDeploymentHarness deployer = new GovernanceDeploymentHarness();
        deployer.setInput("TSV_GOVERNOR", vm.toString(anchor.governor()));
        deployer.setInput("TSV_GUARDIAN", vm.toString(anchor.guardian()));
        deployer.setInput("TSV_RECOVERY_COUNCIL", vm.toString(anchor.recoveryCouncil()));
        // Zero is intentionally invalid and unused: the chain guard runs before broadcasting.
        deployer.setInput("TSV_DEPLOYER_PRIVATE_KEY", "0");
        deployer.setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert(DeployGovernanceV1.InvalidDeploymentInput.selector);
        deployer.run();
    }

    function testVerifierAcceptsCorrectBoundDeployment() public {
        anchor.bindProxies(_proxies());
        verifier.run();
    }

    function testVerifierRejectsUnboundAnchor() public {
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testVerifierRejectsWrongChainAndProxyOrder() public {
        anchor.bindProxies(_proxies());
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
        _setEnvironment();
        _setInput("TSV_REGISTRY", vm.toString(address(ledger)));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testFuzzVerifierRejectsWrongImplementationAtAnyProxy(uint8 index) public {
        index = uint8(bound(index, 0, 5));
        anchor.bindProxies(_proxies());
        _setInput(string.concat(_proxyEnvName(index), "_IMPLEMENTATION"), vm.toString(makeAddr("wrong-implementation")));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testFuzzVerifierRejectsWrongImplementationCodeHashAtAnyProxy(uint8 index) public {
        index = uint8(bound(index, 0, 5));
        anchor.bindProxies(_proxies());
        _setInput(
            string.concat(_proxyEnvName(index), "_IMPLEMENTATION_CODEHASH"), vm.toString(keccak256("wrong-code-hash"))
        );
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testVerifierRejectsStaleIdentityManifestAfterRecovery() public {
        anchor.bindProxies(_proxies());
        address next = makeAddr("next-governor");
        address currentGuardian = anchor.guardian();
        vm.prank(anchor.recoveryCouncil());
        bytes32 id = anchor.proposeRecovery(next, currentGuardian, keccak256("manifest"), keccak256("evidence"));
        vm.prank(anchor.guardian());
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
        _setInput("TSV_GOVERNOR", vm.toString(next));
        verifier.run();
    }

    function _expectInvalidCoreInput() private {
        vm.expectRevert(DeployCoreV1.InvalidDeploymentInput.selector);
        coreValidator.checkEnvironment();
    }

    function _setInput(string memory name, string memory value) private {
        coreValidator.setInput(name, value);
        verifier.setInput(name, value);
    }

    function _setEnvironment() private {
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid));
        _setInput("TSV_GOVERNANCE_ANCHOR", vm.toString(address(anchor)));
        _setInput("TSV_GOVERNOR", vm.toString(anchor.governor()));
        _setInput("TSV_GUARDIAN", vm.toString(anchor.guardian()));
        _setInput("TSV_RECOVERY_COUNCIL", vm.toString(anchor.recoveryCouncil()));
        _setInput("TSV_POOL_MANAGER", vm.toString(address(manager)));
        _setInput("TSV_POOL_MANAGER_CODEHASH", vm.toString(address(manager).codehash));
        _setInput("TSV_SBT", vm.toString(address(sbt)));
        _setInput("TSV_SBT_CODEHASH", vm.toString(address(sbt).codehash));
        _setInput("TSV_SBT_TOKEN_ID", "1");
        _setInput("TSV_DAY_START_OFFSET_SECONDS", "14400");
        address[6] memory proxies = _proxies();
        for (uint256 i; i < 6; ++i) {
            address implementation = TSVERC1967Proxy(payable(proxies[i])).tsvImplementation();
            string memory name = _proxyEnvName(i);
            _setInput(name, vm.toString(proxies[i]));
            _setInput(string.concat(name, "_IMPLEMENTATION"), vm.toString(implementation));
            _setInput(string.concat(name, "_IMPLEMENTATION_CODEHASH"), vm.toString(implementation.codehash));
        }
    }

    function _proxies() private view returns (address[6] memory) {
        return [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lpManager)];
    }

    function _proxyEnvName(uint256 index) private pure returns (string memory) {
        string[6] memory names =
            ["TSV_REGISTRY", "TSV_VOLUME_LEDGER", "TSV_DATA_INBOX", "TSV_HOOK", "TSV_SWAP_ROUTER", "TSV_LP_MANAGER"];
        return names[index];
    }
}

```

### test/unit/v1/registry/Admission.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken, V1SnapshotOnlyAdapterMock} from "../../../helpers/v1/FoundationMocks.sol";

/// @dev TSVAdmissionTest scenarios; inherited fixtures contain no test functions.
contract TSVAdmissionTest is FoundationFixture {
    /// @dev Verifies the Registry rejects the same security on both pool legs.
    function testRegistryRejectsSameSecurityBothSides() public {
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped secondStock = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(secondStock), 1);
        registry.registerToken(_config(address(secondStock), SECURITY, address(secondAdapter)), keccak256("second"));
        address a = address(stock) < address(secondStock) ? address(stock) : address(secondStock);
        address b = address(stock) < address(secondStock) ? address(secondStock) : address(stock);
        PoolKey memory bad = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(bad);
    }

    /// @dev Verifies the Registry accepts a direct adapter and stores its policy metadata.
    function testRegistryAcceptsDirectAdapterAndStoresPolicyMetadata() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(otherUnderlying), address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        registry.registerToken(config, keccak256("wrong-ratio"));
        TokenConfig memory stored = registry.getToken(address(other));
        assertEq(stored.securityId, SECURITY);
        assertEq(stored.legalShareAdapter, address(adapter));
        assertEq(stored.legalSharePolicyHash, config.legalSharePolicyHash);
        TokenConfig memory quoteConfig = registry.getToken(address(quote));
        assertEq(quoteConfig.securityId, bytes32(0));
        assertEq(quoteConfig.legalShareAdapter, address(0));
        assertEq(uint8(stored.status), uint8(TokenStatus.APPROVED));
        assertEq(registry.tierPolicy(1).listedCount, 1);
    }

    function testAdmissionAtomicallyListsApprovesAndDefaultsToOpen() public {
        bytes32 securityId = keccak256("new-security");
        bytes32 symbolHash = keccak256("new-symbol");
        bytes32 evidenceHash = keccak256("admission-evidence");
        TokenConfig memory config = _newStockConfig(securityId);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityListed(securityId, symbolHash, 1, evidenceHash);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.TokenRegistered(config.poolCurrency, securityId, evidenceHash);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.TokenStatusChanged(
            config.poolCurrency, uint8(TokenStatus.ABSENT), uint8(TokenStatus.APPROVED), evidenceHash
        );
        registry.admitSecurity(securityId, symbolHash, 1, config, evidenceHash);
        assertEq(keccak256(abi.encode(registry.getToken(config.poolCurrency))), keccak256(abi.encode(config)));
        assertTrue(registry.getSecurity(securityId).listed);
        assertEq(registry.getSecurity(securityId).symbolHash, symbolHash);
        assertEq(registry.getSecurity(securityId).version, 1);
        assertEq(registry.getSecurity(securityId).activePoolCount, 0);
        assertEq(registry.tierPolicy(1).listedCount, 2);
        assertEq(uint8(registry.marketStatus(securityId)), uint8(MarketStatus.OPEN));
        assertEq(uint8(registry.marketPauseMode(securityId)), uint8(PauseMode.NONE));
        assertEq(registry.marketSequence(securityId), 0);
        _assertOperationGates(true, true);
    }

    /// @dev Rejected admissions must release the symbol, Tier slot, and all partial records.
    function testFuzzAdmissionValidationFailureRollsBackAllRecords(uint8 scenario) public {
        scenario = uint8(bound(scenario, 0, 15));
        bytes32 securityId = keccak256("failed-security");
        bytes32 symbolHash = keccak256("failed-symbol");
        bytes32 evidenceHash = keccak256("evidence");
        uint8 tierId = 1;
        TokenConfig memory good = _newStockConfig(securityId);
        TokenConfig memory config = abi.decode(abi.encode(good), (TokenConfig));
        if (scenario == 0) {
            config.status = TokenStatus.ABSENT;
        } else if (scenario == 1) {
            config.status = TokenStatus.DISABLED;
        } else if (scenario == 2) {
            config.reviewHash = 0;
        } else if (scenario == 3) {
            config.legalSharePolicyHash = 0;
        } else if (scenario == 4) {
            config.poolRuntimeCodeHash = keccak256("wrong-code");
        } else if (scenario == 5) {
            config.poolDecimals = 6;
        } else if (scenario == 6) {
            config.legalAdapterVersion = 2;
        } else if (scenario == 7) {
            config.legalShareAdapter = address(stockAdapter);
            config.legalAdapterCodeHash = address(stockAdapter).codehash;
        } else if (scenario == 8) {
            config.legalShareAdapter = address(0);
        } else if (scenario == 9) {
            config.legalAdapterCodeHash = keccak256("wrong-adapter-code");
        } else if (scenario == 10) {
            config.securityId = SECURITY;
        } else if (scenario == 11) {
            config.poolCurrency = address(stock);
        } else if (scenario == 12) {
            tierId = 2;
        } else if (scenario == 13) {
            evidenceHash = 0;
        } else if (scenario == 14) {
            config.poolCurrency = address(0);
        } else {
            config.poolDecimals = 19;
        }
        bytes32 tokenBefore = keccak256(abi.encode(registry.getToken(config.poolCurrency)));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(securityId, symbolHash, tierId, config, evidenceHash);
        assertEq(registry.getSecurity(securityId).securityId, bytes32(0));
        assertEq(keccak256(abi.encode(registry.getToken(config.poolCurrency))), tokenBefore);
        assertEq(uint8(registry.getToken(good.poolCurrency).status), uint8(TokenStatus.ABSENT));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.marketSequence(securityId), 0);
        // The same symbol and security can be admitted after correcting the rejected input.
        registry.admitSecurity(securityId, symbolHash, 1, good, keccak256("corrected-evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testAdmissionRejectsDuplicateSecurityAndSymbolAndFullTier() public {
        bytes32 newSecurity = keccak256("duplicate-test");
        TokenConfig memory config = _newStockConfig(newSecurity);
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(SECURITY, keccak256("unused"), 1, config, keccak256("evidence"));
        config.securityId = newSecurity;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(newSecurity, keccak256("STDx"), 1, config, keccak256("evidence"));
        registry.setTierPolicy(1, 25, 1, keccak256("capacity"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(newSecurity, keccak256("unused"), 1, config, keccak256("evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(newSecurity).securityId, bytes32(0));
        assertEq(uint8(registry.getToken(config.poolCurrency).status), uint8(TokenStatus.ABSENT));
        registry.setTierPolicy(1, 25, 10, keccak256("capacity-restored"));
        registry.admitSecurity(newSecurity, keccak256("unused"), 1, config, keccak256("evidence"));
    }

    function testAdmissionAndRegistrationRequireSymbolAdmin() public {
        bytes32 securityId = keccak256("unauthorized-security");
        TokenConfig memory config = _newStockConfig(securityId);
        address stranger = makeAddr("admission-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.admitSecurity(securityId, keccak256("symbol"), 1, config, keccak256("evidence"));
        V1MockToken otherQuote = new V1MockToken("OTHER_QUOTE", 6);
        config = _config(address(otherQuote), 0, address(0));
        vm.expectRevert();
        vm.prank(stranger);
        registry.registerToken(config, keccak256("evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(securityId).securityId, bytes32(0));
    }

    function testQuoteRegistrationApprovesOnceAndRequiresReview() public {
        V1MockToken otherQuote = new V1MockToken("OTHER_QUOTE", 6);
        TokenConfig memory config = _config(address(otherQuote), 0, address(0));
        config.reviewHash = 0;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("evidence"));
        config.reviewHash = keccak256("quote-review");
        registry.registerToken(config, keccak256("evidence"));
        assertEq(uint8(registry.getToken(address(otherQuote)).status), uint8(TokenStatus.APPROVED));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("duplicate"));
    }

    function testUnknownAssetsStayAbsentAndCannotCreatePools() public {
        V1MockToken unknown = new V1MockToken("UNKNOWN", 6);
        assertEq(uint8(registry.getToken(address(unknown)).status), uint8(TokenStatus.ABSENT));
        address a = address(unknown) < address(quote) ? address(unknown) : address(quote);
        address b = address(unknown) < address(quote) ? address(quote) : address(unknown);
        PoolKey memory unknownKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(unknownKey);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(unknown), TokenStatus.APPROVED, keccak256("evidence"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.marketStatus(keccak256("unknown-security"));
        TokenConfig memory config = _newStockConfig(keccak256("unknown-security"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("evidence"));
    }

    function testTokenDisableAndReenablePreserveApprovalChecks() public {
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("noop"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.ABSENT, keccak256("absent"));
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable"));
        _assertOperationGates(false, false);
        bytes memory code = address(stock).code;
        vm.etch(address(stock), hex"00");
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("changed-code"));
        assertEq(uint8(registry.getToken(address(stock)).status), uint8(TokenStatus.DISABLED));
        vm.etch(address(stock), code);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("reenable"));
        _assertOperationGates(true, true);
    }

    /// @dev Verifies the Registry rejects an adapter without the direct-conversion interface.
    function testRegistryRejectsAdapterWithoutDirectInterface() public {
        V1MockToken other = new V1MockToken("Other", 18);
        V1SnapshotOnlyAdapterMock adapter = new V1SnapshotOnlyAdapterMock(address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("adapter-rate"));
    }

    /// @dev Verifies the Registry rejects a direct adapter bound to another Currency.
    function testRegistryRejectsDirectAdapterBoundToDifferentCurrency() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));

        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("wrong-currency"));
    }

    /// @dev Verifies a disabled pool is re-enabled only after market and asset checks pass.
    function testDisabledPoolOnlyReenablesAfterMarketAndAssetChecks() public {
        registry.disablePool(poolId, keccak256("disable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
        _submitMarket(MarketAction.HALT, 1, keccak256("halt"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarket(MarketAction.RESUME, 2, keccak256("resume"));
        registry.enablePool(poolId, keccak256("enable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        assertTrue(registry.isTradable(poolId));
    }

    /// @dev Verifies the Registry rejects different stock securities in the same pool.
    function testRegistryRejectsDifferentSecurityStocksInSamePool() public {
        bytes32 secondSecurity = keccak256("SEC_B");
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped second = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(second), 1);
        registry.admitSecurity(
            secondSecurity,
            keccak256("STDy"),
            1,
            _config(address(second), secondSecurity, address(secondAdapter)),
            keccak256("register-b")
        );
        address a = address(stock) < address(second) ? address(stock) : address(second);
        address b = address(stock) < address(second) ? address(second) : address(stock);
        PoolKey memory twoStocks = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(twoStocks);
    }
}

```

### test/unit/v1/registry/Permissions.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TokenConfig, TokenStatus, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";
import {OperationsSbt} from "../../../helpers/v1/OperationsMocks.sol";

contract TSVOperationsPermissionsTest is OperationsFixture {
    function testEverySymbolAdminEntryRejectsUnassignedAndRevokedRoleIncludingGovernor() public {
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        address operator = makeAddr("symbol-operator");
        TokenConfig memory config = _newStockConfig(keccak256("new-security"));
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(
            TSVRegistryV1.admitSecurity, (config.securityId, keccak256("symbol"), 1, config, keccak256("evidence"))
        );
        calls[1] = abi.encodeCall(TSVRegistryV1.registerToken, (config, keccak256("evidence")));
        calls[2] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY, keccak256("evidence")));
        calls[3] = abi.encodeCall(TSVRegistryV1.delistSecurity, (SECURITY, keccak256("evidence")));
        calls[4] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 2, keccak256("evidence")));
        calls[5] =
            abi.encodeCall(TSVRegistryV1.setTokenStatus, (address(stock), TokenStatus.DISABLED, keccak256("evidence")));
        calls[6] = abi.encodeCall(
            TSVRegistryV1.replaceLegalShareAdapter, (address(stock), address(stockAdapter), keccak256("evidence"))
        );
        calls[7] = abi.encodeCall(TSVRegistryV1.disablePool, (poolId, keccak256("evidence")));
        calls[8] = abi.encodeCall(TSVRegistryV1.enablePool, (poolId, keccak256("evidence")));
        bytes32 beforeState = _state();
        _denyCalls(calls, operator, role);
        registry.grantRole(role, operator);
        vm.prank(operator);
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("operator-success"));
        vm.prank(operator);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("operator-success"));
        registry.revokeRole(role, operator);
        _denyCalls(calls, operator, role);
        registry.revokeRole(role, address(this));
        _denyCalls(calls, address(this), role);
        assertEq(_state(), beforeState);
    }

    function testPauserAndResumerCannotActForEachOtherAndRevocationTakesEffect() public {
        address pauser = makeAddr("pause-only");
        address resumer = makeAddr("resume-only");
        bytes32 pauseRole = registry.EMERGENCY_PAUSER_ROLE();
        bytes32 resumeRole = registry.EMERGENCY_RESUMER_ROLE();
        registry.grantRole(pauseRole, pauser);
        registry.grantRole(resumeRole, resumer);
        vm.expectRevert(_denied(resumer, pauseRole));
        vm.prank(resumer);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"), keccak256("source"));
        vm.prank(pauser);
        uint256 id =
            registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"), keccak256("source"));
        vm.expectRevert(_denied(pauser, resumeRole));
        vm.prank(pauser);
        registry.clearEmergencyPause(id, keccak256("resume"));
        registry.revokeRole(resumeRole, resumer);
        vm.expectRevert(_denied(resumer, resumeRole));
        vm.prank(resumer);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(false, false);
        registry.grantRole(resumeRole, resumer);
        vm.prank(resumer);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        registry.revokeRole(pauseRole, pauser);
        vm.expectRevert(_denied(pauser, pauseRole));
        vm.prank(pauser);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("incident"), keccak256("source"));
        assertEq(registry.nextPauseId(), 2);
    }

    function testBusinessOperatorsCannotChangeGovernorConfigurationOrDaySchedule() public {
        address operator = makeAddr("business-only");
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), operator);
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), operator);
        OperationsSbt sbt = new OperationsSbt();
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        registry.setTierPolicy(2, 10, 1, keccak256("tier"));
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        registry.setSbtConfig(address(sbt), 1, keccak256("sbt"));
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        ledger.scheduleDayStart(18000, 20261004, keccak256("schedule"));
        ledger.scheduleDayStart(18000, 20261004, keccak256("valid"));
        vm.expectRevert(_denied(operator, 0));
        vm.prank(operator);
        ledger.cancelPendingDayStart(keccak256("cancel"));
        assertEq(ledger.dayStartCheckpointCount(), 1);
        assertEq(registry.tierPolicy(2).tierBps, 0);
        assertEq(address(registry.participantSbt()), address(0));
    }

    function testPoolIntercontractEntriesRequireBoundLpManager() public {
        bytes32 beforeState = _state();
        address stranger = makeAddr("not-lp-manager");
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        vm.prank(stranger);
        registry.registerPendingPool(key);
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        vm.prank(stranger);
        registry.markPoolActive(poolId, uint160(1 << 96), stranger, keccak256("price"));
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        vm.prank(stranger);
        _charge(1e18);
        assertEq(_state(), beforeState);
    }

    function _denyCalls(bytes[] memory calls, address caller, bytes32 role) private {
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(_denied(caller, role));
            vm.prank(caller);
            (bool ok, bytes memory result) = address(registry).call(calls[i]);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _denied(address caller, bytes32 role) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.getToken(address(stock)),
                registry.getPool(poolId),
                registry.tierPolicy(1),
                ledger.used(SECURITY, DAY),
                registry.nextPauseId()
            )
        );
    }
}

```

### test/unit/v1/registry/Configuration.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {OperationsSbt, OperationsPausedOnlySbt, OperationsVerifyOnlySbt} from "../../../helpers/v1/OperationsMocks.sol";

contract TSVOperationsConfigurationTest is FoundationFixture {
    function testTierPolicyBoundsCapacityAndEvents() public {
        bytes32 beforeState = keccak256(abi.encode(registry.tierPolicy(1)));
        uint16[3] memory badBps = [uint16(0), 10001, type(uint16).max];
        for (uint256 i; i < badBps.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.setTierPolicy(1, badBps[i], 10, keccak256("invalid-bps"));
            assertEq(keccak256(abi.encode(registry.tierPolicy(1))), beforeState);
        }
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(0, 25, 10, keccak256("zero-tier"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 25, 0, keccak256("below-count"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 25, 10, 0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.TierPolicyChanged(1, 1, 1, keccak256("minimum"));
        registry.setTierPolicy(1, 1, 1, keccak256("minimum"));
        registry.setTierPolicy(1, 10000, 1, keccak256("maximum"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.tierPolicy(1).tierBps, 10000);
        registry.setTierPolicy(2, 25, 0, keccak256("closed-empty-tier"));
        assertEq(registry.tierPolicy(2).maxListed, 0);
    }

    function testSbtMustBeConfiguredAndCredentialIsSeparateFromEligibility() public {
        address owner = makeAddr("credential-owner");
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        registry.hasCredential(owner);
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        registry.isEligible(owner);
        OperationsSbt credential = new OperationsSbt();
        credential.setCredential(owner, 7, true);
        registry.setSbtConfig(address(credential), 7, keccak256("credential"));
        assertTrue(registry.hasCredential(owner));
        assertTrue(registry.isEligible(owner));
        assertFalse(registry.hasCredential(makeAddr("nonholder")));
        credential.setPaused(true);
        assertTrue(registry.hasCredential(owner));
        assertFalse(registry.isEligible(owner));
        credential.setPaused(false);
        registry.setSbtConfig(address(credential), 8, keccak256("new-id"));
        assertFalse(registry.hasCredential(owner));
        credential.setCredential(owner, 8, true);
        assertTrue(registry.isEligible(owner));
    }

    function testEveryInvalidSbtConfigurationPreservesPreviousConfiguration() public {
        OperationsSbt good = new OperationsSbt();
        registry.setSbtConfig(address(good), 7, keccak256("good"));
        address[5] memory bad = [
            address(0),
            makeAddr("no-code-sbt"),
            address(quote),
            address(new OperationsPausedOnlySbt()),
            address(new OperationsVerifyOnlySbt())
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.setSbtConfig(bad[i], 8, keccak256("bad"));
            assertEq(address(registry.participantSbt()), address(good));
            assertEq(registry.sbtTokenId(), 7);
        }
        OperationsSbt fails = new OperationsSbt();
        fails.setFailVerify(true);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(fails), 8, keccak256("reverting-verify"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(good), 8, 0);
        assertEq(address(registry.participantSbt()), address(good));
        assertEq(registry.sbtTokenId(), 7);
    }

    function testSbtReplacementEventAndMalformedReadsAreAtomic() public {
        OperationsSbt old = new OperationsSbt();
        OperationsSbt next = new OperationsSbt();
        registry.setSbtConfig(address(old), 7, keccak256("old"));
        bytes4[2] memory selectors = [ISmartWalletSbtV1.paused.selector, ISmartWalletSbtV1.verify.selector];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(address(next), abi.encodeWithSelector(selectors[i]), hex"01");
            vm.expectRevert();
            registry.setSbtConfig(address(next), 8, keccak256("malformed"));
            assertEq(address(registry.participantSbt()), address(old));
            assertEq(registry.sbtTokenId(), 7);
            vm.clearMockedCalls();
        }
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SbtConfigChanged(address(old), address(next), 7, 8, keccak256("replacement"));
        registry.setSbtConfig(address(next), 8, keccak256("replacement"));
        assertEq(address(registry.participantSbt()), address(next));
        assertEq(registry.sbtTokenId(), 8);
    }

    function testQuoteCannotCarryStockMetadataAndBadDecimalsRemainAbsent() public {
        V1MockToken token = new V1MockToken("new-quote", 6);
        TokenConfig memory good = _config(address(token), 0, address(0));
        for (uint8 fault; fault < 8; ++fault) {
            TokenConfig memory bad = abi.decode(abi.encode(good), (TokenConfig));
            if (fault == 0) bad.legalShareAdapter = address(stockAdapter);
            else if (fault == 1) bad.legalAdapterCodeHash = keccak256("adapter-code");
            else if (fault == 2) bad.legalAdapterVersion = 1;
            else if (fault == 3) bad.legalSharePolicyHash = keccak256("policy");
            else if (fault == 4) bad.poolDecimals = 18;
            else if (fault == 5) bad.poolDecimals = 19;
            else if (fault == 6) bad.poolRuntimeCodeHash = keccak256("code");
            else bad.poolCurrency = makeAddr("no-code-currency");
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.registerToken(bad, keccak256("invalid-quote"));
            assertEq(registry.getToken(address(token)).poolCurrency, address(0));
        }
        vm.mockCallRevert(address(token), abi.encodeWithSelector(V1MockToken.decimals.selector), "metadata unavailable");
        vm.expectRevert();
        registry.registerToken(good, keccak256("bad-decimals-read"));
        assertEq(registry.getToken(address(token)).poolCurrency, address(0));
        vm.clearMockedCalls();
        registry.registerToken(good, keccak256("retry"));
    }
}

```

### test/unit/v1/registry/Pauses.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVPausesTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesTest is FoundationFixture {
    function testRelistingRetainsMarketPauseAndReportSequence() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        _assertOperationGates(false, false);
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable-token"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("delisted-token"));
        TokenConfig memory another = _newStockConfig(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(another, keccak256("delisted-security"));
        registry.relistSecurity(SECURITY, keccak256("relist"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("reenable-token"));
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.HALTED));
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(PauseMode.ALL));
        assertEq(registry.marketSequence(SECURITY), 1);
        assertEq(inbox.lastSequence(0, SECURITY), 1);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("still-halted"));
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 2);
        registry.enablePool(poolId, keccak256("enable"));
        _assertOperationGates(true, true);
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
    }

    /// @dev Verifies legal-share adapter replacement requires a pause and the next version.
    function testLegalAdapterReplacementRequiresPauseAndNextVersion() public {
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        uint256 pauseId = registry.addEmergencyPause(
            PauseScope.TOKEN,
            bytes32(uint256(uint160(address(stock)))),
            PauseMode.ALL,
            keccak256("replace"),
            keccak256("source")
        );
        BackedAutoFeeLegalShareAdapter wrongVersion =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 3);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(wrongVersion), keccak256("review"));
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        TokenConfig memory config = registry.getToken(address(stock));
        assertEq(config.legalShareAdapter, address(replacement));
        assertEq(config.legalAdapterVersion, 2);
        assertEq(config.legalAdapterCodeHash, address(replacement).codehash);
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.clearEmergencyPause(pauseId, keccak256("done"));
    }

    function testEmergencyPauseModesAcrossAllScopes() public {
        _grantPauseRoles();
        for (uint8 scope = 0; scope < 4; scope++) {
            bytes32 target = _pauseTarget(PauseScope(scope));
            for (uint8 mode = 1; mode <= 3; mode++) {
                uint256 id = registry.addEmergencyPause(
                    PauseScope(scope), target, PauseMode(mode), keccak256("pause"), keccak256("source")
                );
                assertEq(registry.activePauseCount(scope, target, mode), 1);
                (PauseScope savedScope, bytes32 savedTarget, PauseMode savedMode,,,,, bool active) =
                    registry.emergencyPauses(id);
                assertEq(uint8(savedScope), scope);
                assertEq(savedTarget, target);
                assertEq(uint8(savedMode), mode);
                assertTrue(active);
                _assertOperationGates(mode == uint8(PauseMode.LP), mode == uint8(PauseMode.TRADE));
                registry.clearEmergencyPause(id, keccak256("resume"));
                assertEq(registry.activePauseCount(scope, target, mode), 0);
                _assertOperationGates(true, true);
            }
        }
    }

    function testPauseEventsExposeEmergencyModeAndMarketMaskChanges() public {
        _grantPauseRoles();
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseOpened(
            1, uint8(PauseScope.POOL), poolId, uint8(PauseMode.LP), keccak256("pause")
        );
        _pause(PauseScope.POOL, poolId, PauseMode.LP);
        bytes32 reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.TRADE, uint64(2)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.OPEN),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.NONE),
            uint8(PauseMode.TRADE),
            2,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 2);
        reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.LP, uint64(3)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.HALTED),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.TRADE),
            uint8(PauseMode.ALL),
            3,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 3);
    }

    function testEmergencyPauseRecordsStackAndClearIndependently() public {
        _grantPauseRoles();
        uint256 trade1 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 trade2 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 lp = _pause(PauseScope.GLOBAL, 0, PauseMode.LP);
        uint256 all = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 2);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(all, keccak256("resume"));
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(lp, keccak256("resume"));
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(trade1, keccak256("resume"));
        _assertOperationGates(false, true);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.clearEmergencyPause(trade1, keccak256("again"));
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 1);
        registry.clearEmergencyPause(trade2, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testEmergencyPauseRejectsNoneInvalidEnumsAndUnauthorizedCallers() public {
        _grantPauseRoles();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.NONE, keccak256("pause"), keccak256("source"));
        (bool success,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(PauseScope.GLOBAL),
                    bytes32(0),
                    uint8(4),
                    keccak256("pause"),
                    keccak256("source")
                )
            );
        assertFalse(success);
        assertEq(registry.nextPauseId(), 1);
        address stranger = makeAddr("pause-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("pause"), keccak256("source"));
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        vm.expectRevert();
        vm.prank(stranger);
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.activePauseCount(uint8(PauseScope.GLOBAL), 0, uint8(PauseMode.ALL)), 1);
    }

    function testEmergencyPauseDoesNotAffectUnrelatedTargetsAndChecksBothCurrencies() public {
        _grantPauseRoles();
        _pause(PauseScope.POOL, keccak256("other-pool"), PauseMode.ALL);
        _pause(PauseScope.SECURITY, keccak256("other-security"), PauseMode.ALL);
        _pause(PauseScope.TOKEN, bytes32(uint256(uint160(makeAddr("other-token")))), PauseMode.ALL);
        _assertOperationGates(true, true);
        uint256 id = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.LP);
        _assertOperationGates(true, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        assertFalse(registry.isTradable(keccak256("absent-pool")));
        assertFalse(registry.isLPAllowed(keccak256("absent-pool")));
    }

    function testMarketPauseModesAccumulateAndResumeIndependently() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 1);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 2);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 3);
        _assertMarketPause(PauseMode.LP, true, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 4);
        _assertMarketPause(PauseMode.NONE, true, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 5);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 6);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 7);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 8);
        _assertMarketPause(PauseMode.NONE, true, true);
    }

    function testMarketFirstLPPauseAllowsTrading() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 1);
        _assertMarketPause(PauseMode.LP, true, false);
    }

    function testMarketFirstAllPauseBlocksBoth() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        _assertMarketPause(PauseMode.ALL, false, false);
    }

    function testEmergencyAndMarketPauseRecoveriesAreIndependent() public {
        _grantPauseRoles();
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, false);
        id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testPoolEnableRequiresBothOperationTypesToBeUnpaused() public {
        _grantPauseRoles();
        for (uint8 mode = 1; mode <= 3; mode++) {
            uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode(mode));
            registry.disablePool(poolId, keccak256("disable"));
            uint32 version = registry.getPool(poolId).version;
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId, keccak256("enable"));
            assertEq(registry.getPool(poolId).version, version);
            assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
            registry.clearEmergencyPause(id, keccak256("resume"));
            registry.enablePool(poolId, keccak256("enable"));
            _assertOperationGates(true, true);
        }
        registry.disablePool(poolId, keccak256("disable"));
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        registry.enablePool(poolId, keccak256("enable"));
    }

    function testAdapterReplacementRejectsSingleModePauseAndAllowsCombinedCoverage() public {
        _grantPauseRoles();
        uint256 trade = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.clearEmergencyPause(trade, keccak256("resume"));
        _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.LP);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        assertEq(registry.getToken(address(stock)).legalAdapterVersion, 2);
    }
}

```

### test/unit/v1/registry/Lifecycle.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, PoolStatus} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsLifecycleTest is OperationsFixture {
    using PoolIdLibrary for PoolKey;

    function testMultipleCurrenciesAndPoolsCountOneListedSecurity() public {
        TokenConfig memory secondCurrency = _newStockConfig(SECURITY);
        registry.registerToken(secondCurrency, keccak256("second-currency"));
        PoolKey memory secondKey = key;
        address a = secondCurrency.poolCurrency < address(quote) ? secondCurrency.poolCurrency : address(quote);
        address b = secondCurrency.poolCurrency < address(quote) ? address(quote) : secondCurrency.poolCurrency;
        secondKey.currency0 = Currency.wrap(a);
        secondKey.currency1 = Currency.wrap(b);
        bytes32 secondPool = registry.registerPendingPool(secondKey);
        registry.markPoolActive(secondPool, uint160(1 << 96), address(this), keccak256("price"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("active-pools"));
        registry.disablePool(poolId, keccak256("disable-first"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("one-active-pool"));
        registry.disablePool(secondPool, keccak256("disable-second"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 0);
        registry.relistSecurity(SECURITY, keccak256("relist"));
        registry.enablePool(poolId, keccak256("enable-first"));
        registry.enablePool(secondPool, keccak256("enable-second"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
        assertEq(registry.activePoolCountByCurrency(address(quote)), 2);
        assertEq(keccak256(abi.encode(registry.getPool(secondPool).key)), keccak256(abi.encode(secondKey)));
    }

    function testRelistingFullTierRollsBackThenSucceedsAfterCapacityRestored() public {
        registry.setTierPolicy(1, 25, 1, keccak256("capacity-one"));
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        _admitAdditionalSecurity(keccak256("other-security"), keccak256("OTHER"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.relistSecurity(SECURITY, keccak256("full"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(1, 25, 2, keccak256("capacity-two"));
        registry.relistSecurity(SECURITY, keccak256("retry"));
        assertEq(registry.tierPolicy(1).listedCount, 2);
        assertEq(registry.getSecurity(SECURITY).version, 3);
    }

    function testTierMoveReleasesOldSlotAndFailedMoveLeavesCountsAndCap() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        registry.setTierPolicy(2, 10, 0, keccak256("full-tier"));
        bytes32 beforeState = _lifecycleState();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSecurityTier(SECURITY, 2, keccak256("full"));
        assertEq(_lifecycleState(), beforeState);
        registry.setTierPolicy(2, 10, 1, keccak256("capacity"));
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityTierChanged(SECURITY, 1, 2, keccak256("move"));
        registry.setSecurityTier(SECURITY, 2, keccak256("move"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        assertEq(registry.tierPolicy(2).listedCount, 1);
        assertEq(registry.getSecurity(SECURITY).version, 2);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        registry.setSecurityTier(SECURITY, 1, keccak256("move-back"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.tierPolicy(2).listedCount, 0);
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1.5e18);
    }

    function testLifecycleRejectsUnknownNoopAndMissingEvidenceWithoutWrites() public {
        bytes32 absent = keccak256("absent-security");
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(TSVRegistryV1.relistSecurity, (SECURITY, keccak256("already-listed")));
        calls[1] = abi.encodeCall(TSVRegistryV1.relistSecurity, (absent, keccak256("unknown")));
        calls[2] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 1, keccak256("same-tier")));
        calls[3] = abi.encodeCall(TSVRegistryV1.setSecurityTier, (SECURITY, 2, bytes32(0)));
        calls[4] = abi.encodeCall(TSVRegistryV1.delistSecurity, (absent, keccak256("unknown")));
        calls[5] = abi.encodeCall(TSVRegistryV1.delistSecurity, (SECURITY, bytes32(0)));
        calls[6] = abi.encodeCall(TSVRegistryV1.disablePool, (poolId, bytes32(0)));
        calls[7] = abi.encodeCall(TSVRegistryV1.disablePool, (bytes32(0), keccak256("unknown")));
        calls[8] = abi.encodeCall(TSVRegistryV1.enablePool, (poolId, keccak256("already-active")));
        for (uint256 i; i < calls.length; ++i) {
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            _registryCall(calls[i]);
            assertEq(_lifecycleState(), beforeState);
        }
        registry.disablePool(poolId, keccak256("disable"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.disablePool(poolId, keccak256("twice"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.delistSecurity(SECURITY, keccak256("twice"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.relistSecurity(SECURITY, 0);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setSecurityTier(SECURITY, 2, keccak256("delisted"));
    }

    function testPoolEnableRechecksEachCurrencyAndDoesNotChangeCountsOnFailure() public {
        registry.disablePool(poolId, keccak256("disable"));
        address[2] memory currencies = [address(stock), address(quote)];
        for (uint256 i; i < currencies.length; ++i) {
            registry.setTokenStatus(currencies[i], TokenStatus.DISABLED, keccak256("disable-currency"));
            bytes32 beforeState = _lifecycleState();
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId, keccak256("blocked"));
            assertEq(_lifecycleState(), beforeState);
            registry.setTokenStatus(currencies[i], TokenStatus.APPROVED, keccak256("reenable-currency"));
        }
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, 0);
        registry.enablePool(poolId, keccak256("enable"));
        assertEq(registry.getPool(poolId).version, 4);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
    }

    function testDelistingDoesNotReleaseSymbolIdentity() public {
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        bytes32 otherSecurity = keccak256("other-security");
        TokenConfig memory config = _newStockConfig(otherSecurity);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(otherSecurity, keccak256("STDx"), 1, config, keccak256("reused-symbol"));
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(SECURITY, keccak256("new-symbol"), 1, config, keccak256("reused-id"));
        assertEq(registry.tierPolicy(1).listedCount, 0);
        registry.relistSecurity(SECURITY, keccak256("relist"));
        assertEq(registry.getSecurity(SECURITY).symbolHash, keccak256("STDx"));
    }

    function _lifecycleState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                registry.getSecurity(SECURITY),
                registry.tierPolicy(1),
                registry.tierPolicy(2),
                registry.getPool(poolId),
                registry.getToken(address(stock)),
                registry.getToken(address(quote)),
                registry.activePoolCountByCurrency(address(stock)),
                registry.activePoolCountByCurrency(address(quote)),
                ledger.used(SECURITY, DAY)
            )
        );
    }

    function _registryCall(bytes memory payload) private {
        (bool ok, bytes memory result) = address(registry).call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

```

### test/unit/v1/registry/PauseBoundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsPauseBoundariesTest is FoundationFixture {
    function testInvalidPauseMetadataAndTargetsDoNotAllocateIdOrChangeGates() public {
        _grantPauseRoles();
        for (uint8 fault; fault < 7; ++fault) {
            PauseScope scope = PauseScope.GLOBAL;
            bytes32 target;
            PauseMode mode = PauseMode.ALL;
            bytes32 reason = keccak256("incident");
            bytes32 source = keccak256("source");
            if (fault == 0) reason = 0;
            else if (fault == 1) source = 0;
            else if (fault == 2) target = SECURITY;
            else if (fault == 3) scope = PauseScope.SECURITY;
            else if (fault == 4) scope = PauseScope.TOKEN;
            else if (fault == 5) scope = PauseScope.POOL;
            else mode = PauseMode.NONE;
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.addEmergencyPause(scope, target, mode, reason, source);
            assertEq(registry.nextPauseId(), 1);
            assertEq(registry.activePauseCount(uint8(scope), target, uint8(mode)), 0);
            _assertOperationGates(true, true);
        }
        (bool ok,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(4),
                    bytes32(0),
                    uint8(PauseMode.ALL),
                    keccak256("incident"),
                    keccak256("source")
                )
            );
        assertFalse(ok);
        assertEq(registry.nextPauseId(), 1);
    }

    function testPauseAuditMetadataSurvivesClearAndIdsAreNeverReused() public {
        _grantPauseRoles();
        bytes32 reason = keccak256("incident");
        bytes32 source = keccak256("source");
        uint64 opened = uint64(block.timestamp);
        uint256 id = registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.LP, reason, source);
        (
            PauseScope scope,
            bytes32 target,
            PauseMode mode,
            bytes32 savedReason,
            bytes32 savedSource,
            address operator,
            uint64 timestamp,
            bool active
        ) = registry.emergencyPauses(id);
        assertEq(uint8(scope), uint8(PauseScope.SECURITY));
        assertEq(target, SECURITY);
        assertEq(uint8(mode), uint8(PauseMode.LP));
        assertEq(savedReason, reason);
        assertEq(savedSource, source);
        assertEq(operator, address(this));
        assertEq(timestamp, opened);
        assertTrue(active);
        bytes32 beforeState = _pauseState(id);
        uint256[3] memory invalid = [uint256(0), 999, id];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.clearEmergencyPause(invalid[i], i == 2 ? bytes32(0) : keccak256("clear"));
            assertEq(_pauseState(id), beforeState);
        }
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseClosed(id, keccak256("resolved"));
        registry.clearEmergencyPause(id, keccak256("resolved"));
        (,,, savedReason, savedSource, operator, timestamp, active) = registry.emergencyPauses(id);
        assertFalse(active);
        assertEq(savedReason, reason);
        assertEq(savedSource, source);
        assertEq(operator, address(this));
        assertEq(timestamp, opened);
        assertEq(_pause(PauseScope.SECURITY, SECURITY, PauseMode.LP), id + 1);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.clearEmergencyPause(id, keccak256("old-record"));
        assertEq(registry.activePauseCount(uint8(PauseScope.SECURITY), SECURITY, uint8(PauseMode.LP)), 1);
    }

    function _pauseState(uint256 id) private view returns (bytes32) {
        (
            PauseScope scope,
            bytes32 target,
            PauseMode mode,
            bytes32 reason,
            bytes32 source,
            address operator,
            uint64 timestamp,
            bool active
        ) = registry.emergencyPauses(id);
        return keccak256(
            abi.encode(
                scope,
                target,
                mode,
                reason,
                source,
                operator,
                timestamp,
                active,
                registry.nextPauseId(),
                registry.activePauseCount(uint8(scope), target, uint8(mode)),
                registry.isTradable(poolId),
                registry.isLPAllowed(poolId)
            )
        );
    }
}

```

### test/unit/v1/registry/AdapterChanges.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig, PauseScope, PauseMode, MarketAction} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsAdapterChangesTest is OperationsFixture {
    function testInactiveCurrencyReplacementDoesNotRequirePauseAndIncrementsEveryVersion() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        registry.disablePool(poolId, keccak256("disable"));
        for (uint32 version = 2; version <= 3; ++version) {
            BackedAutoFeeLegalShareAdapter replacement =
                new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), version);
            bytes32 evidence = keccak256(abi.encode("policy", version));
            address old = registry.getToken(address(stock)).legalShareAdapter;
            vm.expectEmit(true, false, false, true, address(registry));
            emit TSVRegistryV1.LegalShareAdapterChanged(address(stock), old, address(replacement), version, evidence);
            registry.replaceLegalShareAdapter(address(stock), address(replacement), evidence);
            TokenConfig memory stored = registry.getToken(address(stock));
            assertEq(stored.legalShareAdapter, address(replacement));
            assertEq(stored.legalAdapterVersion, version);
            assertEq(stored.legalAdapterCodeHash, address(replacement).codehash);
            assertEq(stored.legalSharePolicyHash, evidence);
            assertEq(ledger.used(SECURITY, DAY), 1e18);
        }
        registry.enablePool(poolId, keccak256("enable"));
        _assertOperationGates(true, true);
    }

    function testMarketSecurityAndPoolPausesDoNotAuthorizeActiveAdapterReplacement() public {
        _grantPauseRoles();
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        _pause(PauseScope.POOL, poolId, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        bytes32 beforeState = keccak256(abi.encode(registry.getToken(address(stock))));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("wrong-pause-scope"));
        assertEq(keccak256(abi.encode(registry.getToken(address(stock)))), beforeState);
        _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("correct-scope"));
    }

    function testReplacementRejectsInvalidIdentityEvidenceInterfaceCurrencyAndVersion() public {
        _grantPauseRoles();
        _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter good =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        BackedAutoFeeLegalShareAdapter wrongVersion =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 3);
        BackedAutoFeeLegalShareAdapter wrongCurrency =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        for (uint8 fault; fault < 8; ++fault) {
            address currency = address(stock);
            address adapter = address(good);
            bytes32 evidence = keccak256("policy");
            if (fault == 0) {
                currency = address(quote);
            } else if (fault == 1) {
                currency = makeAddr("unknown");
            } else if (fault == 2) {
                adapter = address(stockAdapter);
            } else if (fault == 3) {
                adapter = makeAddr("no-code-adapter");
            } else if (fault == 4) {
                evidence = 0;
            } else if (fault == 5) {
                adapter = address(wrongVersion);
            } else if (fault == 6) {
                adapter = address(wrongCurrency);
                vm.mockCall(
                    adapter,
                    abi.encodeWithSelector(IDirectLegalShareAdapter.poolCurrency.selector),
                    abi.encode(address(quote))
                );
            } else {
                vm.mockCall(
                    address(good), abi.encodeWithSelector(IERC165.supportsInterface.selector), abi.encode(false)
                );
            }
            bytes32 beforeState = keccak256(abi.encode(registry.getToken(address(stock))));
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.replaceLegalShareAdapter(currency, adapter, evidence);
            assertEq(keccak256(abi.encode(registry.getToken(address(stock)))), beforeState);
            vm.clearMockedCalls();
        }
        registry.replaceLegalShareAdapter(address(stock), address(good), keccak256("retry"));
    }
}

```

### test/unit/v1/trading/VolumeAccounting.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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

```

### test/unit/v1/trading/Initialization.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {GovernanceFixture} from "../../../helpers/v1/GovernanceFixture.sol";

contract TSVRouterInitializationTest is GovernanceFixture {
    function testRouterRejectsEveryDependencyWithoutCode() public {
        for (uint256 i; i < 3; i++) {
            address[3] memory dependencies_ = [address(this), address(this), address(this)];
            dependencies_[i] = address(0);
            address implementation = address(new TSVSwapRouterV1());
            bytes memory initialization = abi.encodeCall(
                TSVSwapRouterV1.initialize, (address(anchor), dependencies_[0], dependencies_[1], dependencies_[2])
            );
            vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
            new TSVERC1967Proxy(implementation, initialization);
        }
    }
}

```

### test/unit/v1/reports/SplitFactorBoundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {AdtvReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TradeDayLib} from "tsv-v1/libraries/TradeDayLib.sol";
import {ReportValidationLib} from "tsv-v1/libraries/ReportValidationLib.sol";
import {SplitFactorFixture} from "../../../helpers/v1/SplitFactorFixture.sol";

/// @dev Authorization, malformed reports, locked history, arithmetic limits and failure-state preservation.
contract TSVSplitFactorBoundariesTest is SplitFactorFixture {
    function testScheduleCorrectionAndCancellationEventsCarryCanonicalFactorsAndSourceEvidence() public {
        SplitFactorReport memory first = _factor(20261002, 2, 10, 1, 1, keccak256("event-first"));
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorScheduled(
            SECURITY, 202609, 20261002, 1, 5, 1, first.reportId, first.sourceHash
        );
        inbox.submitSplitFactor(first);
        SplitFactorReport memory correction = _factor(20261002, 3, 1, 2, 2, keccak256("event-correction"));
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorScheduled(
            SECURITY, 202609, 20261002, 3, 1, 2, correction.reportId, correction.sourceHash
        );
        inbox.submitSplitFactor(correction);
        SplitFactorReport memory cancelled = _factor(20261002, 0, 0, 3, 3, keccak256("event-cancellation"));
        cancelled.action = 2;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.SplitFactorCancelled(
            SECURITY, 202609, 20261002, correction.reportId, 3, cancelled.reportId, cancelled.sourceHash
        );
        inbox.submitSplitFactor(cancelled);
    }

    function testDelistedSecurityCannotReceiveNewFactorReports() public {
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("delisted-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(report);
        assertEq(_factorState(report), beforeState);
    }

    function testOnlyVolumeReporterCanScheduleOrCancelAndRevocationTakesEffectImmediately() public {
        address outsider = makeAddr("factor-outsider");
        address haltReporter = makeAddr("factor-halt-reporter");
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), haltReporter);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("factor-role"));
        address[2] memory callers = [outsider, haltReporter];
        for (uint256 i; i < callers.length; ++i) {
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(callers[i]);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
        inbox.revokeRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitSplitFactor(report); // The Governor is not implicitly a reporter.
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        inbox.submitSplitFactor(report);
        report = _factor(20261002, 0, 0, 2, 2, keccak256("factor-cancel-role"));
        report.action = 2;
        inbox.revokeRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitSplitFactor(report);
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        inbox.submitSplitFactor(report);
        _assertFactor(20261002, 1, 1);
    }

    function testLedgerFactorWriterIsOnlyTheBoundInbox() public {
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("direct-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptSplitFactor(report);
        assertEq(_factorState(report), beforeState);
    }

    function testInvalidBusinessFieldsDoNotConsumeReportMetadataAndTheSameIdCanBeRetried() public {
        for (uint8 fault; fault < 12; ++fault) {
            SplitFactorReport memory report =
                _factor(20261002, 2, 1, 1, 1, keccak256(abi.encode("invalid-factor", fault)));
            if (fault == 0) report.securityId = 0;
            else if (fault == 1) report.securityId = keccak256("unknown-security");
            else if (fault == 2) report.sourceMonth = 202613;
            else if (fault == 3) report.sourceMonth = 202608;
            else if (fault == 4) report.effectiveTradeDayId = DAY;
            else if (fault == 5) report.effectiveTradeDayId = 20261032;
            else if (fault == 6) report.numerator = 0;
            else if (fault == 7) report.denominator = 0;
            else if (fault == 8) report.action = 0;
            else if (fault == 9) report.action = 3;
            else if (fault == 10) report.version = 0;
            else report.version = 2;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(fault == 5 ? TradeDayLib.InvalidPeriod.selector : TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
            assertFalse(inbox.reportIdUsed(report.reportId));
        }
        SplitFactorReport memory retry = _factor(20261002, 2, 1, 1, 1, keccak256(abi.encode("invalid-factor", 6)));
        inbox.submitSplitFactor(retry);
        assertTrue(inbox.reportIdUsed(retry.reportId));
        _assertFactor(20261002, 2, 1);
    }

    function testInvalidIngressMetadataAndReplayLeaveAllFactorStateUnchanged() public {
        _setFactor(20261002, 2, 1, 1, 1);
        for (uint8 fault; fault < 8; ++fault) {
            SplitFactorReport memory report =
                _factor(20261003, 3, 1, 2, 2, keccak256(abi.encode("factor-ingress", fault)));
            if (fault == 0) report.reportId = 0;
            else if (fault == 1) report.sourceHash = 0;
            else if (fault == 2) report.sequence = 0;
            else if (fault == 3) report.sequence = 1;
            else if (fault == 4) report.sourceTimestamp = uint64(block.timestamp - 1);
            else if (fault == 5) report.sourceTimestamp = uint64(block.timestamp + 1);
            else if (fault == 6) report.submitDeadline = uint64(block.timestamp - 1);
            else report.reportId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 0).reportId;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(
                fault == 5 || fault == 6
                    ? ReportValidationLib.Expired.selector
                    : ReportValidationLib.InvalidReport.selector
            );
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
    }

    function testSplitReportIdsAreGlobalButSequenceAndVersionScopesRemainIndependent() public {
        _submitAdtv(1000e18);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("adtv"));
        vm.expectRevert(ReportValidationLib.InvalidReport.selector);
        inbox.submitSplitFactor(report);
        assertEq(inbox.lastSequence(3, SECURITY), 0);
        report.reportId = keccak256("distinct-factor-id");
        report.sequence = 7; // Gaps are permitted, but source ordering is independent from ADTV.
        inbox.submitSplitFactor(report);
        assertEq(inbox.lastSequence(1, SECURITY), 1);
        assertEq(inbox.lastSequence(3, SECURITY), 7);
        assertEq(ledger.splitFactorVersion(SECURITY, uint32(MONTH)), 1);
    }

    function testSourceTimeAndSubmissionDeadlineCannotSelectAnIntradayActivationTime() public {
        _submitAdtv(1000e18);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("timestamp-fields"));
        report.submitDeadline = uint64(block.timestamp); // Inclusive acceptance; not a factor expiry.
        inbox.submitSplitFactor(report);
        vm.warp(block.timestamp + 1000);
        (, uint32 day) = ledger.currentTradeDay();
        assertEq(day, DAY);
        _assertFactor(day, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, day);
        assertEq(left, 2.5e18);
        vm.warp(ledger.dayStartUTC(20261002));
        _assertFactor(20261002, 2, 1);
    }

    function testCancellationRequiresTheLatestPendingDayAndZeroFactorComponents() public {
        SplitFactorReport memory empty = _factor(20261002, 0, 0, 1, 1, keccak256("cancel-empty"));
        empty.action = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(empty);
        _setFactor(20261002, 2, 1, 1, 1);
        _setFactor(20261005, 3, 1, 2, 2);
        for (uint8 fault; fault < 3; ++fault) {
            SplitFactorReport memory report =
                _factor(20261005, 0, 0, 3, 3, keccak256(abi.encode("invalid-cancel", fault)));
            report.action = 2;
            if (fault == 0) report.effectiveTradeDayId = 20261002;
            else if (fault == 1) report.numerator = 1;
            else report.denominator = 1;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
    }

    function testCancellationOneSecondBeforeStartSucceedsButAtStartIsLocked() public {
        _setFactor(20261002, 2, 1, 1, 1);
        uint256 snapshot = vm.snapshotState();
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        _cancelFactor(20261002, 2, 2);
        _assertFactor(20261002, 1, 1);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(start);
        SplitFactorReport memory locked = _factor(20261002, 0, 0, 2, 2, keccak256("cancel-at-start"));
        locked.action = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(locked);
        _assertFactor(20261002, 2, 1);
    }

    function testFactorOverflowRejectsScheduleOrAdtvCorrectionWithoutPoisoningFutureCaps() public {
        _submitAdtv(type(uint256).max);
        SplitFactorReport memory report = _factor(20261002, 2, 1, 1, 1, keccak256("overflow-factor"));
        bytes32 beforeState = _factorState(report);
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitSplitFactor(report);
        assertEq(_factorState(report), beforeState);

        inbox.submitAdtv(_adtv(SECURITY, type(uint256).max / 2, 2, 2, keccak256("safe-large-basis")));
        inbox.submitSplitFactor(report); // Reuse the rejected report ID after fixing the basis.
        registry.setTierPolicy(1, 10000, 10, keccak256("maximum-tier"));
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, type(uint256).max - 1);

        AdtvReport memory correction = _adtv(SECURITY, type(uint256).max, 3, 3, keccak256("overflow-correction"));
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitAdtv(correction);
        assertFalse(inbox.reportIdUsed(correction.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).value, type(uint256).max / 2);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, type(uint256).max - 1);
    }

    function testScheduledFactorBeforeAdtvAlsoGuardsTheFirstReportAgainstOverflow() public {
        _setFactor(20261002, 2, 1, 1, 1);
        AdtvReport memory first = _adtv(SECURITY, type(uint256).max, 1, 1, keccak256("first-basis-overflow"));
        vm.expectRevert(stdError.arithmeticError);
        inbox.submitAdtv(first);
        assertFalse(inbox.reportIdUsed(first.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).version, 0);
        first.adtvWad = type(uint256).max / 2;
        inbox.submitAdtv(first);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).version, 1);
    }

    function testMaximumEqualFractionReducesToIdentityAndAllMonthDaysRemainQueryable() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, type(uint128).max, type(uint128).max, 1, 1);
        _assertFactor(20261002, 1, 1);
        for (uint32 day = 20261003; day <= 20261031; ++day) {
            _setFactor(day, uint128(day - 20261000), 1, uint64(day - DAY), uint64(day - DAY));
        }
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 30);
        for (uint32 day = 20261003; day <= 20261031; ++day) {
            _assertFactor(day, uint128(day - 20261000), 1);
        }
        _assertFactor(20261101, 1, 1);
    }

    function testFuzzAdjustedCapMatchesIndependentBoundedIntegerFormula(uint160 value, uint64 n, uint64 d, uint16 bps)
        public
    {
        value = uint160(bound(value, 1, type(uint160).max));
        n = uint64(bound(n, 1, type(uint64).max));
        d = uint64(bound(d, 1, type(uint64).max));
        bps = uint16(bound(bps, 1, 10000));
        registry.setTierPolicy(1, bps, 10, keccak256("factor-fuzz-tier"));
        _submitAdtv(value);
        _setFactor(20261002, n, d, 1, 1);
        // This oracle uses ordinary integer multiplication in a proven < 238-bit input range.
        uint256 expected = uint256(value) * n * bps / (uint256(d) * 10000);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(valid, expected != 0);
        assertEq(left, expected);
    }
}

```

### test/unit/v1/reports/AdtvBatch.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsAdtvBatchTest is OperationsFixture {
    function testBatchRejectsEmptyAndAboveMaximumBeforeAnyWrite() public {
        AdtvReport[] memory reports = new AdtvReport[](0);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        reports = new AdtvReport[](101);
        reports[0] = _adtv(SECURITY, 1000e18, 1, 1, keccak256("too-many"));
        bytes32 beforeState = _reportState(reports[0].reportId);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_reportState(reports[0].reportId), beforeState);
        assertEq(inbox.MAX_ADTV_BATCH_SIZE(), 100);
    }

    function testSingleElementBatchUsesSameRulesAsSingleReport() public {
        AdtvReport[] memory reports = new AdtvReport[](1);
        reports[0] = _adtv(SECURITY, 1000e18, 1, 1, keccak256("one"));
        inbox.submitAdtvBatch(reports);
        reports[0] = _adtv(SECURITY, 500e18, 2, 2, keccak256("one-correction"));
        inbox.submitAdtvBatch(reports);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).value, 500e18);
        assertEq(inbox.lastSequence(1, SECURITY), 2);
    }

    function testMaximumBatchLastFailureRollsBackAllReportsThenRetrySucceeds() public {
        AdtvReport[] memory reports = _batch(100);
        reports[99].version = 2;
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        for (uint256 i; i < reports.length; ++i) {
            assertFalse(inbox.reportIdUsed(reports[i].reportId));
            assertEq(inbox.lastSequence(1, reports[i].securityId), 0);
            assertEq(inbox.lastSourceTimestamp(1, reports[i].securityId), 0);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).version, 0);
        }
        reports[99].version = 1;
        inbox.submitAdtvBatch(reports);
        for (uint256 i; i < reports.length; ++i) {
            assertTrue(inbox.reportIdUsed(reports[i].reportId));
            assertEq(inbox.lastSequence(1, reports[i].securityId), 1);
            assertEq(inbox.lastSourceTimestamp(1, reports[i].securityId), reports[i].sourceTimestamp);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).value, reports[i].adtvWad);
            assertEq(ledger.adtvOf(reports[i].securityId, uint32(MONTH)).reportId, reports[i].reportId);
        }
    }

    function testBatchRejectsZeroDuplicateDescendingAndMixedMonthAtomically() public {
        AdtvReport[] memory good = _batch(3);
        for (uint8 fault; fault < 4; ++fault) {
            AdtvReport[] memory bad = abi.decode(abi.encode(good), (AdtvReport[]));
            if (fault == 0) {
                bad[1].securityId = 0;
            } else if (fault == 1) {
                bad[1].securityId = bad[0].securityId;
            } else if (fault == 2) {
                AdtvReport memory tmp = bad[1];
                bad[1] = bad[0];
                bad[0] = tmp;
            } else {
                bad[1].sourceMonth = 202610;
            }
            bytes32 beforeState = _batchState(good);
            vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
            inbox.submitAdtvBatch(bad);
            assertEq(_batchState(good), beforeState);
        }
        inbox.submitAdtvBatch(good);
    }

    function testBatchDuplicateReportIdAcrossSecuritiesRollsBackAndCanRetry() public {
        AdtvReport[] memory reports = _batch(3);
        bytes32 originalId = reports[2].reportId;
        reports[2].reportId = reports[0].reportId;
        bytes32 beforeState = _batchState(reports);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_batchState(reports), beforeState);
        reports[2].reportId = originalId;
        inbox.submitAdtvBatch(reports);
        assertTrue(inbox.reportIdUsed(originalId));
    }

    function testFuzzBatchFailureAtEverySmallBatchPositionIsAtomic(uint8 position, bool ingressFault) public {
        position = uint8(bound(position, 0, 2));
        AdtvReport[] memory reports = _batch(3);
        bytes32 beforeState = _batchState(reports);
        if (ingressFault) reports[position].submitDeadline = uint64(block.timestamp - 1);
        else reports[position].adtvWad = 0;
        vm.expectRevert(ingressFault ? TSVDataInboxV1.Expired.selector : TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);
        assertEq(_batchState(reports), beforeState);
    }

    function _batch(uint256 size) private returns (AdtvReport[] memory reports) {
        registry.setTierPolicy(1, 25, uint32(size + 1), keccak256("batch-capacity"));
        reports = new AdtvReport[](size);
        for (uint256 i; i < size; ++i) {
            bytes32 security = bytes32(i + 1);
            _admitAdditionalSecurity(security, keccak256(abi.encode("batch-symbol", i)));
            reports[i] = _adtv(security, (i + 1) * 1000e18, 1, 1, keccak256(abi.encode("batch-id", i)));
        }
    }

    function _batchState(AdtvReport[] memory reports) private view returns (bytes32 digest) {
        for (uint256 i; i < reports.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest, _reportState(reports[i].securityId, reports[i].sourceMonth, DAY, reports[i].reportId)
                )
            );
        }
    }
}

```

### test/unit/v1/reports/CalendarBoundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsCalendarTest is OperationsFixture {
    function testCalendarBoundariesMatchIndependentUtcVectors() public {
        // Unix timestamps generated independently with Python datetime(timezone.utc).
        uint32[8] memory dates =
            [uint32(20261001), 20261003, 20261004, 20261101, 20270101, 20280229, 20280301, 21000301];
        uint32[8] memory previous =
            [uint32(20260930), 20261002, 20261003, 20261031, 20261231, 20280228, 20280229, 21000228];
        uint64[8] memory midnights =
            [uint64(1790812800), 1790985600, 1791072000, 1793491200, 1798761600, 1835395200, 1835481600, 4107542400];
        for (uint256 i; i < dates.length; ++i) {
            uint64 start = midnights[i] + 14400;
            assertEq(ledger.dayStartUTC(dates[i]), start);
            vm.warp(start - 1);
            (, uint32 day) = ledger.currentTradeDay();
            assertEq(day, previous[i]);
            vm.warp(start);
            (, day) = ledger.currentTradeDay();
            assertEq(day, dates[i]);
            vm.warp(start + 1);
            (, day) = ledger.currentTradeDay();
            assertEq(day, dates[i]);
        }
        assertEq(ledger.dayStartUTC(20000229), 951782400 + 14400);
    }

    function testFuzzInitialOffsetAssignsEverySecondToExactlyOneDay(uint32 offset, uint32 second) public {
        offset = uint32(bound(offset, 0, 86399));
        second = uint32(bound(second, 0, 86399));
        TSVVolumeLedgerV1 custom = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), offset))
                )
            )
        );
        vm.warp(1791072000 + second); // 2026-10-04 00:00 UTC + independently selected second.
        (bool exists, uint32 day) = custom.currentTradeDay();
        assertTrue(exists);
        assertEq(day, second >= offset ? 20261004 : 20261003);
        assertEq(custom.dayStartUTC(20261004), 1791072000 + offset);
    }

    function testInvalidGregorianDatesAreRejected() public {
        uint32[11] memory invalid = [
            uint32(0),
            19691231,
            20260001,
            20261301,
            20261000,
            20260431,
            20260229,
            21000229,
            20260230,
            100000101,
            20260132
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
            ledger.dayStartUTC(invalid[i]);
        }
    }

    function testShortestTransitionHasNoOverlapAndOneTradeDay() public {
        ledger.scheduleDayStart(0, 20261004, keccak256("minus-four-hours"));
        assertEq(ledger.dayStartUTC(20261004) - ledger.dayStartUTC(20261003), 20 hours);
        vm.warp(1791072000 - 1);
        (, uint32 day) = ledger.currentTradeDay();
        assertEq(day, 20261003);
        vm.warp(1791072000);
        (, day) = ledger.currentTradeDay();
        assertEq(day, 20261004);
        assertEq(ledger.dayStartUTC(DAY), 1790827200);
    }

    function testPendingScheduleAndCancellationBoundsKeepHistoricalUsage() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        uint64 historicalStart = ledger.dayStartUTC(DAY);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(keccak256("none"));
        uint32[4] memory badOffsets = [uint32(86400), 14400, 28801, type(uint32).max];
        for (uint256 i; i < badOffsets.length; ++i) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
            ledger.scheduleDayStart(badOffsets[i], 20261004, keccak256("invalid-offset"));
            assertEq(ledger.dayStartCheckpointCount(), 0);
        }
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18000, 20261004, 0);
        bytes32 reason = keccak256("schedule");
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.DayStartScheduled(20261004, 20261003, 14400, 18000, 1791090000, address(this), reason);
        ledger.scheduleDayStart(18000, 20261004, reason);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(21600, 20261005, keccak256("second-pending"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(0);
        assertEq(ledger.dayStartCheckpointCount(), 1);
        vm.warp(1791000000 - 1); // Last second before transition day 2026-10-03 begins.
        vm.expectEmit(true, true, false, true, address(ledger));
        emit TSVVolumeLedgerV1.DayStartCancelled(20261004, address(this), keccak256("cancel"));
        ledger.cancelPendingDayStart(keccak256("cancel"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(DAY), historicalStart);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function testScheduleLocksExactlyAtTransitionStartAndCannotCancelAfterActivation() public {
        ledger.scheduleDayStart(18000, 20261004, keccak256("schedule"));
        uint64 transitionStart = ledger.dayStartUTC(20261003);
        vm.warp(transitionStart);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(keccak256("too-late"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(21600, 20261005, keccak256("replace-locked"));
        vm.warp(ledger.dayStartUTC(20261004));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(keccak256("already-active"));
        assertEq(ledger.dayStartCheckpointCount(), 1);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(14400, 20261004, keccak256("same-effective-day"));
        assertEq(ledger.dayStartCheckpointCount(), 1);
    }

    function testCheckpointLookupPreservesEarlierOffsetsAfterMultipleChanges() public {
        ledger.scheduleDayStart(18000, 20261004, keccak256("first"));
        vm.warp(1791090000);
        ledger.scheduleDayStart(3600, 20261007, keccak256("second"));
        vm.warp(1791334800); // 2026-10-07 01:00 UTC.
        ledger.scheduleDayStart(14400, 20261010, keccak256("third"));
        assertEq(ledger.dayStartCheckpointCount(), 3);
        assertEq(ledger.dayStartUTC(20261001), 1790827200);
        assertEq(ledger.dayStartUTC(20261004), 1791090000);
        assertEq(ledger.dayStartUTC(20261007), 1791334800);
        assertEq(ledger.dayStartUTC(20261010), 1791604800);
        assertEq(ledger.dayStartUTC(20261011), 1791691200);
    }
}

```

### test/unit/v1/reports/Bindings.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

contract TSVOperationsBindingsTest is FoundationFixture {
    function testLedgerAndInboxInitializationRejectZeroDependenciesAndInvalidOffsets() public {
        address ledgerImpl = address(new TSVVolumeLedgerV1());
        address inboxImpl = address(new TSVDataInboxV1());
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        new ERC1967Proxy(ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(0), 14400)));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        new ERC1967Proxy(
            ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 86400))
        );
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        new ERC1967Proxy(
            inboxImpl, abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(0), address(ledger)))
        );
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        new ERC1967Proxy(
            inboxImpl, abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(0)))
        );
        TSVVolumeLedgerV1 maxOffset = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    ledgerImpl,
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 86399))
                )
            )
        );
        assertEq(maxOffset.initialDayStartOffsetSeconds(), 86399);
    }

    function testRegistryBindingIsGovernorOnlyAtomicAndOneTime() public {
        TSVRegistryV1 fresh = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        address stranger = makeAddr("binding-outsider");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        fresh.bindComponents(address(this), address(this), address(inbox));
        for (uint8 slot; slot < 3; ++slot) {
            address[3] memory components = [address(this), address(this), address(inbox)];
            components[slot] = stranger;
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            fresh.bindComponents(components[0], components[1], components[2]);
            assertEq(fresh.hook(), address(0));
            assertEq(fresh.lpManager(), address(0));
            assertEq(fresh.dataInbox(), address(0));
        }
        fresh.bindComponents(address(this), address(this), address(inbox));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        fresh.bindComponents(address(this), address(this), address(inbox));
        assertEq(fresh.dataInbox(), address(inbox));
    }

    function testLedgerWriterBindingIsGovernorOnlyAtomicAndOneTime() public {
        TSVVolumeLedgerV1 fresh = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14400))
                )
            )
        );
        address stranger = makeAddr("writer-outsider");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        vm.prank(stranger);
        fresh.bindWriters(address(this), address(inbox));
        for (uint8 slot; slot < 2; ++slot) {
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            fresh.bindWriters(slot == 0 ? stranger : address(this), slot == 1 ? stranger : address(inbox));
            assertEq(fresh.hook(), address(0));
            assertEq(fresh.dataInbox(), address(0));
        }
        vm.expectEmit(true, true, false, true, address(fresh));
        emit TSVVolumeLedgerV1.WritersBound(address(this), address(inbox));
        fresh.bindWriters(address(this), address(inbox));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        fresh.bindWriters(address(this), address(inbox));
        assertEq(fresh.hook(), address(this));
        assertEq(fresh.dataInbox(), address(inbox));
    }
}

```

### test/unit/v1/reports/CapCorrections.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsCapCorrectionsTest is OperationsFixture {
    function testAdtvCorrectionClampsExistingQuotaAndPreservesConsumedVolume() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        inbox.submitAdtv(_adtv(SECURITY, 400e18, 2, 2, keccak256("lower-adtv")));
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        assertEq(ledger.quotaOf(SECURITY, DAY).quotaWad, 2e18);
        bytes32 beforeState = _reportState(keccak256("unrelated"));
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _charge(1);
        assertEq(_reportState(keccak256("unrelated")), beforeState);
        inbox.submitAdtv(_adtv(SECURITY, 2000e18, 3, 3, keccak256("raise-adtv")));
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1e18); // Quota 2, not the raised hard cap 5.
        inbox.submitQuota(_quota(0, 2, 2, 2, keccak256("clear")));
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 4e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }

    function testTierPolicyCorrectionImmediatelyChangesCapWithoutResettingUsedOrQuota() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        registry.setTierPolicy(1, 5, 10, keccak256("lower-tier-policy"));
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _charge(1);
        registry.setTierPolicy(1, 100, 10, keccak256("raise-tier-policy"));
        (, left) = ledger.remaining(SECURITY, DAY);
        assertEq(left, 1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.quotaOf(SECURITY, DAY).version, 1);
    }

    function testAcceptedReportsDoNotExpireWithSubmissionDeadline() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        vm.warp(block.timestamp + 101);
        _charge(1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1e18);
    }

    function testFuzzHardCapUsesFloorAndExactLimitIsAllowed(uint192 adtv, uint16 bps) public {
        adtv = uint192(bound(adtv, 1, 1e24));
        bps = uint16(bound(bps, 1, 10000));
        registry.setTierPolicy(1, bps, 10, keccak256("fuzz-policy"));
        _submitAdtv(adtv);
        uint256 expected = uint256(adtv) * bps / 10000;
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertEq(valid, expected != 0);
        assertEq(left, expected);
        if (expected == 0) {
            vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
            _charge(1);
        } else {
            _charge(expected);
            assertEq(ledger.used(SECURITY, DAY), expected);
            vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
            _charge(1);
            assertEq(ledger.used(SECURITY, DAY), expected);
        }
    }

    function testFutureDayQuotaDoesNotChangeCurrentDayAndRequiresApplicableMonth() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        QuotaReport memory r = _quota(1e18, 1, 1, 1, keccak256("future-quota"));
        r.tradeDayId = 20261002;
        inbox.submitQuota(r);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1.5e18);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 1e18);
        (valid, left) = ledger.remaining(SECURITY, 20261101);
        assertFalse(valid);
        assertEq(left, 0);
        AdtvReport memory nextMonth = _adtv(SECURITY, 1000e18, 1, 2, keccak256("next-adtv"));
        nextMonth.sourceMonth = 202610;
        inbox.submitAdtv(nextMonth);
        (valid, left) = ledger.remaining(SECURITY, 20261101);
        assertTrue(valid);
        assertEq(left, 2.5e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
    }
}

```

### test/unit/v1/reports/SplitFactor.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {SplitFactorFixture} from "../../../helpers/v1/SplitFactorFixture.sol";

/// @dev Default, activation, source-month basis, ordering and cancellation behavior.
contract TSVSplitFactorTest is SplitFactorFixture {
    function testDefaultFactorKeepsExistingAdtvTierAndMissingReportRules() public {
        _assertFactor(DAY, 1, 1);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertFalse(valid);
        assertEq(left, 0);
        _submitAdtv(1000e18);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 0);
        assertEq(ledger.splitFactorVersion(SECURITY, uint32(MONTH)), 0);
    }

    function testSplitActivatesExactlyAtDayStartWithoutAnotherTransactionAndKeepsOldUsed() public {
        _submitAdtv(1000e18);
        _charge(1e18);
        _setFactor(20261002, 2, 1, 1, 1);
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        (, uint32 day) = ledger.currentTradeDay();
        assertEq(day, DAY);
        (, uint256 left) = ledger.remaining(SECURITY, day);
        assertEq(left, 1.5e18);
        vm.warp(start);
        (, day) = ledger.currentTradeDay();
        assertEq(day, 20261002);
        (, left) = ledger.remaining(SECURITY, day);
        assertEq(left, 5e18);
        assertEq(ledger.used(SECURITY, day), 0);
        _charge(5e18);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, day));
        _charge(1);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).value, 1000e18);
        assertEq(inbox.lastSequence(3, SECURITY), 1); // Warp/query/Swap do not activate through another report.
    }

    function testReverseSplitUsesAnExactFractionAndCanReduceTheCapToZero() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 10, 1, 1);
        _assertFactor(20261002, 1, 5);
        vm.warp(ledger.dayStartUTC(20261002));
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 5e17);
        _charge(5e17);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, 20261002));
        _charge(1);

        _setFactor(20261003, 1, type(uint128).max, 2, 2);
        vm.warp(ledger.dayStartUTC(20261003));
        (bool valid, uint256 zeroCap) = ledger.remaining(SECURITY, 20261003);
        assertFalse(valid);
        assertEq(zeroCap, 0);
        vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
        _charge(1);
    }

    function testSeveralAbsoluteFactorsUseTheLatestApplicableCheckpointInsteadOfMultiplyingAgain() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1, 1);
        _setFactor(20261005, 6, 1, 2, 2); // Two-for-one followed by three-for-one = absolute six.
        _setFactor(20261009, 6, 5, 3, 3);
        _setFactor(20261010, 1, 1, 4, 4);
        for (uint32 date = DAY; date <= 20261031; ++date) {
            uint128 numerator = date < 20261002 ? 1 : date < 20261005 ? 2 : date < 20261010 ? 6 : 1;
            uint128 denominator = date == 20261009 ? 5 : 1;
            _assertFactor(date, numerator, denominator);
            (, uint256 left) = ledger.remaining(SECURITY, date);
            assertEq(left, uint256(25e17) * numerator / denominator);
        }
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 4);
    }

    function testNewAdtvSourceMonthStartsAtOneAndDoesNotApplyPreviousMonthsSplitAgain() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1, 1);
        AdtvReport memory next = _adtv(SECURITY, 2000e18, 1, 2, keccak256("new-month-basis"));
        next.sourceMonth = 202610;
        inbox.submitAdtv(next);
        _assertFactor(20261031, 2, 1);
        _assertFactor(20261101, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261101);
        assertEq(left, 5e18); // October ADTV is already in October's closing units.
        _setFactor(20261105, 1, 5, 1, 2);
        _assertFactor(20261105, 1, 5);
        (, left) = ledger.remaining(SECURITY, 20261105);
        assertEq(left, 1e18);
        assertEq(ledger.splitFactorVersion(SECURITY, 202609), 1);
        assertEq(ledger.splitFactorVersion(SECURITY, 202610), 1);
        assertEq(inbox.lastSequence(3, SECURITY), 2); // Report stream sequence does not restart each month.
    }

    function testFactorsAreIndependentAcrossSecurities() public {
        bytes32 second = keccak256("SEC_FACTOR_B");
        _admitAdditionalSecurity(second, keccak256("FACTOR_B"));
        _submitAdtv(1000e18);
        inbox.submitAdtv(_adtv(second, 1000e18, 1, 1, keccak256("second-adtv")));
        _setFactor(20261002, 2, 1, 1, 1);
        SplitFactorReport memory other = _factor(20261002, 3, 1, 1, 1, keccak256("second-factor"));
        other.securityId = second;
        inbox.submitSplitFactor(other);
        (, uint256 firstLeft) = ledger.remaining(SECURITY, 20261002);
        (, uint256 secondLeft) = ledger.remaining(second, 20261002);
        assertEq(firstLeft, 5e18);
        assertEq(secondLeft, 7.5e18);
    }

    function testFactorCanBeScheduledBeforeMonthlyReportButDoesNotSubstituteForMissingAdtv() public {
        _setFactor(20261002, 2, 1, 1, 1);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertFalse(valid);
        assertEq(left, 0);
        vm.warp(ledger.dayStartUTC(20261002));
        vm.expectRevert(TSVVolumeLedgerV1.MissingReport.selector);
        _charge(1);
        _submitAdtv(1000e18);
        (valid, left) = ledger.remaining(SECURITY, 20261002);
        assertTrue(valid);
        assertEq(left, 5e18);
    }

    function testOnlyLatestPendingCheckpointCanBeCorrectedAndItsOldReportRemainsConsumed() public {
        _setFactor(20261002, 2, 1, 1, 1);
        _setFactor(20261005, 3, 1, 2, 2);
        bytes32 oldId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 1).reportId;
        SplitFactorReport memory earlier = _factor(20261002, 4, 1, 3, 3, keccak256("earlier-correction"));
        bytes32 beforeState = _factorState(earlier);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitSplitFactor(earlier);
        assertEq(_factorState(earlier), beforeState);
        _setFactor(20261005, 4, 2, 3, 3);
        _assertFactor(20261005, 2, 1);
        assertTrue(inbox.reportIdUsed(oldId));
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 2);
    }

    function testCancelLatestPendingFactorRestoresEarlierFactorAndVersionNeverRewinds() public {
        _setFactor(20261002, 2, 1, 1, 1);
        _setFactor(20261005, 6, 1, 2, 2);
        bytes32 oldId = ledger.splitFactorCheckpoint(SECURITY, uint32(MONTH), 1).reportId;
        _cancelFactor(20261005, 3, 3);
        _assertFactor(20261005, 2, 1);
        assertTrue(inbox.reportIdUsed(oldId));
        assertEq(ledger.splitFactorVersion(SECURITY, uint32(MONTH)), 3);
        _setFactor(20261005, 3, 1, 4, 4);
        _assertFactor(20261005, 3, 1);
        _cancelFactor(20261005, 5, 5);
        _cancelFactor(20261002, 6, 6);
        _assertFactor(20261005, 1, 1);
        assertEq(ledger.splitFactorCheckpointCount(SECURITY, uint32(MONTH)), 0);
        assertEq(ledger.splitFactorVersion(SECURITY, uint32(MONTH)), 6);
    }

    function testActivatedFactorCannotBeEditedCancelledOrReplayed() public {
        _setFactor(20261002, 2, 1, 1, 1);
        vm.warp(ledger.dayStartUTC(20261002));
        for (uint8 action = 1; action <= 2; ++action) {
            SplitFactorReport memory report = _factor(
                20261002, action == 1 ? 3 : 0, action == 1 ? 1 : 0, 2, 2, keccak256(abi.encode("locked", action))
            );
            report.action = action;
            bytes32 beforeState = _factorState(report);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitSplitFactor(report);
            assertEq(_factorState(report), beforeState);
        }
        _assertFactor(20261002, 2, 1);
        assertEq(ledger.splitFactorVersion(SECURITY, uint32(MONTH)), 1);
    }

    function testTwentyAndTwentyEightHourTransitionsActivateAtTheConfiguredDayStart() public {
        _submitAdtv(1000e18);
        for (uint8 variant; variant < 2; ++variant) {
            uint256 snapshot = vm.snapshotState();
            _setFactor(20261004, 2, 1, 1, 1);
            ledger.scheduleDayStart(variant == 0 ? 0 : 28800, 20261004, keccak256("day-start"));
            uint256 start = ledger.dayStartUTC(20261004);
            vm.warp(start - 1);
            (, uint32 day) = ledger.currentTradeDay();
            assertEq(day, 20261003);
            _assertFactor(day, 1, 1);
            vm.warp(start);
            (, day) = ledger.currentTradeDay();
            assertEq(day, 20261004);
            _assertFactor(day, 2, 1);
            (, uint256 left) = ledger.remaining(SECURITY, day);
            assertEq(left, 5e18);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testQuotaRemainsAnAbsoluteTargetDayOverrideAndIsClampedByTheAdjustedHardCap() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1, 1);
        // The quota is stated in the target day's units; it is not multiplied again.
        _submitFutureQuota(20261002, 4e18, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 4e18);
        _setFactor(20261002, 1, 5, 2, 2);
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 5e17);
        vm.warp(ledger.dayStartUTC(20261002));
        _charge(5e17);
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, 20261002));
        _charge(1);
    }

    function testTierAndAdtvCorrectionsStillParticipateInTheAdjustedCap() public {
        _submitAdtv(1000e18);
        _setFactor(20261002, 2, 1, 1, 1);
        registry.setTierPolicy(1, 50, 10, keccak256("tier-correction"));
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 10e18);
        inbox.submitAdtv(_adtv(SECURITY, 2000e18, 2, 2, keccak256("same-basis-correction")));
        (, left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 20e18);
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).version, 2);
    }

    function testCapUsesOneFinalFloorInsteadOfFlooringBeforeApplyingTheFactor() public {
        registry.setTierPolicy(1, 5000, 10, keccak256("half"));
        _submitAdtv(3);
        _setFactor(20261002, 2, 1, 1, 1);
        (, uint256 left) = ledger.remaining(SECURITY, 20261002);
        assertEq(left, 3); // floor(3 × 1/2 × 2), not floor(3 × 1/2) × 2.
    }

    function _submitFutureQuota(uint32 day, uint256 amount, uint64 version, uint64 sequence) private {
        // Build before setting any expectation: fixture getters must not consume a prank/expectRevert.
        bytes32 id = keccak256(abi.encode("factor-quota", day, version));
        // Reuse the unchanged quota schema.
        inbox.submitQuota(_futureQuota(day, amount, version, sequence, id));
    }

    function _futureQuota(uint32 day, uint256 amount, uint64 version, uint64 sequence, bytes32 id)
        private
        view
        returns (QuotaReport memory report)
    {
        report = _quota(amount, 1, version, sequence, id);
        report.tradeDayId = day;
    }
}

```

### test/unit/v1/reports/Ingress.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsIngressTest is OperationsFixture {
    function testEveryReportRejectsInvalidMetadataWithoutConsumingState() public {
        for (uint8 kind; kind < 3; ++kind) {
            uint256 fixture = vm.snapshotState();
            if (kind == 2) _submitAdtv(1000e18);
            ReportMetadata memory accepted = _metadata(1, 1, keccak256(abi.encode("accepted", kind)));
            _callInbox(_reportPayload(kind, accepted));
            for (uint8 fault; fault < 9; ++fault) {
                ReportMetadata memory good = _metadata(3, 2, keccak256(abi.encode("candidate", kind, fault)));
                ReportMetadata memory bad = abi.decode(abi.encode(good), (ReportMetadata));
                bytes4 expected = TSVDataInboxV1.InvalidReport.selector;
                if (fault == 0) {
                    bad.id = 0;
                } else if (fault == 1) {
                    bad.source = 0;
                } else if (fault == 2) {
                    bad.id = accepted.id;
                } else if (fault == 3) {
                    bad.sequence = 0;
                } else if (fault == 4) {
                    bad.sequence = 1;
                } else if (fault == 5) {
                    bad.timestamp = accepted.timestamp - 1;
                } else if (fault == 6) {
                    bad.timestamp = uint64(block.timestamp + 1);
                    expected = TSVDataInboxV1.Expired.selector;
                } else if (fault == 7) {
                    bad.deadline = uint64(block.timestamp - 1);
                    expected = TSVDataInboxV1.Expired.selector;
                } else {
                    bad.timestamp = type(uint64).max;
                    expected = TSVDataInboxV1.Expired.selector;
                }
                bytes32 beforeState = _reportState(bad.id);
                vm.expectRevert(expected);
                _callInbox(_reportPayload(kind, bad));
                assertEq(_reportState(bad.id), beforeState);
            }
            // Equal source time, skipped sequence numbers and deadline equality are valid.
            ReportMetadata memory next = _metadata(3, 2, keccak256(abi.encode("retry", kind)));
            next.deadline = uint64(block.timestamp);
            _callInbox(_reportPayload(kind, next));
            assertEq(inbox.lastSequence(kind, SECURITY), 3);
            assertEq(inbox.lastSourceTimestamp(kind, SECURITY), next.timestamp);
            assertTrue(inbox.reportIdUsed(next.id));
            assertTrue(vm.revertToState(fixture));
        }
    }

    function testReportRolesAreIndependentAndRevocationAppliesToEveryEntry() public {
        address haltReporter = makeAddr("halt-only");
        address volumeReporter = makeAddr("volume-only");
        bytes32 haltRole = inbox.HALT_REPORTER_ROLE();
        bytes32 volumeRole = inbox.VOLUME_ORACLE_ROLE();
        inbox.grantRole(haltRole, haltReporter);
        inbox.grantRole(volumeRole, volumeReporter);
        _submitAdtv(1000e18);
        for (uint8 kind; kind < 4; ++kind) {
            bytes memory payload;
            if (kind == 3) {
                AdtvReport[] memory reports = new AdtvReport[](1);
                reports[0] = _adtv(SECURITY, 1000e18, 2, 2, keccak256("batch-role"));
                payload = abi.encodeCall(TSVDataInboxV1.submitAdtvBatch, (reports));
            } else {
                payload = _reportPayload(
                    kind, _metadata(kind == 1 ? 2 : 1, kind == 1 ? 2 : 1, keccak256(abi.encode("role", kind)))
                );
            }
            address authorized = kind == 0 ? haltReporter : volumeReporter;
            address wrongRole = kind == 0 ? volumeReporter : haltReporter;
            bytes32 role = kind == 0 ? haltRole : volumeRole;
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(wrongRole);
            _callInbox(payload);
            inbox.revokeRole(role, authorized);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(authorized);
            _callInbox(payload);
            inbox.grantRole(role, authorized);
            uint256 snapshot = vm.snapshotState();
            vm.prank(authorized);
            _callInbox(payload);
            assertTrue(vm.revertToState(snapshot));
            vm.prank(authorized);
            inbox.renounceRole(role, authorized);
            vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
            vm.prank(authorized);
            _callInbox(payload);
            inbox.grantRole(role, authorized);
        }
    }

    function testReportIdsAreGlobalWhileOrderingIsPerKindAndSecurity() public {
        bytes32 second = keccak256("second-report-security");
        _admitAdditionalSecurity(second, keccak256("SECOND"));
        bytes32 id = keccak256("global-report-id");
        MarketReport memory market = _market(MarketAction.HALT, 10, id);
        inbox.submitMarketStatus(market);
        AdtvReport memory adtv = _adtv(second, 1000e18, 1, 1, id);
        bytes32 beforeState = _reportState(second, uint32(MONTH), DAY, id);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitAdtv(adtv);
        assertEq(_reportState(second, uint32(MONTH), DAY, id), beforeState);
        adtv.reportId = keccak256("second-adtv");
        inbox.submitAdtv(adtv);
        adtv = _adtv(SECURITY, 1000e18, 1, 1, keccak256("first-adtv"));
        inbox.submitAdtv(adtv);
        QuotaReport memory quota = _quota(2e18, 1, 1, 1, adtv.reportId);
        beforeState = _reportState(quota.reportId);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitQuota(quota);
        assertEq(_reportState(quota.reportId), beforeState);
        quota.reportId = keccak256("first-quota");
        inbox.submitQuota(quota);
        assertEq(inbox.lastSequence(0, SECURITY), 10);
        assertEq(inbox.lastSequence(1, SECURITY), 1);
        assertEq(inbox.lastSequence(1, second), 1);
        assertEq(inbox.lastSequence(2, SECURITY), 1);
    }

    function testDirectWritersCannotBypassInboxAuthorization() public {
        AdtvReport memory adtv = _adtv(SECURITY, 1000e18, 1, 1, keccak256("direct"));
        QuotaReport memory quota = _quota(2e18, 1, 1, 1, keccak256("direct-quota"));
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptAdtv(adtv);
        vm.expectRevert(TSVVolumeLedgerV1.UnauthorizedWriter.selector);
        ledger.acceptQuota(quota);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.applyMarketStatus(SECURITY, MarketAction.HALT, PauseMode.ALL, 1, keccak256("direct-market"));
        assertFalse(inbox.reportIdUsed(adtv.reportId));
        assertEq(ledger.adtvOf(SECURITY, uint32(MONTH)).version, 0);
    }
}

```

### test/unit/v1/reports/Reports.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketStatus, MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVReportsTest scenarios; inherited fixtures contain no test functions.
contract TSVReportsTest is FoundationFixture {
    /// @dev Verifies one ADTV batch can include multiple securities.
    function testAdtvBatchAcceptsMultipleSecuritiesInOneSubmission() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        _admitAdditionalSecurity(secondSecurity, keccak256("STD_y"));

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-batch-a"));
        reports[1] = _adtv(lastSecurity, 2000e18, 1, 1, keccak256("adtv-batch-b"));

        inbox.submitAdtvBatch(reports);

        TSVVolumeLedgerV1.AdtvValue memory first = ledger.adtvOf(firstSecurity, uint32(MONTH));
        TSVVolumeLedgerV1.AdtvValue memory last = ledger.adtvOf(lastSecurity, uint32(MONTH));
        assertEq(first.value, 1000e18);
        assertEq(last.value, 2000e18);
        assertEq(first.version, 1);
        assertEq(last.version, 1);
    }

    /// @dev Verifies an ADTV batch reverts atomically when one report is invalid.
    function testAdtvBatchIsAtomicWhenOneReportIsInvalid() public {
        bytes32 secondSecurity = bytes32(type(uint256).max);
        _admitAdditionalSecurity(secondSecurity, keccak256("STD_z"));

        bytes32 firstSecurity = uint256(SECURITY) < uint256(secondSecurity) ? SECURITY : secondSecurity;
        bytes32 lastSecurity = firstSecurity == SECURITY ? secondSecurity : SECURITY;
        AdtvReport[] memory reports = new AdtvReport[](2);
        reports[0] = _adtv(firstSecurity, 1000e18, 1, 1, keccak256("adtv-atomic-a"));
        // Version 2 is invalid because this security has no accepted version 1.
        reports[1] = _adtv(lastSecurity, 2000e18, 2, 1, keccak256("adtv-atomic-b"));

        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitAdtvBatch(reports);

        assertFalse(inbox.reportIdUsed(reports[0].reportId));
        assertFalse(inbox.reportIdUsed(reports[1].reportId));
        assertEq(ledger.adtvOf(firstSecurity, uint32(MONTH)).version, 0);
        assertEq(ledger.adtvOf(lastSecurity, uint32(MONTH)).version, 0);
    }

    /// @dev Verifies daily quota overrides are optional and clearing one restores the hard cap.
    function testDailyQuotaIsOptionalAndClearRestoresTheHardCap() public {
        _submitAdtv(1000e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);

        QuotaReport memory setReport = _quota(2e18, 1, 1, 1, keccak256("quota-set"));
        inbox.submitQuota(setReport);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2e18);

        QuotaReport memory clearReport = _quota(0, 2, 2, 2, keccak256("quota-clear"));
        inbox.submitQuota(clearReport);
        TSVVolumeLedgerV1.QuotaOverride memory quota = ledger.quotaOf(SECURITY, DAY);
        assertFalse(quota.active);
        assertEq(quota.version, 2);
        (valid, left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 2.5e18);
    }

    /// @dev Verifies invalid clears and above-cap quota values revert atomically.
    function testQuotaRejectsInvalidClearAndValuesAboveHardCapAtomically() public {
        _submitAdtv(1000e18);
        QuotaReport memory report = _quota(0, 2, 1, 1, keccak256("clear-without-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(0, 1, 1, 1, keccak256("zero-set"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));

        report = _quota(3e18, 1, 1, 1, keccak256("over-hard-cap"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(report);
        assertFalse(inbox.reportIdUsed(report.reportId));
        assertEq(inbox.lastSequence(2, SECURITY), 0);
    }

    /// @dev Verifies market reports do not require a heartbeat and cannot be replayed.
    function testMarketReportDoesNotNeedHeartbeatAndReplayFails() public {
        _submitMarket(MarketAction.HALT, 1, keccak256("market-1"));
        vm.warp(block.timestamp + 30 days);
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.HALTED));
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("market-2"));
        report.submitDeadline = uint64(block.timestamp + 1);
        inbox.submitMarketStatus(report);
        vm.expectRevert(TSVDataInboxV1.InvalidReport.selector);
        inbox.submitMarketStatus(report);
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.OPEN));
    }

    /// @dev Verifies report submission requires a caller with the direct reporter role.
    function testReportsRequireDirectRoleCaller() public {
        MarketReport memory report = _market(MarketAction.RESUME, 2, keccak256("unauthorized"));
        vm.prank(makeAddr("unregistered-reporter"));
        vm.expectRevert(TSVDataInboxV1.UnauthorizedReporter.selector);
        inbox.submitMarketStatus(report);
    }

    function testMarketReportsRejectNoneNoopsAndInvalidActionsAtomically() public {
        _assertMarketPause(PauseMode.NONE, true, true);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.ALL, 1, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.HALT, PauseMode.NONE, 1, TSVDataInboxV1.InvalidReport.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.NONE, 1, TSVDataInboxV1.InvalidReport.selector);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 1);
        _rejectMarketMode(MarketAction.HALT, PauseMode.TRADE, 2, TSVRegistryV1.InvalidStatus.selector);
        _rejectMarketMode(MarketAction.RESUME, PauseMode.LP, 2, TSVRegistryV1.InvalidStatus.selector);
        _assertMarketPause(PauseMode.TRADE, false, true);
        MarketReport memory report = _market(MarketAction.HALT, 2, keccak256("invalid-action"));
        bytes memory payload = abi.encodeCall(TSVDataInboxV1.submitMarketStatus, (report));
        // The action is the second ABI word after the selector. Values outside the new enum must revert.
        assembly ("memory-safe") {
            mstore(add(payload, 68), 2)
        }
        (bool success,) = address(inbox).call(payload);
        assertFalse(success);
        assertFalse(inbox.reportIdUsed(report.reportId));
        assertEq(inbox.lastSequence(0, SECURITY), 1);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 2);
        _assertMarketPause(PauseMode.NONE, true, true);
    }
}

```

### test/unit/v1/reports/StatefulOperations.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OperationsHandler} from "../../../helpers/v1/OperationsHandler.sol";

contract TSVStatefulOperationsTest is Test {
    OperationsHandler internal handler;

    function setUp() public {
        handler = new OperationsHandler();
        handler.initializeModel();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.submitAdtv.selector;
        selectors[1] = handler.submitQuota.selector;
        selectors[2] = handler.charge.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.schedule.selector;
        selectors[5] = handler.cancel.selector;
        selectors[6] = handler.toggleReporter.selector;
        selectors[7] = handler.submitFactor.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantCalendarMatchesIndependentModelAndHistoryIsStable() public view {
        handler.assertCalendarModel();
    }

    function invariantReportsCapsReplayProtectionAndUsedMatchModel() public view {
        handler.assertReportModel();
    }

    function testModelTraversesReportCorrectionsRoleFailuresAndLongShortDayChanges() public {
        handler.submitAdtv(0, 1000e18, 0);
        handler.charge(1e18);
        handler.submitQuota(0, 5e17, false, 0);
        handler.charge(1);
        handler.submitQuota(0, 0, true, 0);
        handler.submitAdtv(0, 400e18, 0);
        handler.charge(1);
        handler.toggleReporter();
        handler.submitAdtv(1, 1000e18, 0);
        handler.toggleReporter();
        handler.submitAdtv(1, 1000e18, 0);
        handler.submitAdtv(2, 1000e18, 6); // Cross-period duplicate ID.
        handler.schedule(28800, 3, false);
        handler.cancel(false);
        handler.schedule(0, 3, false);
        handler.advanceTime(3 days);
        handler.cancel(false); // Transition has started; cancellation must fail.
        handler.advanceTime(3 days);
        handler.schedule(14400, 3, false);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // November uses the already supplied October ADTV.
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // December fails closed before November ADTV arrives.
        handler.submitAdtv(2, 1000e18, 0);
        handler.charge(1);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(1); // January requires December ADTV, including across the year boundary.
        handler.submitAdtv(3, 1000e18, 0);
        handler.charge(1);
        handler.assertCalendarModel();
        handler.assertReportModel();
        assertGt(handler.successfulReports(), 0);
        assertGt(handler.rejectedReports(), 0);
        assertGt(handler.successfulCharges(), 0);
        assertGt(handler.rejectedCharges(), 0);
    }

    function testModelCombinesFutureFactorsCorrectionsCancellationsDayStartsAndMonthRollover() public {
        handler.submitAdtv(0, 1000e18, 0);
        handler.charge(1e18);
        handler.submitFactor(1, 1, 0, false, 0); // 2/1, October 2.
        handler.submitFactor(4, 5, 0, false, 0); // 6/1, October 5.
        handler.submitFactor(1, 2, 0, false, 0); // Cannot correct an intermediate checkpoint.
        handler.submitFactor(4, 0, 0, true, 0);
        handler.schedule(28800, 3, false);
        handler.advanceTime(1 days);
        handler.submitFactor(1, 0, 0, true, 0); // Activated checkpoint is locked.
        handler.charge(3e18);
        handler.submitQuota(1, 4e18, false, 0);
        handler.charge(2e18); // Absolute quota 4, not automatically doubled to 8.
        handler.submitFactor(4, 0, 4, false, 0); // Reverse split 1/5.
        handler.toggleReporter();
        handler.submitFactor(5, 2, 0, false, 0);
        handler.toggleReporter();
        handler.submitFactor(5, 2, 0, false, 6); // Replay a report ID across streams.
        handler.advanceTime(4 days);
        handler.charge(5e17);
        handler.submitAdtv(1, 2000e18, 0);
        handler.advanceTime(20 days);
        handler.advanceTime(10 days);
        handler.charge(3e18); // November uses a new ADTV basis and default factor 1.
        handler.assertCalendarModel();
        handler.assertReportModel();
    }
}

```

### test/unit/v1/reports/TradeDay.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVTradeDayTest scenarios; inherited fixtures contain no test functions.
contract TSVTradeDayTest is FoundationFixture {
    /// @dev Verifies automatic trade-day calculations use Gregorian dates and the previous month.
    function testAutomaticTradeDayUsesGregorianDatesAndPreviousMonth() public {
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, DAY);
        assertEq(ledger.dayStartUTC(DAY), 1_790_827_200);
        assertEq(ledger.dayStartUTC(20280229), ledger.dayStartUTC(20280228) + 86_400);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.dayStartUTC(20260229);
    }

    /// @dev Verifies a day-start change schedules the transition and locks at its start.
    function testDayStartScheduleCreatesLongTransitionAndLocksAtTransitionStart() public {
        uint32 effectiveDay = 20261004;
        uint64 oldTransitionStart = ledger.dayStartUTC(20261003);
        ledger.scheduleDayStart(28_800, effectiveDay, keccak256("offset-change"));
        assertEq(ledger.dayStartCheckpointCount(), 1);
        TSVVolumeLedgerV1.DayStartCheckpoint memory checkpoint = ledger.dayStartCheckpoint(0);
        assertEq(checkpoint.effectiveDayId, effectiveDay);
        assertEq(checkpoint.offsetSeconds, 28_800);
        assertEq(ledger.dayStartUTC(effectiveDay) - oldTransitionStart, 100_800);
        vm.warp(oldTransitionStart);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.cancelPendingDayStart(keccak256("too-late"));
        (bool exists, uint32 day) = ledger.currentTradeDay();
        assertTrue(exists);
        assertEq(day, 20261003);
        uint64 effectiveStart = ledger.dayStartUTC(effectiveDay);
        vm.warp(effectiveStart - 1);
        (, day) = ledger.currentTradeDay();
        assertEq(day, 20261003);
        vm.warp(effectiveStart);
        (, day) = ledger.currentTradeDay();
        assertEq(day, effectiveDay);
    }

    /// @dev Verifies a day-start change can be cancelled before transition without retaining a checkpoint.
    function testDayStartCanBeCancelledBeforeTransitionWithoutRetainingCheckpoint() public {
        ledger.scheduleDayStart(3_600, 20261004, keccak256("offset-change"));
        ledger.cancelPendingDayStart(keccak256("cancel-change"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
        assertEq(ledger.dayStartUTC(20261004), ledger.dayStartUTC(20261001) + 3 * 86_400);
    }

    /// @dev Verifies another day-start change can be scheduled after the prior checkpoint takes effect.
    function testCanScheduleAnotherDayStartAfterPriorCheckpointTakesEffect() public {
        ledger.scheduleDayStart(20_000, 20261004, keccak256("first-change"));
        vm.warp(ledger.dayStartUTC(20261004));
        ledger.scheduleDayStart(14_400, 20261010, keccak256("second-change"));
        assertEq(ledger.dayStartCheckpointCount(), 2);
        assertEq(ledger.dayStartUTC(20261009), ledger.dayStartUTC(20261001) + 8 * 86_400 + 5_600);
        assertEq(ledger.dayStartUTC(20261010), ledger.dayStartUTC(20261001) + 9 * 86_400);
        assertEq(ledger.dayStartUTC(20261010) - ledger.dayStartUTC(20261009), 80_800);
    }

    /// @dev Verifies day-start scheduling rejects past boundaries, invalid dates, and shifts above four hours.
    function testDayStartRejectsPastBoundaryInvalidDateAndShiftAboveFourHours() public {
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20261002, keccak256("past-transition"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(28_801, 20261004, keccak256("too-large-shift"));
        vm.expectRevert(TSVVolumeLedgerV1.InvalidPeriod.selector);
        ledger.scheduleDayStart(18_000, 20260229, keccak256("invalid-date"));
        assertEq(ledger.dayStartCheckpointCount(), 0);
    }
}

```

### test/unit/v1/reports/PayloadValidation.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {OperationsFixture} from "../../../helpers/v1/OperationsFixture.sol";

contract TSVOperationsPayloadTest is OperationsFixture {
    function testMarketFieldsRejectAndSameIdCanBeCorrected() public {
        for (uint8 fault; fault < 6; ++fault) {
            uint256 snapshot = vm.snapshotState();
            MarketReport memory r = _market(MarketAction.HALT, 1, keccak256(abi.encode("market-field", fault)));
            bytes32 id = r.reportId;
            bytes4 expected = TSVDataInboxV1.InvalidReport.selector;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.mode = PauseMode.NONE;
            } else if (fault == 2) {
                r.reasonCode = 0;
            } else if (fault == 3) {
                r.exchangeHash = 0;
            } else {
                expected = TSVRegistryV1.InvalidStatus.selector;
                if (fault == 4) {
                    r.securityId = keccak256("absent");
                } else {
                    registry.disablePool(poolId, keccak256("disable"));
                    registry.delistSecurity(SECURITY, keccak256("delist"));
                }
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, uint32(MONTH), DAY, id);
            vm.expectRevert(expected);
            inbox.submitMarketStatus(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, uint32(MONTH), DAY, id), targetBefore);
            if (fault == 5) registry.relistSecurity(SECURITY, keccak256("relist"));
            r = _market(MarketAction.HALT, 1, id);
            inbox.submitMarketStatus(r);
            assertTrue(inbox.reportIdUsed(id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testAdtvFieldsRejectAndSameIdCanBeCorrected() public {
        uint32[5] memory invalidMonths = [uint32(0), 196912, 202600, 202613, 1000001];
        for (uint8 fault; fault < 11; ++fault) {
            uint256 snapshot = vm.snapshotState();
            AdtvReport memory r = _adtv(SECURITY, 1000e18, 1, 1, keccak256(abi.encode("adtv-field", fault)));
            bytes32 id = r.reportId;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.securityId = keccak256("absent");
            } else if (fault == 2) {
                r.adtvWad = 0;
            } else if (fault == 3) {
                r.version = 0;
            } else if (fault == 4) {
                r.version = 2;
            } else if (fault < 10) {
                r.sourceMonth = invalidMonths[fault - 5];
            } else {
                registry.disablePool(poolId, keccak256("disable"));
                registry.delistSecurity(SECURITY, keccak256("delist"));
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, r.sourceMonth, DAY, id);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitAdtv(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, r.sourceMonth, DAY, id), targetBefore);
            if (fault == 10) registry.relistSecurity(SECURITY, keccak256("relist"));
            inbox.submitAdtv(_adtv(SECURITY, 1000e18, 1, 1, id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testQuotaFieldsRejectAndSameIdCanBeCorrected() public {
        _submitAdtv(1000e18);
        for (uint8 fault; fault < 12; ++fault) {
            uint256 snapshot = vm.snapshotState();
            QuotaReport memory r = _quota(2e18, 1, 1, 1, keccak256(abi.encode("quota-field", fault)));
            bytes32 id = r.reportId;
            bytes4 expected = TSVVolumeLedgerV1.InvalidReport.selector;
            if (fault == 0) {
                r.securityId = 0;
            } else if (fault == 1) {
                r.securityId = keccak256("absent");
            } else if (fault == 2) {
                r.action = 0;
            } else if (fault == 3) {
                r.action = 3;
            } else if (fault == 4) {
                r.quotaWad = 0;
            } else if (fault == 5) {
                r.quotaWad = 2.5e18 + 1;
            } else if (fault == 6) {
                r.version = 0;
            } else if (fault == 7) {
                r.version = 2;
            } else if (fault == 8) {
                r.tradeDayId = 20261101;
                expected = TSVVolumeLedgerV1.InvalidReport.selector;
            } else if (fault == 9) {
                r.tradeDayId = 20260229;
                expected = TSVVolumeLedgerV1.InvalidPeriod.selector;
            } else if (fault == 10) {
                r.action = 2; // CLEAR without an active SET, even with nonzero amount.
            } else {
                registry.disablePool(poolId, keccak256("disable"));
                registry.delistSecurity(SECURITY, keccak256("delist"));
            }
            bytes32 beforeState = _reportState(id);
            bytes32 targetBefore = _reportState(r.securityId, uint32(MONTH), r.tradeDayId, id);
            vm.expectRevert(expected);
            inbox.submitQuota(r);
            assertEq(_reportState(id), beforeState);
            assertEq(_reportState(r.securityId, uint32(MONTH), r.tradeDayId, id), targetBefore);
            if (fault == 11) registry.relistSecurity(SECURITY, keccak256("relist"));
            inbox.submitQuota(_quota(2e18, 1, 1, 1, id));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testCorrectionsRequireNextVersionButStreamsContinueAcrossPeriods() public {
        _submitAdtv(1000e18);
        AdtvReport memory correction = _adtv(SECURITY, 500e18, 1, 2, keccak256("correction"));
        for (uint64 version; version < 4; ++version) {
            if (version == 2) continue;
            correction.version = version;
            bytes32 beforeState = _reportState(correction.reportId);
            vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
            inbox.submitAdtv(correction);
            assertEq(_reportState(correction.reportId), beforeState);
        }
        correction.version = 2;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.AdtvAccepted(SECURITY, uint32(MONTH), 500e18, 2, correction.reportId);
        inbox.submitAdtv(correction);
        AdtvReport memory nextMonth = _adtv(SECURITY, 500e18, 1, 3, keccak256("next-month"));
        nextMonth.sourceMonth = 202610;
        inbox.submitAdtv(nextMonth);
        assertEq(ledger.adtvOf(SECURITY, 202609).version, 2);
        assertEq(ledger.adtvOf(SECURITY, 202610).version, 1);
        assertEq(inbox.lastSequence(1, SECURITY), 3);
        // A fresh ID/version may report the same positive value; value equality is not replay protection.
        nextMonth.version = 2;
        nextMonth.sequence = 4;
        nextMonth.reportId = keccak256("same-value-new-version");
        inbox.submitAdtv(nextMonth);
        assertEq(ledger.adtvOf(SECURITY, 202610).value, 500e18);
    }

    function testQuotaClearMustBeZeroAndKeepsVersionAndUsage() public {
        _submitAdtv(1000e18);
        _submitQuota(2e18);
        _charge(1e18);
        QuotaReport memory r = _quota(1, 2, 2, 2, keccak256("clear"));
        bytes32 beforeState = _reportState(r.reportId);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(r);
        assertEq(_reportState(r.reportId), beforeState);
        r.quotaWad = 0;
        vm.expectEmit(true, true, true, true, address(ledger));
        emit TSVVolumeLedgerV1.QuotaAccepted(SECURITY, DAY, 2, 0, 2, r.reportId);
        inbox.submitQuota(r);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.quotaOf(SECURITY, DAY).version, 2);
        assertFalse(ledger.quotaOf(SECURITY, DAY).active);
        r.version = 3;
        r.sequence = 3;
        r.reportId = keccak256("second-clear");
        beforeState = _reportState(r.reportId);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidReport.selector);
        inbox.submitQuota(r);
        assertEq(_reportState(r.reportId), beforeState);
        r.action = 1;
        r.quotaWad = 1.5e18;
        inbox.submitQuota(r);
        assertEq(ledger.quotaOf(SECURITY, DAY).version, 3);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 0.5e18);
    }
}

```

### test/integration/xlayer/deployment.json — TEST SCENARIO COVERAGE ONLY

```json
{
  "chainId": 196,
  "block": 72271000,
  "blockHash": "0x166268472881348e8a50763787b5447abec2949c21855cc139f64365143e2dbd",
  "rpc": "https://rpc.xlayer.tech",
  "router": "0x7c5bee2a8091c3ef39072f64f18fac913060aeaf",
  "version": "v1.0.10-rfq-anti-arbitrage",
  "abiSource": "https://github.com/okxlabs/Web3-DEX-Router-EVM-V1/tree/1fc1508df3caeb18a8179dfc0ea4e956099ab481",
  "contracts": [
    {
      "address": "0x7c5bee2a8091c3ef39072f64f18fac913060aeaf",
      "codehash": "0x7766cf8785ca58e8da2204bf28f5b5cb2da420e1dbad4f5b88828a7c768da885",
      "kind": "router"
    },
    {
      "address": "0x6960308951bdb3ec525f909fbfef5b878dc706ac",
      "codehash": "0xc06ecb2112462d9e226af6241fe6b4ae4df4949c9ed942c398acc8da4633b6bb",
      "kind": "execution module"
    },
    {
      "address": "0xe508a5bf6d01059ff08a5c6176cd7bb4c5d8b981",
      "codehash": "0x0e380751e312aaef6cab5ef5fbbf7d0d95c2815accd37017d886d55366caabb4",
      "kind": "execution module"
    },
    {
      "address": "0x0d3aaedce40e2fec55f89c5f488d88e51dadf394",
      "codehash": "0x13503fbaed37543dd22481ffa645e59cffaa5f59197df3d95da849ab191a9525",
      "kind": "execution module"
    },
    {
      "address": "0xd68d266765dc4709ee3245ea26a8000c8de9a63c",
      "codehash": "0x68d976d471d08596d99fc2c734383ce9325108fd95160e7f030306263f80fcf5",
      "kind": "execution module"
    },
    {
      "address": "0xf4f2d082546e6be6da334e7e9af45ce8b440495c",
      "codehash": "0x56e6889837edf83566f6eb7bc9be7f88cf3ca10218c6506c9fc823a7e61957a4",
      "kind": "execution module"
    },
    {
      "address": "0xfad6a9eee5b32e9b81bb217baef37742b2ca5b83",
      "codehash": "0x09df377864a9c2e1adeae0ff142297ddfd99e6464861e45b0c7716253d5f0c4f",
      "kind": "approval proxy"
    },
    {
      "address": "0x8b773d83bc66be128c60e07e17c8901f7a64f000",
      "codehash": "0x69c96ed2d046e83e322c31cbc8c0943dbad47bc7cc31d1f8760921c47b0d7671",
      "kind": "token approval"
    }
  ]
}

```

### test/integration/xlayer/README.md — TEST SCENARIO COVERAGE ONLY

```md
# X Layer 固定区块 DEX 流程

运行 `make test-xlayer`，默认连接 [官方公开 RPC](https://web3.okx.com/onchainos/dev-docs/xlayer/developer/rpc-endpoints/rpc-endpoints) `https://rpc.xlayer.tech`；可用环境变量 `XLAYER_RPC_URL` 指定同链 archive RPC。固定区块 **72,271,000**、chainId **196**，不随 latest 自动移动。

`DexRouterFlow.t.sol` 使用链上真实入口 `0x7c5bee2a8091c3ef39072f64f18fac913060aeaf`、执行模块、TokenApproveProxy 与 TokenApprove。部署清单固定八个依赖的 codehash；测试校验版本、授权关系及链/区块。未改写这些合约代码、白名单或管理员状态；无需生产账户签名。

流程为：测试用户 approve 链上 TokenApprove → 链上 DEX 转入测试 Adapter → Adapter 从 DEX 追加的认证标记取得原始交易者 → TSV Router 校验该身份的 SBT → Hook/V4 交换、精确结算与额度记账 → 输出交付、未使用输入退款。多跳中间资金先返回 DEX，下一跳仍按原始交易者身份检查。

11 项覆盖：双向单跳、拆单、跨两池/两股票 Currency 的多跳、指定收款人、合约钱包身份、不能借用持证 tx.origin、DEX 最低输出失败全回滚、部分成交退款、Adapter 撤权/交易暂停、交易与 LP 完整生命周期、部署依赖校验。成功后测试 Token 在 DEX、Adapter、TSV Router/LP Manager 无本笔残留，Adapter 对 TSV Router 的授权归零。

边界：DEX 和授权组件是真实链上实例；TSV 六组件及真实 V4 PoolManager 在 fork 内新建，股票/Wrapped/SBT 使用行为 mock。此套件证明 DEX→TSV 的集成流程，不代表真实发行方资产、生产 SBT、生产 TSV 部署或多签已经验收，也不覆盖 DEX 自身全部协议、native/permit/佣金/RFQ 路径。正式 Adapter 尚未作为生产合约交付。

默认 `make test` 运行不联网的 unit/local；fork 由独立 xlayer profile 执行。RPC 缺失、错链、代码哈希不符或流程失败会直接失败，不自动 skip。

```

### test/integration/xlayer/DexRouterFlow.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerWrapped} from "../../helpers/v1/MockIssuerTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {IDexRouter, IDexApproveProxy} from "../../../lib/dexrouter-interfaces/IDexRouter.sol";
import {ProtocolFixture} from "../../helpers/v1/ProtocolFixture.sol";
import {DexRouterTestAdapter, DexRouterTestWallet} from "../../helpers/v1/DexRouterTestAdapter.sol";

/// @dev Actual deployed DEX and approval contracts; TSV/V4/issuer/SBT fixtures are deployed on the fork.
///      No router etching, approval-list mutation, production-admin impersonation, or skip fallback.
contract TSVXLayerDexRouterTest is ProtocolFixture {
    struct ContractPin {
        address deployed;
        bytes32 codehash;
        string kind;
    }
    uint256 internal constant FORK_BLOCK = 72_271_000;
    address internal constant DEX = 0x7c5bEE2a8091C3ef39072f64F18Fac913060AEaF;
    bytes32 internal constant DEX_CODEHASH = 0x7766cf8785ca58e8da2204bf28f5b5cb2da420e1dbad4f5b88828a7c768da885;
    IDexRouter internal dex;
    DexRouterTestAdapter internal adapter;
    address internal approveProxy;
    address internal tokenApprove;

    function setUp() public override {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        assertEq(block.chainid, 196, "wrong fork chain");
        assertEq(DEX.codehash, DEX_CODEHASH, "deployed DEX changed");
        _assertDeploymentPins();
        dex = IDexRouter(DEX);
        assertEq(dex.version(), "v1.0.10-rfq-anti-arbitrage");
        // Approval proxy recovered from the pinned on-chain DAG execution module.
        approveProxy = address(uint160(0xfAd6a9eEe5b32E9B81bb217BaeF37742B2ca5B83));
        tokenApprove = IDexApproveProxy(approveProxy).tokenApprove();
        assertTrue(IDexApproveProxy(approveProxy).isAllowedProxy(DEX), "DEX not authorized by approval proxy");
        assertGt(tokenApprove.code.length, 0);
        super.setUp();
        adapter = new DexRouterTestAdapter(DEX, router);
        router.setAdapterAllowed(address(adapter), true);
        vm.startPrank(alice);
        stock.approve(tokenApprove, type(uint256).max);
        quote.approve(tokenApprove, type(uint256).max);
        vm.stopPrank();
    }

    function testPinnedDeploymentAndApprovalContractsAreReal() public view {
        assertEq(block.number, FORK_BLOCK);
        assertEq(DEX.codehash, DEX_CODEHASH);
        assertTrue(IDexApproveProxy(approveProxy).isAllowedProxy(DEX));
        assertGt(approveProxy.code.length, 0);
        assertGt(tokenApprove.code.length, 0);
    }

    function testFullDexRouteBothDirectionsSettlesAndAccountsActualDeltas() public {
        _trade(alice, true, 1e18, alice);
        _trade(alice, false, 1e18, alice);
    }

    function testDexSplitRouteExecutesEachLegAndAccountsTheirSum() public {
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(direction, 1e18);
        IDexRouter.RouterPath memory split = paths[0];
        split.mixAdapters = new address[](2);
        split.assetTo = new address[](2);
        split.rawData = new uint256[](2);
        split.extraData = new bytes[](2);
        for (uint256 i; i < 2; i++) {
            split.mixAdapters[i] = address(adapter);
            split.assetTo[i] = address(adapter);
            split.rawData[i] = uint256(uint160(address(router))) | (uint256(5000) << 160) | (uint256(1) << 176)
                | (direction ? 0 : uint256(1) << 255);
            split.extraData[i] = abi.encode(_swapRequest(direction, 5e17));
        }
        paths[0] = split;
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        assertGt(dex.dagSwapByOrderId(48, base, paths), 0);
        assertEq(beforeStock - stock.balanceOf(alice), 1e18);
        assertEq(ledger.used(SECURITY, DAY) - beforeUsed, 1e18);
        _assertNoTransitBalances();
    }

    function testDexTwoHopRouteUsesOriginalParticipantAndCountsEveryStockLeg() public {
        V1MockIssuerWrapped finalStock = new V1MockIssuerWrapped(stockUnderlying);
        BackedAutoFeeLegalShareAdapter legalAdapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(finalStock), 1);
        registry.registerToken(_config(address(finalStock), SECURITY, address(legalAdapter)), keccak256("second-stock"));
        PoolKey memory finalKey = PoolKey(
            Currency.wrap(address(finalStock) < address(quote) ? address(finalStock) : address(quote)),
            Currency.wrap(address(finalStock) < address(quote) ? address(quote) : address(finalStock)),
            3000,
            60,
            IHooks(address(hook))
        );
        lpManager.initializePool(finalKey, uint160(1 << 96), keccak256("second-hop-price"));
        finalStock.mintTestShares(alice, 1e24);
        vm.startPrank(alice);
        finalStock.approve(address(lpManager), type(uint256).max);
        lpManager.openPosition(finalKey, -600, 600, 1e20, _pauseTestBounds());
        vm.stopPrank();
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        (, uint256 intermediateAmount) = router.swapExactInput(_swapRequest(direction, 1e18));
        vm.revertToState(snapshot);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory first) = _route(direction, 1e18);
        (, IDexRouter.RouterPath[] memory second) = _route(!direction, uint128(intermediateAmount));
        IDexRouter.RouterPath[] memory paths = new IDexRouter.RouterPath[](2);
        paths[0] = first[0];
        paths[1] = second[0];
        bool finalDirection = Currency.unwrap(finalKey.currency0) == address(quote);
        SwapRequest memory finalRequest = _swapRequest(finalDirection, uint128(intermediateAmount));
        finalRequest.key = finalKey;
        paths[1].extraData[0] = abi.encode(finalRequest);
        // First edge 0->1 settles to the DEX; second edge 1->2 delivers to the original caller.
        paths[1].rawData[0] = uint256(uint160(address(router))) | (uint256(10_000) << 160) | (uint256(1) << 184)
            | (uint256(2) << 176) | (finalDirection ? 0 : uint256(1) << 255);
        base.toToken = address(finalStock);
        uint256 beforeStock = stock.balanceOf(alice);
        uint256 beforeFinalStock = finalStock.balanceOf(alice);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        uint256 finalOutput = dex.dagSwapByOrderId(49, base, paths);
        assertGt(finalOutput, 0);
        assertEq(adapter.lastParticipant(), alice);
        assertEq(beforeStock - stock.balanceOf(alice), 1e18);
        assertEq(finalStock.balanceOf(alice) - beforeFinalStock, finalOutput);
        assertEq(ledger.used(SECURITY, DAY) - beforeUsed, 1e18 + finalOutput);
        _assertNoTransitBalances();
        assertEq(finalStock.balanceOf(DEX), 0);
        assertEq(finalStock.balanceOf(address(adapter)), 0);
        assertEq(finalStock.balanceOf(address(router)), 0);
    }

    function testDexExplicitReceiverPreservesOriginalParticipant() public {
        address recipient = makeAddr("recipient-without-sbt");
        assertFalse(registry.isEligible(recipient));
        _trade(alice, true, 1e18, recipient);
        assertEq(adapter.lastParticipant(), alice);
    }

    function testContractWalletMarkerUsesWalletInsteadOfTransactionOrigin() public {
        DexRouterTestWallet wallet = new DexRouterTestWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.execute(address(stock), abi.encodeCall(IERC20.approve, (tokenApprove, type(uint256).max)));
        wallet.execute(address(quote), abi.encodeCall(IERC20.approve, (tokenApprove, type(uint256).max)));
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        assertFalse(registry.isEligible(address(this)));
        wallet.execute(DEX, abi.encodeCall(IDexRouter.dagSwapByOrderId, (42, base, paths)));
        assertEq(adapter.lastParticipant(), address(wallet));
        assertGt(adapter.lastActualOut(), 0);
        _assertNoTransitBalances();
    }

    function testIneligibleDexCallerCannotBorrowEligibleOrigin() public {
        sbt.setHolder(alice, false);
        address origin = makeAddr("eligible-origin");
        sbt.setHolder(origin, true);
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(alice, origin);
        dex.dagSwapByOrderId(43, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        _assertNoTransitBalances();
    }

    function testDexGlobalMinReturnFailureRevertsTransfersPoolQuotaAndAdapterWrites() public {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        base.minReturnAmount = type(uint128).max;
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert();
        vm.prank(alice);
        dex.dagSwapByOrderId(44, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        assertEq(adapter.lastParticipant(), address(0));
        _assertNoTransitBalances();
        _trade(alice, true, 1e18, alice);
    }

    function testPartialFillRefundsUnusedInputToAuthenticatedParticipant() public {
        _trade(alice, address(stock) == Currency.unwrap(key.currency0), 1e22, alice);
        assertLt(adapter.lastActualIn(), 1e22);
        assertGt(adapter.lastActualIn(), 0);
        _assertNoTransitBalances();
    }

    function testAdapterRevocationAndTradingPauseRevertDexFundingAtomically() public {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(true, 1e18);
        router.setAdapterAllowed(address(adapter), false);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        vm.prank(alice);
        dex.dagSwapByOrderId(45, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        router.setAdapterAllowed(address(adapter), true);
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        dex.dagSwapByOrderId(46, base, paths);
        assertEq(_swapStateDigest(DAY), beforeState);
        _assertNoTransitBalances();
    }

    function testFullDexSwapAndLPLifecycleSharesPoolWithoutCountingLiquidityAsVolume() public {
        vm.prank(alice);
        uint256 id = lpManager.openPosition(key, -600, 600, 1e19, _pauseTestBounds());
        vm.prank(alice);
        lpManager.increaseLiquidity(id, 1e18, _pauseTestBounds());
        _trade(alice, true, 1e18, alice);
        _trade(alice, false, 1e18, alice);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        lpManager.collectFees(id, _pauseTestBounds());
        lpManager.decreaseLiquidity(id, 1e18, _pauseTestBounds());
        lpManager.closePosition(id, _pauseTestBounds());
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertFalse(lpManager.getPosition(id).active);
        _assertNoTransitBalances();
    }

    function _route(bool direction, uint128 amount)
        internal
        view
        returns (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths)
    {
        SwapRequest memory request = _swapRequest(direction, amount);
        address input = Currency.unwrap(direction ? key.currency0 : key.currency1);
        address output = Currency.unwrap(direction ? key.currency1 : key.currency0);
        base = IDexRouter.BaseRequest(uint256(uint160(input)), output, amount, 1, block.timestamp + 100);
        paths = new IDexRouter.RouterPath[](1);
        paths[0].mixAdapters = new address[](1);
        paths[0].assetTo = new address[](1);
        paths[0].rawData = new uint256[](1);
        paths[0].extraData = new bytes[](1);
        paths[0].mixAdapters[0] = address(adapter);
        paths[0].assetTo[0] = address(adapter);
        // DAG input index 0, output index 1, weight 10_000; bit 255 selects sellQuote.
        paths[0].rawData[0] = uint256(uint160(address(router))) | (uint256(10_000) << 160) | (uint256(1) << 176)
            | (direction ? 0 : uint256(1) << 255);
        paths[0].extraData[0] = abi.encode(request);
        paths[0].fromToken = uint256(uint160(input));
    }

    function _trade(address participant, bool direction, uint128 amount, address recipient) internal {
        (IDexRouter.BaseRequest memory base, IDexRouter.RouterPath[] memory paths) = _route(direction, amount);
        IERC20 input = IERC20(address(uint160(base.fromToken)));
        IERC20 output = IERC20(base.toToken);
        uint256 inputBefore = input.balanceOf(participant);
        uint256 outputBefore = output.balanceOf(recipient);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(participant);
        uint256 reportedOut = dex.dagSwapTo(47, recipient, base, paths);
        assertEq(adapter.lastParticipant(), participant);
        assertEq(inputBefore - input.balanceOf(participant), adapter.lastActualIn());
        assertEq(output.balanceOf(recipient) - outputBefore, adapter.lastActualOut());
        assertEq(reportedOut, adapter.lastActualOut());
        bool stockInput = address(input) == address(stock);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockInput ? adapter.lastActualIn() : adapter.lastActualOut());
        _assertNoTransitBalances();
    }

    function _assertNoTransitBalances() internal view {
        address[4] memory transit = [DEX, address(adapter), address(router), address(lpManager)];
        for (uint256 i; i < transit.length; i++) {
            assertEq(stock.balanceOf(transit[i]), 0);
            assertEq(quote.balanceOf(transit[i]), 0);
        }
        assertEq(stock.allowance(address(adapter), address(router)), 0);
        assertEq(quote.allowance(address(adapter), address(router)), 0);
    }

    function _assertDeploymentPins() internal view {
        string memory manifest = vm.readFile("test/integration/xlayer/deployment.json");
        assertEq(vm.parseJsonUint(manifest, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(manifest, ".block"), block.number);
        // JSON object keys are ABI-encoded alphabetically: address, codehash, kind.
        ContractPin[] memory pins = abi.decode(vm.parseJson(manifest, ".contracts"), (ContractPin[]));
        for (uint256 i; i < pins.length; i++) {
            assertEq(pins[i].deployed.codehash, pins[i].codehash, pins[i].kind);
        }
    }
}

```

### test/integration/governance/README.md — TEST SCENARIO COVERAGE ONLY

```md
# 实际治理账户测试扩展入口

此目录预留实际 Governor、Guardian、Council 合约账户的集成测试，当前没有生产多签演练套件。

需要提供实际多签实现/版本、部署地址、签名门槛、模块配置和受控签名账户。验证单笔/批量升级、冻结/解冻、身份恢复审批/撤回/取消、权限轮换及重放拒绝。现有 `GovernorExecutor` 仅验证合约调用路径，不能代替这些验证。

```

### test/integration/local/operations/OperationsFlows.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TokenStatus, PoolStatus, PauseScope, PauseMode, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Operations are exercised against funded positions and a real V4 PoolManager.
contract TSVOperationsFlowsLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testQuotaLoweredBelowUsedBlocksTradeAndClearRestoresCapacity() public {
        _trade(1e18);
        _setQuota(DAY, 5e17);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        _rejectTrade(DAY);
        _clearQuota(DAY);
        _trade(1e17);
        assertEq(ledger.used(SECURITY, DAY), 11e17);
    }

    function testAdtvAndTierCorrectionsClampExistingQuotaOnNextRealTrade() public {
        _setQuota(DAY, 2e18);
        _trade(1e18);
        _adtv(202609, 5e17);
        _rejectTrade(DAY);
        _adtv(202609, 5e18);
        (bool valid, uint256 left) = ledger.remaining(SECURITY, DAY);
        assertTrue(valid);
        assertEq(left, 1e18);
        registry.setTierPolicy(1, 1000, 10, keccak256("lower-tier"));
        _rejectTrade(DAY);
        registry.setTierPolicy(1, 10000, 10, keccak256("restore-tier"));
        _trade(1e17);
        assertEq(ledger.used(SECURITY, DAY), 11e17);
        assertEq(ledger.quotaOf(SECURITY, DAY).quotaWad, 2e18);
    }

    function testMovingSecurityTierChangesRealTradeCapAndPreservesExistingPosition() public {
        _trade(1e18);
        _adtv(202609, 2e18);
        registry.setTierPolicy(2, 1000, 1, keccak256("restrictive-tier"));
        bytes32 positionBefore = keccak256(abi.encode(lpManager.getPosition(positionId)));
        registry.setSecurityTier(SECURITY, 2, keccak256("move"));
        _rejectTrade(DAY);
        assertEq(keccak256(abi.encode(lpManager.getPosition(positionId))), positionBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
        registry.setSecurityTier(SECURITY, 1, keccak256("move-back"));
        _trade(1e17);
        assertEq(ledger.used(SECURITY, DAY), 11e17);
    }

    function testMonthRolloverFailsClosedUntilPreviousMonthAdtvArrivesWhileLPContinues() public {
        _trade(1e18);
        vm.warp(1793419200); // 2026-10-31 04:00 UTC.
        _trade(1e18);
        vm.warp(1793505600); // 2026-11-01 04:00 UTC.
        _rejectTrade(20261101);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        assertEq(ledger.used(SECURITY, 20261101), 0);
        _adtv(202610, 1e24);
        _trade(1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.used(SECURITY, 20261031), 1e18);
        assertEq(ledger.used(SECURITY, 20261101), 1e18);
    }

    function testTwentyAndTwentyEightHourTransitionsEachUseOneFullDailyQuota() public {
        for (uint8 variant; variant < 2; ++variant) {
            uint256 snapshot = vm.snapshotState();
            _trade(1e17);
            uint32 offset = variant == 0 ? 0 : 28800;
            ledger.scheduleDayStart(offset, 20261004, keccak256(abi.encode("transition", variant)));
            _setQuota(20261003, 1e18);
            _setQuota(20261004, 1e18);
            uint64 start = ledger.dayStartUTC(20261003);
            uint64 end = ledger.dayStartUTC(20261004);
            assertEq(end - start, variant == 0 ? 20 hours : 28 hours);
            vm.warp(start);
            _trade(8e17);
            vm.warp(end - 1);
            _rejectTrade(20261003); // 0.8 used + 0.3 requested > the same full cap.
            assertEq(ledger.used(SECURITY, 20261003), 8e17);
            vm.warp(end);
            _trade(3e17);
            assertEq(ledger.used(SECURITY, 20261004), 3e17);
            assertEq(ledger.used(SECURITY, DAY), 1e17);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testReviewedAdapterReplacementPreservesPoolPositionFeesAndUsedVolume() public {
        _trade(1e18);
        uint256 feeSnapshot = vm.snapshotState();
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        uint256 expectedStockFee = stock.balanceOf(alice) - stockBefore;
        uint256 expectedQuoteFee = quote.balanceOf(alice) - quoteBefore;
        assertGt(expectedStockFee + expectedQuoteFee, 0);
        assertTrue(vm.revertToState(feeSnapshot));
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 positionBefore = keccak256(abi.encode(lpManager.getPosition(positionId)));
        uint128 v4Before = StateLibrary.getLiquidity(manager, key.toId());
        uint256 pauseId = _pauseLocal(PauseScope.TOKEN, bytes32(uint256(uint160(address(stock)))), PauseMode.ALL);
        BackedAutoFeeLegalShareAdapter next =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        registry.replaceLegalShareAdapter(address(stock), address(next), keccak256("reviewed-policy"));
        assertEq(keccak256(abi.encode(lpManager.getPosition(positionId))), positionBefore);
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), v4Before);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(keccak256(abi.encode(registry.getPool(poolId).key)), keccak256(abi.encode(key)));
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        registry.clearEmergencyPause(pauseId, keccak256("resume"));
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(stock.balanceOf(alice) - stockBefore, expectedStockFee);
        assertEq(quote.balanceOf(alice) - quoteBefore, expectedQuoteFee);
        _trade(1e17);
        assertEq(ledger.used(SECURITY, DAY), 11e17);
        assertEq(registry.getToken(address(stock)).legalAdapterVersion, 2);
    }

    function testManualLegalUnitChangeWaitsForNextDayAndNeverRewritesHistoricalUsed() public {
        _trade(1e18);
        uint256 id = _pauseLocal(PauseScope.SECURITY, SECURITY, PauseMode.ALL);
        stockUnderlying.setMultiplier(2e18, 1);
        _rejectTrade(DAY);
        _adtv(202609, 2e24); // Approved new-unit ADTV is supplied while operations remain paused.
        _setQuota(20261002, 3e18);
        vm.warp(ledger.dayStartUTC(20261002));
        registry.clearEmergencyPause(id, keccak256("approved-new-unit"));
        _trade(1e18);
        assertEq(ledger.used(SECURITY, DAY), 1e18);
        assertEq(ledger.used(SECURITY, 20261002), 2e18);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        assertEq(ledger.used(SECURITY, 20261002), 2e18);
    }

    function testIndependentSymbolOperatorDelistsRelistsAndReopensFundedPool() public {
        address operator = makeAddr("listing-operator");
        bytes32 role = registry.SYMBOL_ADMIN_ROLE();
        registry.grantRole(role, operator);
        _trade(1e18);
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.startPrank(operator);
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        vm.stopPrank();
        _rejectTrade(DAY);
        assertTrue(lpManager.getPosition(positionId).active);
        assertEq(lpManager.ownerOf(positionId), alice);
        vm.startPrank(operator);
        registry.relistSecurity(SECURITY, keccak256("relist"));
        registry.enablePool(poolId, keccak256("reopen"));
        vm.stopPrank();
        _trade(1e17);
        assertEq(ledger.used(SECURITY, DAY), 11e17);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        assertEq(registry.tierPolicy(1).listedCount, 1);
    }

    function testPoolCreatorRoleIsRequiredAndRevocationLeavesNoPendingPool() public {
        address creator = makeAddr("pool-creator");
        bytes32 role = lpManager.POOL_CREATOR_ROLE();
        PoolKey memory candidate = key;
        candidate.fee = 500;
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, role));
        vm.prank(creator);
        lpManager.initializePool(candidate, uint160(1 << 96), keccak256("price"));
        assertFalse(registry.isKnownPool(PoolId.unwrap(candidate.toId())));
        lpManager.grantRole(role, creator);
        vm.prank(creator);
        lpManager.initializePool(candidate, uint160(1 << 96), keccak256("price"));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, candidate.toId());
        assertEq(price, uint160(1 << 96));
        lpManager.revokeRole(role, creator);
        candidate.fee = 10000;
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, role));
        vm.prank(creator);
        lpManager.initializePool(candidate, uint160(1 << 96), keccak256("price"));
        assertEq(uint8(registry.getPool(PoolId.unwrap(candidate.toId())).status), uint8(PoolStatus.ABSENT));
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
    }

    function _trade(uint128 amount) private {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, amount);
        (, uint32 day) = ledger.currentTradeDay();
        uint256 beforeUsed = ledger.used(SECURITY, day);
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice);
        (uint256 actualIn,) = router.swapExactInput(request);
        assertEq(beforeStock - stock.balanceOf(alice), actualIn);
        assertEq(actualIn, amount);
        (uint256 multiplier,,) = stockUnderlying.getCurrentMultiplier();
        assertEq(ledger.used(SECURITY, day) - beforeUsed, actualIn * multiplier / 1e18);
    }

    function _rejectTrade(uint32 day) private {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 3e17);
        bytes32 beforeState = _swapStateDigest(day);
        vm.expectRevert(); // V4 wraps Hook errors; unit suites assert individual Ledger selectors.
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
    }

    function _adtv(uint32 month, uint256 value) private {
        uint64 now_ = uint64(block.timestamp);
        uint64 version = ledger.adtvOf(SECURITY, month).version + 1;
        uint64 sequence = inbox.lastSequence(1, SECURITY) + 1;
        inbox.submitAdtv(
            AdtvReport(
                SECURITY,
                month,
                value,
                now_,
                now_ + 100,
                version,
                sequence,
                keccak256(abi.encode("ops-adtv", month, sequence)),
                keccak256("source")
            )
        );
    }

    function _setQuota(uint32 day, uint256 value) private {
        _quota(day, 1, value);
    }

    function _clearQuota(uint32 day) private {
        _quota(day, 2, 0);
    }

    function _quota(uint32 day, uint8 action, uint256 value) private {
        uint64 now_ = uint64(block.timestamp);
        uint64 version = ledger.quotaOf(SECURITY, day).version + 1;
        uint64 sequence = inbox.lastSequence(2, SECURITY) + 1;
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                day,
                action,
                value,
                now_,
                now_ + 100,
                version,
                sequence,
                keccak256(abi.encode("ops-quota", day, sequence)),
                keccak256("source")
            )
        );
    }
}

```

### test/integration/local/operations/PoolCreationBoundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVOperationsPoolCreationLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testInvalidPoolKeysPricesAndEvidenceRollBackRegistryAndV4() public {
        for (uint8 fault; fault < 13; ++fault) {
            PoolKey memory candidate = key;
            candidate.fee = 500;
            uint160 price = uint160(1 << 96);
            bytes32 evidence = keccak256("price-basis");
            if (fault == 0) {
                candidate.hooks = IHooks(address(this));
            } else if (fault == 1) {
                candidate.fee = 0x800000;
            } else if (fault == 2) {
                candidate.fee = 1000000;
            } else if (fault == 3) {
                candidate.tickSpacing = 0;
            } else if (fault == 4) {
                candidate.tickSpacing = 32768;
            } else if (fault == 5) {
                Currency tmp = candidate.currency0;
                candidate.currency0 = candidate.currency1;
                candidate.currency1 = tmp;
            } else if (fault == 6) {
                candidate.currency0 = candidate.currency1;
            } else if (fault == 7) {
                candidate.currency0 = Currency.wrap(address(0));
            } else if (fault == 8) {
                price = 0;
            } else if (fault == 9) {
                price = TickMath.MIN_SQRT_PRICE - 1;
            } else if (fault == 10) {
                price = TickMath.MAX_SQRT_PRICE;
            } else if (fault == 11) {
                evidence = 0;
            } else {
                candidate = key; // Duplicate initialization of the original funded pool.
            }
            bytes32 beforeState = _poolState(candidate);
            vm.expectRevert();
            lpManager.initializePool(candidate, price, evidence);
            assertEq(_poolState(candidate), beforeState);
        }
        PoolKey memory corrected = key;
        corrected.fee = 500;
        lpManager.initializePool(corrected, uint160(1 << 96), keccak256("corrected"));
        assertTrue(registry.isKnownPool(PoolId.unwrap(corrected.toId())));
    }

    function testValidFeeTickAndPriceBoundariesInitializeRealV4Pools() public {
        PoolKey memory low = key;
        low.fee = 0;
        low.tickSpacing = 1;
        lpManager.initializePool(low, TickMath.MIN_SQRT_PRICE, keccak256("minimum"));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, low.toId());
        assertEq(price, TickMath.MIN_SQRT_PRICE);
        PoolKey memory high = key;
        high.fee = 999999;
        high.tickSpacing = 32767;
        lpManager.initializePool(high, TickMath.MAX_SQRT_PRICE - 1, keccak256("maximum"));
        (price,,,) = StateLibrary.getSlot0(manager, high.toId());
        assertEq(price, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 3);
    }

    function _poolState(PoolKey memory candidate) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, candidate.toId());
        return keccak256(
            abi.encode(
                registry.getPool(PoolId.unwrap(candidate.toId())),
                registry.getSecurity(SECURITY),
                registry.activePoolCountByCurrency(address(stock)),
                registry.activePoolCountByCurrency(address(quote)),
                price,
                tick,
                protocolFee,
                lpFee,
                _swapStateDigest(DAY)
            )
        );
    }
}

```

### test/integration/local/operations/SplitFactorFlows.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport, QuotaReport, SplitFactorReport} from "tsv-v1/types/TSVReports.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {LedgerV2, InboxV2, GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";

/// @dev Real V4 swaps/positions demonstrate that day-start activation governs the actual quota check.
contract TSVSplitFactorFlowsLocalTest is ProtocolFixture {
    function testAdjustedCapAllowsAdditionalRealTradeOnlyOnTheNewDayAndFailureIsAtomic() public {
        _basis(202609, 40e18); // Tier 25 bps: 0.1 shares/day.
        _trade(8e16);
        _scheduleFactor(20261002, 202609, 2, 1);
        uint256 start = ledger.dayStartUTC(20261002);
        vm.warp(start - 1);
        _rejectTrade(3e16, DAY);
        assertEq(ledger.used(SECURITY, DAY), 8e16);

        vm.warp(start);
        _trade(15e16); // Greater than the old full-day cap of 0.1, below the new cap of 0.2.
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _rejectTrade(6e16, 20261002);
        assertEq(ledger.used(SECURITY, DAY), 8e16);
        assertEq(ledger.adtvOf(SECURITY, 202609).value, 40e18);
        assertEq(lpManager.ownerOf(positionId), alice);
        assertTrue(lpManager.getPosition(positionId).active);
    }

    function testReverseSplitRestrictsRealSwapWhileLPAndOwnerExitRemainAvailable() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 1, 5);
        vm.warp(ledger.dayStartUTC(20261002));
        _rejectTrade(3e16, 20261002);
        _trade(2e16); // Exact adjusted cap.
        _rejectTrade(1, 20261002);
        vm.startPrank(alice);
        lpManager.increaseLiquidity(positionId, 1e16, _pauseTestBounds());
        lpManager.closePosition(positionId, _pauseTestBounds());
        vm.stopPrank();
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(ledger.used(SECURITY, 20261002), 2e16);
    }

    function testTokenMultiplierUpdatesBeforeOrAfterDayStartDoNotSelectTheCapActivationTime() public {
        for (uint8 variant; variant < 2; ++variant) {
            uint256 snapshot = vm.snapshotState();
            _basis(202609, 40e18);
            _scheduleFactor(20261002, 202609, 2, 1);
            uint256 start = ledger.dayStartUTC(20261002);
            if (variant == 0) stockUnderlying.setMultiplier(2e18, 1);
            vm.warp(start - 1);
            (, uint256 left) = ledger.remaining(SECURITY, DAY);
            assertEq(left, 1e17); // A Token update cannot start the cap factor early.
            vm.warp(start);
            (, left) = ledger.remaining(SECURITY, 20261002);
            assertEq(left, 2e17); // A late Token update cannot delay the cap factor.
            if (variant == 1) stockUnderlying.setMultiplier(2e18, 1);
            _trade(3e16);
            assertEq(ledger.used(SECURITY, 20261002), 6e16); // Existing live Adapter accounting is retained.
            (, left) = ledger.remaining(SECURITY, 20261002);
            assertEq(left, 14e16);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testAbsoluteQuotaOverrideAndClearWorkAgainstTheAdjustedCapInRealV4() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 2, 1);
        _quota(20261002, 1, 12e16, 1);
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(1e17);
        _rejectTrade(3e16, 20261002);
        _quota(20261002, 2, 0, 2);
        _trade(5e16);
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _rejectTrade(6e16, 20261002);
    }

    function testPendingFactorAndExistingFundsReportsQuotaRolesSurviveLedgerAndInboxUpgrades() public {
        _basis(202609, 40e18);
        _trade(8e16);
        _scheduleFactor(20261002, 202609, 2, 1);
        _quota(20261002, 1, 18e16, 1);
        bytes32 positionBefore = keccak256(abi.encode(lpManager.getPosition(positionId)));
        bytes32 factorBefore = keccak256(abi.encode(ledger.splitFactorCheckpoint(SECURITY, 202609, 0)));
        ledger.upgradeToAndCall(address(new LedgerV2()), abi.encodeCall(GovernanceMigrationV2.initializeV2, (7, false)));
        inbox.upgradeToAndCall(address(new InboxV2()), abi.encodeCall(GovernanceMigrationV2.initializeV2, (8, false)));
        assertEq(ledger.used(SECURITY, DAY), 8e16);
        assertEq(ledger.adtvOf(SECURITY, 202609).value, 40e18);
        assertEq(ledger.quotaOf(SECURITY, 20261002).quotaWad, 18e16);
        assertEq(keccak256(abi.encode(ledger.splitFactorCheckpoint(SECURITY, 202609, 0))), factorBefore);
        assertEq(keccak256(abi.encode(lpManager.getPosition(positionId))), positionBefore);
        assertTrue(inbox.hasRole(inbox.VOLUME_ORACLE_ROLE(), address(this)));
        assertEq(inbox.lastSequence(3, SECURITY), 1);
        assertEq(ledger.splitFactorVersion(SECURITY, 202609), 1);
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(15e16);
        _rejectTrade(4e16, 20261002);
        _scheduleFactor(20261003, 202609, 3, 1); // Both upgraded components still accept fresh reports.
    }

    function testUpgradeFreezeDoesNotPreventScheduledFactorActivationOrBusinessReporting() public {
        _basis(202609, 40e18);
        _scheduleFactor(20261002, 202609, 2, 1);
        address guardian = anchor.guardian();
        vm.prank(guardian);
        anchor.freezeUpgrades(keccak256("freeze"));
        vm.warp(ledger.dayStartUTC(20261002));
        _trade(15e16);
        assertEq(ledger.used(SECURITY, 20261002), 15e16);
        _scheduleFactor(20261003, 202609, 3, 1);
        assertTrue(anchor.upgradesFrozen());
    }

    function _basis(uint32 month, uint256 amount) private {
        registry.setTierPolicy(1, 25, 10, keccak256("factor-tier"));
        uint64 version = ledger.adtvOf(SECURITY, month).version + 1;
        uint64 sequence = inbox.lastSequence(1, SECURITY) + 1;
        inbox.submitAdtv(
            AdtvReport(
                SECURITY,
                month,
                amount,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("factor-basis", month, version)),
                keccak256("source")
            )
        );
    }

    function _scheduleFactor(uint32 day, uint32 month, uint128 numerator, uint128 denominator) private {
        uint64 version = ledger.splitFactorVersion(SECURITY, month) + 1;
        uint64 sequence = inbox.lastSequence(3, SECURITY) + 1;
        inbox.submitSplitFactor(
            SplitFactorReport(
                SECURITY,
                month,
                day,
                1,
                numerator,
                denominator,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("local-factor", day, sequence)),
                keccak256("announcement")
            )
        );
    }

    function _quota(uint32 day, uint8 action, uint256 amount, uint64 version) private {
        uint64 sequence = inbox.lastSequence(2, SECURITY) + 1;
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                day,
                action,
                amount,
                uint64(vm.getBlockTimestamp()),
                uint64(vm.getBlockTimestamp() + 100),
                version,
                sequence,
                keccak256(abi.encode("factor-quota", day, sequence)),
                keccak256("source")
            )
        );
    }

    function _trade(uint128 amount) private {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, amount);
        request.deadline = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        (uint256 actualIn,) = router.swapExactInput(request);
        assertEq(actualIn, amount);
    }

    function _rejectTrade(uint128 amount, uint32 day) private {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), amount);
        request.deadline = uint64(vm.getBlockTimestamp() + 100);
        bytes32 beforeState = _swapStateDigest(day);
        vm.expectRevert(); // V4 wraps the Hook error; unit cases check the exact Ledger error.
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
    }
}

```

### test/integration/local/governance/SixProxyMigration.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {UpgradeDeployment} from "../../../helpers/v1/UpgradeDeployment.sol";
import {GovernanceMigrationV2} from "../../../helpers/v1/GovernanceUpgradeMocks.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";

/// @dev Six compatible V2 migrations against funded positions and a real local V4 PoolManager.
contract TSVSixProxyMigrationLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        anchor.bindProxies(_addresses());
    }

    function testSixProxyMigrationPreservesBusinessStateAndTradingAndLiquidityStillWork() public {
        uint256 pauseId = _seedBusinessState();
        bytes32 beforeMigration = _businessStateDigest();
        _upgradeSix(false);
        assertEq(_businessStateDigest(), beforeMigration, "V2 migration changed existing business data");
        registry.clearEmergencyPause(pauseId, keccak256("resume"));
        _assertDirectLpLifecycle();
    }

    function testSixProxyMigrationPreservesPositionsForForcedExit() public {
        _seedPauseTestFees();
        bytes32 beforeMigration = _businessStateDigest();
        _upgradeSix(false);
        assertEq(_businessStateDigest(), beforeMigration);
        sbt.setHolder(alice, false);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertGt(stock.balanceOf(alice), stockBefore);
        assertGt(quote.balanceOf(alice), quoteBefore);
    }

    function testLastMigrationFailurePreservesFundedV4StateAndEntireBusinessSnapshot() public {
        _seedBusinessState();
        bytes32 beforeMigration = _businessStateDigest();
        address[6] memory targets = _addresses();
        address[6] memory old;
        for (uint256 i; i < 6; ++i) {
            old[i] = TSVERC1967Proxy(payable(targets[i])).tsvImplementation();
        }
        _upgradeSix(true);
        assertEq(_businessStateDigest(), beforeMigration);
        for (uint256 i; i < 6; ++i) {
            assertEq(TSVERC1967Proxy(payable(targets[i])).tsvImplementation(), old[i]);
        }
        assertFalse(anchor.upgradeContextActive());
    }

    function testFrozenRecoveryPreservesFundedPositionsAndBothUpgradeEntrypointsStayClosed() public {
        address oldGuardian = anchor.guardian();
        vm.prank(oldGuardian);
        bytes32 freeze = anchor.freezeUpgrades(keccak256("governor-risk"));
        bytes32 beforeRecovery = _businessStateDigest();
        address nextGovernor = makeAddr("recovered-governor");
        address nextGuardian = makeAddr("recovered-guardian");
        vm.prank(anchor.recoveryCouncil());
        bytes32 id =
            anchor.proposeRecovery(nextGovernor, nextGuardian, keccak256("frozen-recovery"), keccak256("evidence"));
        vm.prank(oldGuardian);
        anchor.approveRecovery(id);
        vm.prank(makeAddr("executor"));
        anchor.executeRecovery(id);
        assertEq(_businessStateDigest(), beforeRecovery);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
        address[] memory targets = new address[](1);
        targets[0] = address(registry);
        address[] memory implementations = new address[](1);
        implementations[0] = address(new TSVRegistryV1());
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGovernanceAnchor.UpgradeFrozen.selector);
        anchor.upgradeBatch(targets, implementations, new bytes[](1));
        vm.prank(nextGovernor);
        vm.expectRevert(TSVGoverned.UpgradeFrozen.selector);
        registry.upgradeToAndCall(implementations[0], "");
        vm.prank(oldGuardian);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.unfreezeUpgrades(freeze, keccak256("resolved"));
        vm.prank(nextGuardian);
        anchor.unfreezeUpgrades(freeze, keccak256("resolved"));
        vm.prank(nextGovernor);
        registry.upgradeToAndCall(implementations[0], "");
        _assertDirectLpLifecycle();
    }

    function testUpgradeFreezeAllowsReportsConfigurationPauseAndForcedExit() public {
        vm.prank(anchor.guardian());
        bytes32 freeze = anchor.freezeUpgrades(keccak256("upgrade-risk"));
        uint256 pauseId = _seedBusinessState();
        assertTrue(inbox.reportIdUsed(keccak256("migration-quota")));
        registry.setTierPolicy(2, 25, 2, keccak256("new-tier"));
        registry.clearEmergencyPause(pauseId, keccak256("resume"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }

    function _seedBusinessState() private returns (uint256 pauseId) {
        _seedPauseTestFees();
        uint64 now_ = uint64(block.timestamp);
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                DAY,
                1,
                1e22,
                now_ - 1,
                now_ + 100,
                1,
                1,
                keccak256("migration-quota"),
                keccak256("quota-source")
            )
        );
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        pauseId = registry.addEmergencyPause(
            PauseScope.POOL,
            PoolId.unwrap(key.toId()),
            PauseMode.ALL,
            keccak256("migration-pause"),
            keccak256("pause-source")
        );
    }

    function _businessStateDigest() private view returns (bytes32) {
        bytes32 registryState = keccak256(
            abi.encode(
                keccak256(abi.encode(registry.getSecurity(SECURITY), registry.tierPolicy(1))),
                keccak256(abi.encode(registry.getToken(address(stock)))),
                keccak256(abi.encode(registry.getToken(address(quote)))),
                keccak256(abi.encode(registry.getPool(PoolId.unwrap(key.toId())))),
                registry.nextPauseId(),
                _pauseStateDigest(),
                registry.marketPauseMode(SECURITY),
                registry.marketSequence(SECURITY),
                registry.activePoolCountByCurrency(address(stock)),
                registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), address(this))
            )
        );
        bytes32 reportsState = keccak256(
            abi.encode(
                ledger.adtvOf(SECURITY, 202609),
                ledger.quotaOf(SECURITY, DAY),
                ledger.dayStartCheckpointCount(),
                ledger.initialDayStartOffsetSeconds(),
                inbox.reportIdUsed(keccak256("adtv")),
                inbox.reportIdUsed(keccak256("migration-quota")),
                inbox.lastSequence(1, SECURITY),
                inbox.lastSequence(2, SECURITY),
                inbox.lastSourceTimestamp(1, SECURITY),
                inbox.lastSourceTimestamp(2, SECURITY)
            )
        );
        bytes32 links = keccak256(
            abi.encode(
                keccak256(abi.encode(registry.hook(), registry.lpManager(), registry.dataInbox())),
                keccak256(
                    abi.encode(ledger.registry(), ledger.hook(), ledger.dataInbox(), inbox.registry(), inbox.ledger())
                ),
                keccak256(
                    abi.encode(hook.poolManager(), hook.registry(), hook.ledger(), hook.router(), hook.lpManager())
                ),
                router.poolManager(),
                router.registry(),
                router.ledger(),
                lpManager.poolManager(),
                lpManager.registry(),
                registry.participantSbt(),
                registry.sbtTokenId()
            )
        );
        return keccak256(
            abi.encode(
                registryState,
                reportsState,
                links,
                _swapStateDigest(DAY),
                lpManager.nextPositionId(),
                lpManager.hasRole(lpManager.POOL_CREATOR_ROLE(), address(this)),
                inbox.hasRole(inbox.VOLUME_ORACLE_ROLE(), address(this))
            )
        );
    }

    function _addresses() private view returns (address[6] memory) {
        return [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lpManager)];
    }

    function _pauseStateDigest() private view returns (bytes32) {
        (bool ok, bytes memory result) =
            address(registry).staticcall(abi.encodeWithSignature("emergencyPauses(uint256)", 1));
        assertTrue(ok);
        return keccak256(result);
    }

    function _upgradeSix(bool failLast) private {
        address[6] memory proxies = _addresses();
        address[6] memory replacements = UpgradeDeployment.deployV2();
        address[] memory targets = new address[](6);
        address[] memory implementations = new address[](6);
        bytes[] memory calls = new bytes[](6);
        for (uint256 i; i < 6; ++i) {
            targets[i] = proxies[i];
            implementations[i] = replacements[i];
            calls[i] = abi.encodeCall(GovernanceMigrationV2.initializeV2, (42, failLast && i == 5));
        }
        if (failLast) vm.expectRevert(GovernanceMigrationV2.MigrationFailed.selector);
        anchor.upgradeBatch(targets, implementations, calls);
        if (!failLast) {
            for (uint256 i; i < 6; ++i) {
                assertEq(TSVERC1967Proxy(payable(proxies[i])).tsvImplementation(), replacements[i]);
                assertEq(GovernanceMigrationV2(proxies[i]).migrationMarker(), 42);
                assertEq(GovernanceMigrationV2(proxies[i]).migrationCaller(), address(anchor));
            }
        }
    }
}

```

### test/integration/local/governance/GovernanceLifecycle.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVGovernanceLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVGovernanceLocalTest is ProtocolFixture {
    function testGlobalUpgradeFreezeAllowsSwapLiquidityChangesAndOrdinaryExit() public {
        vm.prank(anchor.guardian());
        bytes32 freeze = anchor.freezeUpgrades(keccak256("upgrade-risk"));
        _assertDirectLpLifecycle();
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }
}

```

### test/integration/local/registry/Admission.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TokenStatus, PoolStatus, MarketStatus} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVAdmissionLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVAdmissionLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testAdmissionOpensRealV4PoolWithoutMarketReport() public view {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint8(registry.getToken(address(stock)).status), uint8(TokenStatus.APPROVED));
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.OPEN));
        assertEq(registry.marketSequence(SECURITY), 0);
        assertEq(inbox.lastSequence(0, SECURITY), 0);
        assertTrue(registry.isTradable(poolId));
        assertTrue(registry.isLPAllowed(poolId));
        assertGt(lpManager.getPosition(positionId).liquidity, 0);
    }

    function testPoolInitializationFailureLeavesNoPendingRecordOrCounts() public {
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        uint32 stockCount = registry.activePoolCountByCurrency(address(stock));
        uint32 quoteCount = registry.activePoolCountByCurrency(address(quote));
        vm.expectRevert();
        lpManager.initializePool(otherPool, 0, keccak256("bad-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ABSENT));
        assertFalse(registry.isKnownPool(otherPoolId));
        assertEq(registry.activePoolCountByCurrency(address(stock)), stockCount);
        assertEq(registry.activePoolCountByCurrency(address(quote)), quoteCount);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(otherPoolId));
        assertEq(price, 0);
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("correct-price"));
        assertEq(uint8(registry.getPool(otherPoolId).status), uint8(PoolStatus.ACTIVE));
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 2);
    }
}

```

### test/integration/local/registry/Pauses.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MarketAction, PauseScope, PauseMode, LPOperationMode, LPHookContext} from "tsv-v1/types/TSVTypes.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVPausesLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testEmergencyTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, false);
    }

    function testEmergencyLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, false);
    }

    function testEmergencyAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, false);
    }

    function testMarketTradePauseAllowsAllOrdinaryLPOperations() public {
        _exercisePauseBehavior(PauseMode.TRADE, true);
    }

    function testMarketLPPauseAllowsDirectAndAdapterTrading() public {
        _exercisePauseBehavior(PauseMode.LP, true);
    }

    function testMarketAllPauseBlocksTradingAndOrdinaryLP() public {
        _exercisePauseBehavior(PauseMode.ALL, true);
    }

    function testMarketAndEmergencyPausesRecoverSeparatelyWithRealV4() public {
        _seedPauseTestFees();
        _submitLocalMarket(MarketAction.HALT, PauseMode.LP);
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        _submitLocalMarket(MarketAction.RESUME, PauseMode.LP);
        _assertTradingBlocked();
        _exerciseAllowedLPLifecycle();
        registry.clearEmergencyPause(id, keccak256("resume"));
        vm.prank(alice);
        positionId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
        _exerciseAllowedTrading();
    }

    function testHookIndependentlyChecksTradingAndLPPauses() public {
        uint256 id = _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, swapParams, "");
        registry.clearEmergencyPause(id, keccak256("resume"));
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.LP);
        vm.prank(address(manager));
        (bytes4 selector,,) = hook.beforeSwap(address(router), key, swapParams, "");
        assertEq(selector, IHooks.beforeSwap.selector);

        LPHookContext memory ctx = LPHookContext(
            PoolId.unwrap(key.toId()), -600, 600, LPOperationMode.INCREASE, bytes32(positionId), int256(1e18)
        );
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-600, 600, int256(1e18), bytes32(positionId));
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(lpManager), key, params, "");
        ctx.mode = LPOperationMode.COLLECT;
        ctx.liquidityDelta = 0;
        params.liquidityDelta = 0;
        vm.mockCall(
            address(lpManager), abi.encodeWithSelector(TSVLPManagerV1.activeLPContext.selector), abi.encode(ctx)
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(address(lpManager), key, params, "");
    }

    function testPoolInitializationRemainsAllowedDuringAllPauses() public {
        _pauseLocal(PauseScope.GLOBAL, 0, PauseMode.ALL);
        _submitLocalMarket(MarketAction.HALT, PauseMode.ALL);
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("paused-price"));
        bytes32 otherPoolId = PoolId.unwrap(otherPool.toId());
        assertTrue(registry.isKnownPool(otherPoolId));
        assertFalse(registry.isTradable(otherPoolId));
        assertFalse(registry.isLPAllowed(otherPoolId));
    }
}

```

### test/integration/local/trading/DexAdapter.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {DexRouterTestAdapter} from "../../../helpers/v1/DexRouterTestAdapter.sol";

/// @dev Controlled caller used exclusively to inject valid/malformed authenticated callback trailers.
contract TestDexCallbackCaller {
    function execute(address adapter, bytes calldata data) external {
        (bool ok, bytes memory result) = adapter.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

contract TSVDexAdapterTest is ProtocolFixture {
    TestDexCallbackCaller internal caller;
    DexRouterTestAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        caller = new TestDexCallbackCaller();
        adapter = new DexRouterTestAdapter(address(caller), router);
        router.setAdapterAllowed(address(adapter), true);
    }

    function testUntrustedCallerCannotSpoofAuthenticatedParticipantMarker() public {
        bytes memory payload = _payload(true, address(router), alice, _marker(alice));
        vm.prank(alice);
        (bool ok, bytes memory data) = address(adapter).call(payload);
        assertFalse(ok);
        assertEq(bytes4(data), DexRouterTestAdapter.UnauthorizedDex.selector);
        assertEq(adapter.lastParticipant(), address(0));
    }

    function testMalformedLengthPrefixAndZeroParticipantRejectBeforeFunding() public {
        bytes memory canonical = abi.encodeCall(
            DexRouterTestAdapter.sellBase, (alice, address(router), abi.encode(_swapRequest(true, 1e18)))
        );
        uint256[3] memory markers = [uint256(0), uint256(uint160(alice)), _marker(address(0))];
        for (uint8 i; i < 3; i++) {
            bytes memory payload = abi.encodePacked(canonical, uint256(1e18), markers[i]);
            vm.expectRevert();
            caller.execute(address(adapter), payload);
        }
        vm.expectRevert();
        caller.execute(address(adapter), abi.encodePacked(canonical, _marker(alice)));
        vm.expectRevert();
        caller.execute(address(adapter), abi.encodePacked(canonical, uint256(0), uint256(1e18), _marker(alice)));
        assertEq(adapter.lastParticipant(), address(0));
    }

    function testWrongPoolDirectionOrRecipientRejectsAtomically() public {
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), _payload(true, address(manager), alice, _marker(alice)));
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), _payload(true, address(router), address(0), _marker(alice)));
        bytes memory payload = abi.encodePacked(
            abi.encodeCall(
                DexRouterTestAdapter.sellQuote, (alice, address(router), abi.encode(_swapRequest(true, 1e18)))
            ),
            uint256(1e18),
            _marker(alice)
        );
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), payload);
    }

    function testBothDirectionsRefundOnlyRouteInputAndPreserveExistingDonations() public {
        for (uint8 d; d < 2; d++) {
            bool direction = d == 0;
            IERC20 input = IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1));
            IERC20 output = IERC20(Currency.unwrap(direction ? key.currency1 : key.currency0));
            vm.startPrank(alice);
            input.transfer(address(adapter), 1e18 + 100);
            output.transfer(address(adapter), 200);
            vm.stopPrank();
            uint256 inputBefore = input.balanceOf(address(adapter));
            uint256 outputBefore = output.balanceOf(address(adapter));
            uint256 aliceOutBefore = output.balanceOf(alice);
            caller.execute(address(adapter), _payload(direction, address(router), alice, _marker(alice)));
            assertEq(adapter.lastParticipant(), alice);
            assertEq(input.balanceOf(address(adapter)), inputBefore - 1e18);
            assertEq(output.balanceOf(address(adapter)), outputBefore);
            assertEq(output.balanceOf(alice) - aliceOutBefore, adapter.lastActualOut());
            assertEq(input.allowance(address(adapter), address(router)), 0);
        }
    }

    function _payload(bool direction, address pool, address recipient, uint256 marker)
        internal
        view
        returns (bytes memory)
    {
        bytes memory route = abi.encode(_swapRequest(direction, 1e18));
        bytes memory data = direction
            ? abi.encodeCall(DexRouterTestAdapter.sellBase, (recipient, pool, route))
            : abi.encodeCall(DexRouterTestAdapter.sellQuote, (recipient, pool, route));
        return abi.encodePacked(data, uint256(1e18), marker);
    }

    function _marker(address participant) internal pure returns (uint256) {
        return 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000 | uint256(uint160(participant));
    }
}

```

### test/integration/local/trading/StatefulTradingLP.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TradingLPHandler} from "../../../helpers/v1/TradingLPHandler.sol";

/// @dev Mixed trading and LP sequences, checked against independent balance/position/quota models.
contract TSVStatefulTradingLPTest is Test {
    TradingLPHandler internal handler;

    function setUp() public {
        handler = new TradingLPHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = TradingLPHandler.swap.selector;
        selectors[1] = TradingLPHandler.open.selector;
        selectors[2] = TradingLPHandler.change.selector;
        selectors[3] = TradingLPHandler.collect.selector;
        selectors[4] = TradingLPHandler.close.selector;
        selectors[5] = TradingLPHandler.credential.selector;
        selectors[6] = TradingLPHandler.pause.selector;
        selectors[7] = TradingLPHandler.conversion.selector;
        selectors[8] = TradingLPHandler.quota.selector;
        selectors[9] = TradingLPHandler.advanceDay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantPositionsReceiptsBalancesVolumeAndV4DebtMatchModel() public view {
        handler.assertModel();
    }

    function testModelTraversesSuccessfulAndRejectedSwapLPQuotaAndDayChanges() public {
        handler.open(10, false);
        handler.swap(1e14, true, true, false);
        handler.change(1, true, false);
        handler.collect(0);
        handler.pause(1);
        handler.swap(1e14, true, true, false);
        handler.change(1, false, false);
        handler.pause(2);
        handler.swap(1e14, false, false, false);
        handler.change(1, true, false);
        handler.credential(false, false);
        handler.close(0, true);
        handler.credential(true, false);
        handler.pause(0);
        handler.quota(true, false);
        handler.swap(1e14, true, true, false);
        handler.quota(false, true);
        handler.swap(1e14, true, true, false);
        handler.advanceDay(1);
        handler.swap(1e14, false, false, false);
        handler.assertModel();
        assertEq(handler.successfulSwaps(), 4);
        assertGe(handler.successfulLPChanges(), 4);
        assertGe(handler.rejectedOperations(), 3);
    }
}

```

### test/integration/local/trading/IssuerFailures.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Wrapped-stock issuer refusal is independent of the legal-share conversion source.
contract TSVIssuerSwapFailuresTest is ProtocolFixture {
    function testWrappedStockRefusalRollsBackBothSettlementDirectionsAndCanRetry() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.mockCallRevert(
            address(stock),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encodeWithSignature("Error(string)", "issuer refused transferFrom")
        );
        vm.mockCallRevert(
            address(stock),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encodeWithSignature("Error(string)", "issuer refused recipient")
        );
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(i == 0, 1e18);
            vm.expectRevert();
            vm.prank(alice);
            router.swapExactInput(request);
            assertEq(_swapStateDigest(DAY), beforeState);
            request.limitAmount = 1e20;
            vm.expectRevert();
            vm.prank(alice);
            router.swapExactOutput(request);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        vm.clearMockedCalls();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18));
    }
}

```

### test/integration/local/trading/Settlement.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Token faults must undo the hook accounting, V4 price/fees, and all transfers.
contract TSVTradingSettlementTest is ProtocolFixture {
    function testTaxFalseAndShortTransfersRollbackBothSwapDirections() public {
        for (uint8 mode = 1; mode <= 3; mode++) {
            quote.setTransferMode(mode);
            for (uint8 direction; direction < 2; direction++) {
                bytes32 beforeState = _swapStateDigest(DAY);
                SwapRequest memory request = _swapRequest(direction == 0, 1e18);
                vm.expectRevert();
                vm.prank(alice);
                router.swapExactInput(request);
                assertEq(_swapStateDigest(DAY), beforeState);
                request.limitAmount = 1e20;
                vm.expectRevert();
                vm.prank(alice);
                router.swapExactOutput(request);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        quote.setTransferMode(0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(true, 1e18));
    }

    function testExactSettlementSupportsTokensWithoutReturnData() public {
        quote.setTransferMode(4);
        for (uint8 i; i < 2; i++) {
            vm.prank(alice);
            (uint256 input, uint256 output) = router.swapExactInput(_swapRequest(i == 0, 1e17));
            assertGt(input, 0);
            assertGt(output, 0);
        }
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }

    function testTokenCallbackCannotReenterEitherSwapEntryAndStateCanRecover() public {
        SwapRequest memory request = _swapRequest(true, 1e18);
        for (uint8 i; i < 3; i++) {
            bytes memory data = i == 0
                ? abi.encodeCall(TSVSwapRouterV1.swapExactInput, (request))
                : i == 1
                    ? abi.encodeCall(TSVSwapRouterV1.swapExactOutput, (request))
                    : abi.encodeCall(TSVSwapRouterV1.swapExactInputFromAdapter, (request, alice));
            quote.setCallback(address(router), data);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert(TSVSwapRouterV1.Reentrancy.selector);
            vm.prank(alice);
            router.swapExactInput(request);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setCallback(address(0), "");
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testBlockedOutputRecipientRollsBackThenUnblockedSwapSucceeds() public {
        quote.setBlockedRecipient(alice);
        bytes32 beforeState = _swapStateDigest(DAY);
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        quote.setBlockedRecipient(address(0));
        vm.prank(alice);
        router.swapExactInput(request);
    }
}

```

### test/integration/local/trading/Boundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1TestExternalAdapter} from "../../../helpers/v1/LocalMocks.sol";

/// @dev Real V4 swaps: request bounds, actual delivery, and complete rollback.
contract TSVTradingBoundariesTest is ProtocolFixture {
    function testFuzzInvalidAmountIsRejectedBeforeSettlement(uint128 amount, bool exactInput) public {
        amount = amount == 0 ? 0 : uint128(bound(amount, uint256(uint128(type(int128).max)) + 1, type(uint128).max));
        SwapRequest memory request = _swapRequest(true, amount);
        bytes32 beforeState = _swapStateDigest(DAY);
        _reject(request, exactInput, TSVSwapRouterV1.InvalidRequest.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testZeroAmountAndZeroLimitRejectBothModes() public {
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(true, i == 0 ? 0 : 1e18);
            if (i == 1) request.limitAmount = 0;
            _reject(request, true, TSVSwapRouterV1.InvalidRequest.selector);
            _reject(request, false, TSVSwapRouterV1.InvalidRequest.selector);
        }
    }

    function testExpiredRequestRollsBackBothModes() public {
        SwapRequest memory request = _swapRequest(true, 1e18);
        request.deadline = uint64(block.timestamp - 1);
        bytes32 beforeState = _swapStateDigest(DAY);
        _reject(request, true, TSVSwapRouterV1.Expired.selector);
        _reject(request, false, TSVSwapRouterV1.Expired.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testDeadlineIsInclusiveAndSameRequestCanTradeAgain() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e16);
        request.deadline = uint64(block.timestamp);
        vm.startPrank(alice);
        (uint256 first,) = router.swapExactInput(request);
        (uint256 second,) = router.swapExactInput(request);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), first + second);
        _assertNoRouterBalances();
    }

    function testUnknownOrChangedPoolKeyRejectedAtomically() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 5; i++) {
            SwapRequest memory request = _swapRequest(true, 1e18);
            if (i == 0) request.key.fee++;
            if (i == 1) request.key.tickSpacing += 60;
            if (i == 2) request.key.hooks = IHooks(address(0));
            if (i == 3) (request.key.currency0, request.key.currency1) = (key.currency1, key.currency0);
            if (i == 4) request.key.currency0 = Currency.wrap(makeAddr("unknown-currency"));
            _reject(request, true, TSVSwapRouterV1.InvalidPool.selector);
            _reject(request, false, TSVSwapRouterV1.InvalidPool.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
    }

    function testExactOutputBothDirectionsDeliversExactlyAndCountsActualStockLeg() public {
        stockUnderlying.setMultiplier(9e17, 1);
        for (uint8 i; i < 2; i++) {
            bool stockInput = i == 0;
            bool direction = stockInput == (address(stock) == Currency.unwrap(key.currency0));
            SwapRequest memory request = _swapRequest(direction, 1e16);
            request.limitAmount = 1e19;
            IERC20 input = IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1));
            IERC20 output = IERC20(Currency.unwrap(direction ? key.currency1 : key.currency0));
            uint256 inputBefore = input.balanceOf(alice);
            uint256 outputBefore = output.balanceOf(alice);
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            vm.prank(alice);
            (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
            assertEq(actualOut, request.amountSpecified);
            assertEq(inputBefore - input.balanceOf(alice), actualIn);
            assertEq(output.balanceOf(alice) - outputBefore, actualOut);
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, (stockInput ? actualIn : actualOut) * 9 / 10);
        }
        _assertNoRouterBalances();
    }

    function testBothDirectionsSlippageRollsBackAndCanRetry() public {
        for (uint8 i; i < 2; i++) {
            SwapRequest memory request = _swapRequest(i == 0, 1e16);
            bytes32 beforeState = _swapStateDigest(DAY);
            request.limitAmount = type(uint128).max;
            _reject(request, true, TSVSwapRouterV1.SlippageExceeded.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
            request.limitAmount = 1;
            _reject(request, false, TSVSwapRouterV1.SlippageExceeded.selector);
            assertEq(_swapStateDigest(DAY), beforeState);
            request.limitAmount = 1;
            vm.prank(alice);
            router.swapExactInput(request);
        }
    }

    function testPartialExactInputChargesOnlyConsumedAmount() public {
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(direction, 1e22);
        uint256 beforeStock = stock.balanceOf(alice);
        bytes32 beforeState = _swapStateDigest(DAY);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertLt(actualIn, request.amountSpecified);
        assertGt(actualOut, 0);
        assertEq(beforeStock - stock.balanceOf(alice), actualIn);
        assertEq(ledger.used(SECURITY, DAY), actualIn);
        _assertNoRouterBalances();
        vm.revertToState(snapshot);
        request.limitAmount = uint128(actualOut + 1);
        _reject(request, true, TSVSwapRouterV1.SlippageExceeded.selector);
        assertEq(_swapStateDigest(DAY), beforeState);
        request.limitAmount = uint128(actualOut);
        vm.prank(alice);
        (uint256 retriedIn, uint256 retriedOut) = router.swapExactInput(request);
        assertEq(retriedIn, actualIn);
        assertEq(retriedOut, actualOut);
    }

    function testCallbackRequiresManagerAndActiveSwap() public {
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        router.unlockCallback("");
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        vm.prank(address(manager));
        router.unlockCallback("");
    }

    function testSourceConversionFailureOrZeroRollsBackEntireV4Swap() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        bytes32 beforeState = _swapStateDigest(DAY);
        stockUnderlying.setMultiplier(0, 1);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        stockUnderlying.setMultiplier(1e18, 2);
        vm.mockCallRevert(
            address(stockUnderlying), abi.encodeWithSignature("getUnderlyingAmountByShares(uint256)"), "source offline"
        );
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testAllowanceFailureRollsBackPoolAndQuotaAndCanRetry() public {
        bool direction = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(direction, 1e18);
        vm.prank(alice);
        quote.approve(address(router), 0);
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.prank(alice);
        quote.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.swapExactInput(request);
    }

    function testAdapterRevocationStopsNextSwapIncludingCodeRemovedAdapter() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        router.setAdapterAllowed(address(adapter), false);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        adapter.swapExactInput(router, _swapRequest(true, 1e18), alice);
        router.setAdapterAllowed(address(adapter), true);
        vm.etch(address(adapter), "");
        router.setAdapterAllowed(address(adapter), false);
        assertFalse(router.isAdapterAllowed(address(adapter)));
    }

    function testInvalidAdapterAndUnauthorizedAllowlistChanges() public {
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(address(0), false);
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(alice, true);
        vm.expectRevert();
        vm.prank(alice);
        router.setAdapterAllowed(address(quote), true);
        assertFalse(router.isAdapterAllowed(address(quote)));
    }

    function _reject(SwapRequest memory request, bool exactInput, bytes4 errorSelector) internal {
        vm.expectRevert(errorSelector);
        vm.prank(alice);
        if (exactInput) router.swapExactInput(request);
        else router.swapExactOutput(request);
    }

    function _assertNoRouterBalances() internal view {
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }
}

```

### test/integration/local/trading/Accounting.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Real-V4 accounting across fees, pools, and owners.
contract TSVTradingAccountingTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testProtocolAndLPFeesAreIncludedInActualStockInputVolume() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice);
        (uint256 actualIn,) = router.swapExactInput(_swapRequest(direction, 1e18));
        assertEq(beforeStock - stock.balanceOf(alice), actualIn);
        assertEq(ledger.used(SECURITY, DAY), actualIn);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(stock))), 0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        manager.collectProtocolFees(address(this), Currency.wrap(address(stock)), 0);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function testSameSecurityAcrossTwoRealPoolsConsumesOneQuota() public {
        PoolKey memory second = key;
        second.fee = 500;
        second.tickSpacing = 10;
        lpManager.initializePool(second, uint160(1 << 96), keccak256("second-price"));
        vm.prank(alice);
        lpManager.openPosition(second, -600, 600, 1e20, _pauseTestBounds());
        inbox.submitQuota(
            QuotaReport(
                SECURITY,
                DAY,
                1,
                15e17,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 100),
                1,
                1,
                keccak256("two-pool-quota"),
                keccak256("source")
            )
        );
        bool direction = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        (uint256 first,) = router.swapExactInput(_swapRequest(direction, 1e18));
        SwapRequest memory request = _swapRequest(direction, 1e18);
        request.key = second;
        uint256 ownerStock = stock.balanceOf(alice);
        uint256 poolStock = stock.balanceOf(address(manager));
        vm.expectRevert();
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), first);
        assertEq(stock.balanceOf(alice), ownerStock);
        assertEq(stock.balanceOf(address(manager)), poolStock);
        request.amountSpecified = 4e17;
        vm.prank(alice);
        (uint256 secondInput,) = router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), first + secondInput);
    }

    function testEqualRangesAccrueSeparateOwnerFeesAndClosingOnePreservesOther() public {
        address bob = makeAddr("fee-bob");
        sbt.setHolder(bob, true);
        stock.mintTestShares(bob, 1e22);
        quote.mint(bob, 1e22);
        vm.startPrank(bob);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        uint256 bobId = lpManager.openPosition(key, -600, 600, 1e20, _pauseTestBounds());
        vm.stopPrank();
        _seedPauseTestFees();
        uint256 beforeAlice = stock.balanceOf(alice);
        uint256 beforeBob = stock.balanceOf(bob);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        vm.prank(bob);
        lpManager.collectFees(bobId, _pauseTestBounds());
        uint256 aliceFees = stock.balanceOf(alice) - beforeAlice;
        assertGt(aliceFees, 0);
        assertEq(stock.balanceOf(bob) - beforeBob, aliceFees);
        TSVLPManagerV1.Position memory beforePosition = lpManager.getPosition(bobId);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        assertEq(keccak256(abi.encode(lpManager.getPosition(bobId))), keccak256(abi.encode(beforePosition)));
        assertEq(lpManager.ownerOf(bobId), bob);
        vm.prank(bob);
        lpManager.closePosition(bobId, _pauseTestBounds());
        assertEq(lpManager.balanceOf(bob), 0);
    }
}

```

### test/integration/local/trading/DeltaGuards.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Faulty PoolManager deltas exercise defensive guards before any token settlement.
contract TSVSwapDeltaGuardsTest is ProtocolFixture {
    function testInvalidDeltaSignsRejectedInEitherDirection() public {
        int128[3] memory inputs = [int128(0), int128(1), int128(-1)];
        int128[3] memory outputs = [int128(1), int128(1), int128(0)];
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 d; d < 2; d++) {
            for (uint8 i; i < 3; i++) {
                BalanceDelta delta =
                    d == 0 ? toBalanceDelta(inputs[i], outputs[i]) : toBalanceDelta(outputs[i], inputs[i]);
                vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
                vm.expectRevert(TSVSwapRouterV1.SlippageExceeded.selector);
                vm.prank(alice);
                router.swapExactInput(_swapRequest(d == 0, 1e18));
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        vm.clearMockedCalls();
    }

    function testMinimumSignedInputDeltaRejectsBeforeNegationAndTransfers() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 d; d < 2; d++) {
            BalanceDelta delta = d == 0 ? toBalanceDelta(type(int128).min, 1) : toBalanceDelta(1, type(int128).min);
            vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
            vm.expectRevert(TSVSwapRouterV1.InputAmountTooLarge.selector);
            vm.prank(alice);
            router.swapExactInput(_swapRequest(d == 0, 1e18));
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        vm.clearMockedCalls();
    }
}

```

### test/integration/local/trading/Trading.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1TestParticipantWallet, V1TestExternalAdapter} from "../../../helpers/v1/LocalMocks.sol";

/// @dev TSVTradingLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVTradingLocalTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testMissingAdtvAllowsLiquidityButSwapRevertsAtomically() public {
        uint32 day = 20261101;
        vm.warp(ledger.dayStartUTC(day) + 1);
        (bool valid,) = ledger.remaining(SECURITY, day);
        assertFalse(valid);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, _pauseTestBounds());
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        bytes32 beforeState = _swapStateDigest(day);
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(TSVVolumeLedgerV1.MissingReport.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertEq(_swapStateDigest(day), beforeState);
        uint64 now_ = uint64(block.timestamp);
        inbox.submitAdtv(
            AdtvReport(SECURITY, 202610, 1e24, now_ - 1, now_ + 100, 1, 2, keccak256("nov-adtv"), keccak256("source"))
        );
        vm.prank(alice);
        router.swapExactInput(request);
        assertGt(ledger.used(SECURITY, day), 0);
    }

    /// @dev Verifies a real V4 pool swap accounts for the actual deltas.
    function testRealV4OnePoolSwapAccountsActualDelta() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(uint160(address(hook)) & uint160(0x3FFF), uint160(0x3FFF));
        assertEq(lpManager.ownerOf(positionId), alice);
        assertTrue(registry.isTradable(poolId));
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 beforeUsed = ledger.used(SECURITY, DAY);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        uint256 used = ledger.used(SECURITY, DAY) - beforeUsed;
        assertEq(used, actualIn);
    }

    /// @dev Verifies an allowlisted Adapter uses the shared request for both directions and settles to itself.
    function testAllowlistedAdapterUsesSharedSwapRequestBothDirections() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        _runAdapterSwap(adapter, stockIsCurrency0);
        _runAdapterSwap(adapter, !stockIsCurrency0);
    }

    /// @dev Verifies the Adapter entry rejects callers outside the Router allowlist.
    function testAdapterEntryRejectsUnallowlistedCaller() public {
        SwapRequest memory request = _swapRequest(address(stock) == Currency.unwrap(key.currency0), 1e18);
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        router.swapExactInputFromAdapter(request, alice);
    }

    /// @dev Verifies an allowlisted Adapter cannot use an ineligible participant identity.
    function testAllowlistedAdapterRequiresEligibleParticipant() public {
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        bool zeroForOne = address(stock) == Currency.unwrap(key.currency0);
        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        vm.prank(alice);
        IERC20(inputToken).transfer(address(adapter), 1e18);
        adapter.approveToken(inputToken, address(router));

        SwapRequest memory request = _swapRequest(zeroForOne, 1e18);
        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        adapter.swapExactInput(router, request, makeAddr("ineligible"));
    }

    /// @dev Verifies real V4 stock output records the net amount received.
    function testRealV4StockOutputCountsNetReceived() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(!stockIsCurrency0, 1e18);
        vm.prank(alice);
        (, uint256 actualOut) = router.swapExactInput(request);
        assertEq(ledger.used(SECURITY, DAY), actualOut);
    }

    /// @dev Verifies swaps revert when the payer loses more than the raw input delta.
    function testSwapRevertsIfPayerLosesMoreThanRawDelta() public {
        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        quote.setSenderFee(alice, 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(quoteIsCurrency0, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    /// @dev Verifies swaps revert when the pool loses more than the output delta.
    function testSwapRevertsIfPoolLosesMoreThanOutputDelta() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        quote.setSenderFee(address(manager), 100);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.SettlementMismatch.selector);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
        assertEq(quote.balanceOf(alice), quoteBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    /// @dev Verifies swaps require an eligible direct caller.
    function testSwapRequiresEligibleDirectCaller() public {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        vm.expectRevert(TSVSwapRouterV1.Unauthorized.selector);
        router.swapExactInput(request);

        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactInput(request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies an eligible contract wallet can submit a swap directly.
    function testContractWalletCanDirectlySubmitSwap() public {
        V1TestParticipantWallet wallet = new V1TestParticipantWallet(address(this));
        sbt.setHolder(address(wallet), true);
        stock.mintTestShares(address(wallet), 1e21);
        quote.mint(address(wallet), 1e21);
        wallet.approveToken(address(stock), address(router));
        wallet.approveToken(address(quote), address(router));

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockInput, 1e18);

        (uint256 actualIn, uint256 actualOut) = wallet.swapExactInput(router, request);
        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
    }

    /// @dev Verifies backed stock swaps in both directions use live issuer conversion.
    function testBackedStockSwapBothWaysUsesLiveIssuerConversion() public {
        uint256 aliceRawBeforeUpdate = stock.balanceOf(alice);
        uint256 managerRawBeforeUpdate = stock.balanceOf(address(manager));
        stockUnderlying.setMultiplier(2e18, 1);
        assertEq(stock.balanceOf(alice), aliceRawBeforeUpdate);
        assertEq(stock.balanceOf(address(manager)), managerRawBeforeUpdate);
        assertEq(_displayBalance(alice), aliceRawBeforeUpdate * 2);
        assertEq(_displayBalance(address(manager)), managerRawBeforeUpdate * 2);

        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        (uint256 stockIn, uint256 quoteOut) = router.swapExactInput(_swapRequest(stockIsCurrency0, 1e18));
        assertGt(stockIn, 0);
        assertGt(quoteOut, 0);
        assertEq(aliceRawBefore - stock.balanceOf(alice), stockIn);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockIn * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactInput(_swapRequest(!stockIsCurrency0, 1e18));
        assertGt(quoteIn, 0);
        assertGt(stockOut, 0);
        assertEq(stock.balanceOf(alice) - aliceRawBefore, stockOut);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    /// @dev Verifies exact-output swaps deliver the full requested amount.
    function testExactOutputRequiresFullDelivery() public {
        bool stockIsCurrency0 = address(stock) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(stockIsCurrency0, 1e18);
        request.limitAmount = 2e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 actualIn, uint256 actualOut) = router.swapExactOutput(request);
        assertEq(actualOut, 1e18);
        assertLe(actualIn, 2e18);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, actualIn);
    }

    /// @dev Verifies exact-output stock purchases record net shares received.
    function testExactOutputStockPurchaseRecordsNetShares() public {
        stockUnderlying.setMultiplier(2e18, 1);

        bool quoteIsCurrency0 = address(quote) == Currency.unwrap(key.currency0);
        SwapRequest memory request = _swapRequest(quoteIsCurrency0, 1e18);
        request.limitAmount = 2e18;
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 displayedBefore = _displayBalance(alice);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        vm.prank(alice);
        (uint256 quoteIn, uint256 stockOut) = router.swapExactOutput(request);

        assertLe(quoteIn, request.limitAmount);
        assertEq(stockOut, request.amountSpecified);
        assertEq(quoteBefore - quote.balanceOf(alice), quoteIn);
        assertEq(stock.balanceOf(alice) - stockBefore, stockOut);
        assertEq(_displayBalance(alice) - displayedBefore, stockOut * 2);
        assertEq(ledger.used(SECURITY, DAY) - usedBefore, stockOut * 2);
    }

    /// @dev Verifies direct PoolManager swaps cannot bypass the Hook.
    function testDirectPoolManagerSwapCannotBypassHook() public {
        vm.expectRevert();
        manager.unlock(abi.encode(key));
        assertEq(ledger.used(SECURITY, DAY), 0);
    }
}

```

### test/integration/local/trading/Precision.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {V1LocalERC20Decimals} from "../../../helpers/v1/LocalMocks.sol";

contract TSVTradingPrecisionTest is ProtocolFixture {
    function testSixDecimalQuoteSwapAndLPSettleInRawUnitsAndCountOnlyStockShares() public {
        V1LocalERC20Decimals quote6 = new V1LocalERC20Decimals("QUOTE6", 6);
        registry.registerToken(_config(address(quote6), 0, address(0)), keccak256("quote6"));
        bool stock0 = address(stock) < address(quote6);
        PoolKey memory precisionKey = PoolKey(
            Currency.wrap(stock0 ? address(stock) : address(quote6)),
            Currency.wrap(stock0 ? address(quote6) : address(stock)),
            3000,
            60,
            IHooks(address(hook))
        );
        uint160 price = stock0 ? uint160(uint256(1 << 96) / 1e6) : uint160((1 << 96) * 1e6);
        lpManager.initializePool(precisionKey, price, keccak256("precision-price"));
        quote6.mint(alice, 1e16);
        vm.startPrank(alice);
        quote6.approve(address(lpManager), type(uint256).max);
        quote6.approve(address(router), type(uint256).max);
        LPBounds memory bounds = _pauseTestBounds();
        bounds.maxPoolIn0 = 1e25;
        bounds.maxPoolIn1 = 1e25;
        uint256 id = lpManager.openPosition(precisionKey, -887220, 887220, 1e16, bounds);
        vm.stopPrank();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        for (uint8 i; i < 2; i++) {
            bool stockInput = i == 0;
            SwapRequest memory request = _swapRequest(stockInput == stock0, stockInput ? uint128(1e18) : uint128(1e6));
            request.key = precisionKey;
            uint256 beforeStock = stock.balanceOf(alice);
            uint256 beforeQuote = quote6.balanceOf(alice);
            vm.prank(alice);
            (uint256 input, uint256 output) = router.swapExactInput(request);
            if (stockInput) {
                assertEq(beforeStock - stock.balanceOf(alice), input);
                assertEq(quote6.balanceOf(alice) - beforeQuote, output);
            } else {
                assertEq(beforeQuote - quote6.balanceOf(alice), input);
                assertEq(stock.balanceOf(alice) - beforeStock, output);
            }
            uint256 shares = stockInput ? input : output;
            assertEq(ledger.used(SECURITY, DAY) - usedBefore, shares);
            usedBefore += shares;
        }
        vm.prank(alice);
        lpManager.closePosition(id, bounds);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(quote6.balanceOf(address(router)), 0);
        assertEq(quote6.balanceOf(address(lpManager)), 0);
    }
}

```

### test/integration/local/trading/HookCallbacks.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVTradingHookCallbacksTest is ProtocolFixture {
    function testSwapHooksRequireManagerRouterAndEmptyHookData() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, 4295128740);
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeSwap(address(router), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterSwap(address(router), key, p, BalanceDelta.wrap(0), "");
        for (uint8 i; i < 2; i++) {
            address sender = i == 0 ? alice : address(router);
            bytes memory data = i == 0 ? bytes("") : bytes(hex"01");
            vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
            vm.prank(address(manager));
            hook.beforeSwap(sender, key, p, data);
            vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
            vm.prank(address(manager));
            hook.afterSwap(sender, key, p, BalanceDelta.wrap(0), data);
        }
    }

    function testBeforeSwapReturnsZeroHookDeltaAndFeeOverride() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(router), key, IPoolManager.SwapParams(true, -1, 4295128740), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function testDonateCallbacksAreUnsupported() public {
        vm.expectRevert(TSVHookV1.UnsupportedCallback.selector);
        hook.beforeDonate(address(router), key, 1, 1, "");
        vm.expectRevert(TSVHookV1.UnsupportedCallback.selector);
        hook.afterDonate(address(router), key, 1, 1, "");
    }
}

```

### test/integration/local/liquidity/Liquidity.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVLiquidityLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVLiquidityLocalTest is ProtocolFixture {
    /// @dev Verifies the LP Manager issues a non-transferable position receipt.
    function testLpManagerHostsNonTransferableReceipt() public {
        assertEq(lpManager.ownerOf(positionId), alice);
        assertEq(lpManager.balanceOf(alice), 1);
        assertTrue(lpManager.supportsInterface(0x80ac58cd));

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.transferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.safeTransferFrom(alice, address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.approve(address(this), positionId);

        vm.expectRevert(TSVLPManagerV1.NonTransferable.selector);
        vm.prank(alice);
        lpManager.setApprovalForAll(address(this), true);
    }

    /// @dev Verifies backed stock LP increases and decreases settle raw token amounts.
    function testBackedStockLPIncreaseAndDecreaseSettleRawAmounts() public {
        stockUnderlying.setMultiplier(2e18, 1);

        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 usedBefore = ledger.used(SECURITY, DAY);

        uint256 aliceRawBefore = stock.balanceOf(alice);
        uint256 managerRawBefore = stock.balanceOf(address(manager));
        uint256 aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawIn = aliceRawBefore - stock.balanceOf(alice);
        assertGt(stockRawIn, 0);
        assertEq(stock.balanceOf(address(manager)) - managerRawBefore, stockRawIn);
        assertEq(aliceDisplayBefore - _displayBalance(alice), stockRawIn * 2);

        aliceRawBefore = stock.balanceOf(alice);
        managerRawBefore = stock.balanceOf(address(manager));
        aliceDisplayBefore = _displayBalance(alice);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        uint256 stockRawOut = stock.balanceOf(alice) - aliceRawBefore;
        assertGt(stockRawOut, 0);
        assertEq(managerRawBefore - stock.balanceOf(address(manager)), stockRawOut);
        assertEq(_displayBalance(alice) - aliceDisplayBefore, stockRawOut * 2);

        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
    }

    /// @dev Verifies LP increases revert when the owner loses more than the pool delta.
    function testLPIncreaseRevertsIfOwnerLosesMoreThanPoolDelta() public {
        quote.setSenderFee(alice, 100);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
    }

    /// @dev Verifies LP exits revert when the pool loses more than the output delta.
    function testLpExitRevertsIfPoolLosesMoreThanOutputDelta() public {
        quote.setSenderFee(address(manager), 100);
        uint256 ownerBefore = quote.balanceOf(alice);
        uint256 managerBefore = quote.balanceOf(address(manager));
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        LPBounds memory bounds;
        bounds.deadline = uint64(block.timestamp + 100);

        vm.expectRevert(TSVLPManagerV1.SettlementMismatch.selector);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);

        assertEq(quote.balanceOf(alice), ownerBefore);
        assertEq(quote.balanceOf(address(manager)), managerBefore);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    /// @dev Verifies position close enforces the minimum output for a zero-delta Currency.
    function testClosePositionEnforcesMinimumForZeroDeltaCurrency() public {
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        vm.prank(alice);
        uint256 boundaryPositionId = lpManager.openPosition(key, 0, 60, 1e18, bounds);

        bounds.minPoolOut1 = 1;
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.closePosition(boundaryPositionId, bounds);

        TSVLPManagerV1.Position memory position = lpManager.getPosition(boundaryPositionId);
        assertTrue(position.active);
        assertEq(position.liquidity, 1e18);
        assertEq(lpManager.ownerOf(boundaryPositionId), alice);
    }

    /// @dev Verifies the direct LP lifecycle does not record liquidity as trade volume.
    function testDirectLpLifecycleDoesNotRecordLiquidityAsTradeVolume() public {
        _assertDirectLpLifecycle();
    }
}

```

### test/integration/local/liquidity/PositionId.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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
        lpManager.initializePool(otherPool, uint160(1 << 96), keccak256("position-id-other-pool"));
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
        lpManager.forceExit(positionId, 0, 0, keccak256("position-id-revoke"), keccak256("position-id-evidence"));
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

```

### test/integration/local/liquidity/IssuerFailures.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

contract TSVIssuerLPFailuresTest is ProtocolFixture {
    function testRefusalOnEitherExitLegPreservesPositionFeesReceiptAndCanRetry() public {
        _seedPauseTestFees();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(quote) == Currency.unwrap(key.currency0), 1e18));
        // Each currency separately faults: this covers a failure on the first and second settlement leg.
        for (uint8 currency; currency < 2; currency++) {
            address token = Currency.unwrap(currency == 0 ? key.currency0 : key.currency1);
            vm.mockCallRevert(
                token,
                abi.encodeWithSelector(IERC20.transfer.selector, alice),
                abi.encodeWithSignature("Error(string)", "issuer refused owner")
            );
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.collectFees(positionId, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.decreaseLiquidity(positionId, 1e18, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            vm.expectRevert();
            vm.prank(alice);
            lpManager.closePosition(positionId, _pauseTestBounds());
            assertEq(_swapStateDigest(DAY), beforeState);
            sbt.setHolder(alice, false);
            vm.expectRevert();
            lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
            assertEq(_swapStateDigest(DAY), beforeState);
            sbt.setHolder(alice, true);
            vm.clearMockedCalls();
        }
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
    }
}

```

### test/integration/local/liquidity/ForceExit.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"), keccak256("evidence"));
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
        lpManager.forceExit(positionId, 1, 1, keccak256("incident"), keccak256("evidence"));
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
        lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
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
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        sbt.setHolder(alice, false);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
    }

    /// @dev Verifies failed SBT reads are not treated as revocation.
    function testSbtReadFailuresDoNotBecomeRevocationSignals() public {
        sbt.setFailReads(true, false);
        vm.expectRevert();
        registry.hasCredential(alice);
        vm.expectRevert();
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
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
        registry.setSbtConfig(address(quote), 1, keccak256("bad-sbt"));
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
        lpManager.forceExit(positionId, type(uint256).max, 0, keccak256("revoke"), keccak256("evidence"));

        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, 0, type(uint256).max, keccak256("revoke"), keccak256("evidence"));

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
            lpManager.forceExit(positionId, 1, 1, keccak256("pause-exit"), keccak256("evidence"));
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

        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable-token"));
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("approve-token"));
        registry.disablePool(PoolId.unwrap(key.toId()), keccak256("disable-pool"));
        _assertTradingBlocked();
        _assertOrdinaryLPBlocked();
    }
}

```

### test/integration/local/liquidity/Settlement.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Fault injection on LP funding, fee collection, closure, and forced exit.
contract TSVLiquiditySettlementTest is ProtocolFixture {
    function testFaultyTransferRollsBackAllOrdinaryLPActions() public {
        _seedPauseTestFees();
        vm.prank(alice);
        router.swapExactInput(_swapRequest(address(quote) == Currency.unwrap(key.currency0), 1e18));
        for (uint8 fault = 1; fault <= 3; fault++) {
            quote.setTransferMode(fault);
            for (uint8 action; action < 5; action++) {
                bytes32 beforeState = _swapStateDigest(DAY);
                vm.expectRevert();
                vm.prank(alice);
                _operate(action);
                assertEq(_swapStateDigest(DAY), beforeState);
                assertEq(lpManager.nextPositionId(), 2);
            }
        }
        quote.setTransferMode(0);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
    }

    function testForcedExitTokenFaultRollsBackAndCanRetry() public {
        sbt.setHolder(alice, false);
        for (uint8 fault = 1; fault <= 3; fault++) {
            quote.setTransferMode(fault);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert();
            lpManager.forceExit(positionId, 0, 0, keccak256("revoke"), keccak256("evidence"));
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setTransferMode(0);
        lpManager.forceExit(positionId, 1, 1, keccak256("revoke"), keccak256("evidence"));
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
        _assertNoPeripheryBalances();
    }

    function testNoReturnTokenSupportsCompleteLPLifecycle() public {
        quote.setTransferMode(4);
        vm.startPrank(alice);
        uint256 id = lpManager.openPosition(key, -600, 600, 1e19, _pauseTestBounds());
        lpManager.increaseLiquidity(id, 1e18, _pauseTestBounds());
        lpManager.decreaseLiquidity(id, 1e18, _pauseTestBounds());
        vm.stopPrank();
        _seedPauseTestFees();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        lpManager.collectFees(id, _pauseTestBounds());
        lpManager.closePosition(id, _pauseTestBounds());
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.balanceOf(alice), 1);
        _assertNoPeripheryBalances();
    }

    function testTokenReentryRejectsEveryLPEntryAndRollsBack() public {
        LPBounds memory b = _pauseTestBounds();
        for (uint8 i; i < 6; i++) {
            bytes memory data;
            if (i == 0) data = abi.encodeCall(TSVLPManagerV1.openPosition, (key, -600, 600, 1e18, b));
            if (i == 1) data = abi.encodeCall(TSVLPManagerV1.increaseLiquidity, (positionId, 1e18, b));
            if (i == 2) data = abi.encodeCall(TSVLPManagerV1.decreaseLiquidity, (positionId, 1e18, b));
            if (i == 3) data = abi.encodeCall(TSVLPManagerV1.collectFees, (positionId, b));
            if (i == 4) data = abi.encodeCall(TSVLPManagerV1.closePosition, (positionId, b));
            if (i == 5) {
                data = abi.encodeCall(
                    TSVLPManagerV1.forceExit, (positionId, 0, 0, keccak256("reason"), keccak256("evidence"))
                );
            }
            quote.setCallback(address(lpManager), data);
            bytes32 beforeState = _swapStateDigest(DAY);
            vm.expectRevert(TSVLPManagerV1.Reentrancy.selector);
            vm.prank(alice);
            lpManager.increaseLiquidity(positionId, 1e18, b);
            assertEq(_swapStateDigest(DAY), beforeState);
        }
        quote.setCallback(address(0), "");
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, b);
    }

    function testInsufficientAllowanceRollsBackOpenAndIncreaseThenRetry() public {
        vm.prank(alice);
        quote.approve(address(lpManager), 0);
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 2; i++) {
            vm.expectRevert();
            vm.prank(alice);
            _operate(i);
            assertEq(_swapStateDigest(DAY), beforeState);
            assertEq(lpManager.nextPositionId(), 2);
        }
        vm.prank(alice);
        quote.approve(address(lpManager), type(uint256).max);
        vm.prank(alice);
        _operate(1);
    }

    function _operate(uint8 action) internal {
        LPBounds memory b = _pauseTestBounds();
        if (action == 0) lpManager.openPosition(key, -600, 600, 1e18, b);
        else if (action == 1) lpManager.increaseLiquidity(positionId, 1e18, b);
        else if (action == 2) lpManager.decreaseLiquidity(positionId, 1e18, b);
        else if (action == 3) lpManager.collectFees(positionId, b);
        else lpManager.closePosition(positionId, b);
    }

    function _assertNoPeripheryBalances() internal view {
        assertEq(stock.balanceOf(address(lpManager)), 0);
        assertEq(quote.balanceOf(address(lpManager)), 0);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }
}

```

### test/integration/local/liquidity/Boundaries.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPBounds} from "tsv-v1/types/TSVTypes.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev LP input/ownership bounds and fee lifecycle with a real PoolManager.
contract TSVLiquidityBoundariesTest is ProtocolFixture {
    function testInvalidLiquidityAtOpenIncreaseAndDecreaseIsAtomic() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        LPBounds memory b = _pauseTestBounds();
        uint128[3] memory amounts = [uint128(0), uint128(type(int128).max) + 1, type(uint128).max];
        for (uint8 i; i < 3; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.openPosition(key, -600, 600, amounts[i], b);
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.increaseLiquidity(positionId, amounts[i], b);
        }
        uint128[3] memory decreases = [uint128(0), uint128(1e20), uint128(1e20 + 1)];
        for (uint8 i; i < 3; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.decreaseLiquidity(positionId, decreases[i], b);
        }
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, uint128(type(int128).max), b);
        assertEq(_swapStateDigest(DAY), beforeState);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testFuzzInvalidTicksDoNotAllocateReceipt(int24 tick, bool badUpper) public {
        tick = int24(bound(int256(tick), -887000, 887000));
        if (tick % 60 == 0) tick++;
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.openPosition(
            key, badUpper ? int24(-887220) : tick, badUpper ? tick : int24(887220), 1e18, _pauseTestBounds()
        );
        assertEq(_swapStateDigest(DAY), beforeState);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testTickOrderAndExtremeTicksReject() public {
        int24[4] memory lower = [int24(60), int24(60), int24(-887273), int24(-600)];
        int24[4] memory upper = [int24(60), int24(0), int24(600), int24(887273)];
        for (uint8 i; i < 4; i++) {
            vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
            vm.prank(alice);
            lpManager.openPosition(key, lower[i], upper[i], 1e18, _pauseTestBounds());
        }
    }

    function testEveryOrdinaryOperationRequiresOwnerAndActiveReceipt() public {
        address bob = makeAddr("bob");
        sbt.setHolder(bob, true);
        _rejectAllOwnerOperations(bob, positionId, TSVLPManagerV1.InvalidPosition.selector);
        _rejectAllOwnerOperations(alice, 999, TSVLPManagerV1.InvalidPosition.selector);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        _rejectAllOwnerOperations(alice, positionId, TSVLPManagerV1.InvalidPosition.selector);
        assertFalse(lpManager.getPosition(positionId).active);
        assertEq(lpManager.balanceOf(alice), 0);
    }

    function testEveryOrdinaryOperationRejectsExpiredDeadline() public {
        LPBounds memory b = _pauseTestBounds();
        b.deadline = uint64(block.timestamp - 1);
        bytes32 beforeState = _swapStateDigest(DAY);
        for (uint8 i; i < 5; i++) {
            vm.expectRevert(TSVLPManagerV1.Expired.selector);
            vm.prank(alice);
            _operate(i, positionId, b);
        }
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testDeadlineIsInclusiveForLiquidityChange() public {
        LPBounds memory b = _pauseTestBounds();
        b.deadline = uint64(block.timestamp);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, b);
        assertEq(lpManager.getPosition(positionId).liquidity, 101e18);
    }

    function testOpenRequiresEligibleUserAndKnownPool() public {
        LPBounds memory b = _pauseTestBounds();
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.openPosition(key, -600, 600, 1e18, b);
        PoolKey memory wrong = key;
        wrong.fee++;
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.openPosition(wrong, -600, 600, 1e18, b);
        assertEq(lpManager.nextPositionId(), 2);
    }

    function testEachInputAndOutputSlippageBoundRollsBackAndCanRetry() public {
        for (uint8 currency; currency < 2; currency++) {
            LPBounds memory b = _pauseTestBounds();
            if (currency == 0) b.maxPoolIn0 = 0;
            else b.maxPoolIn1 = 0;
            bytes32 beforeState = _swapStateDigest(DAY);
            for (uint8 action; action < 2; action++) {
                vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
                vm.prank(alice);
                _operate(action, positionId, b);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
            b = _pauseTestBounds();
            if (currency == 0) b.minPoolOut0 = type(uint256).max;
            else b.minPoolOut1 = type(uint256).max;
            for (uint8 action = 2; action < 5; action += 2) {
                vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
                vm.prank(alice);
                _operate(action, positionId, b);
                assertEq(_swapStateDigest(DAY), beforeState);
            }
        }
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e18, _pauseTestBounds());
        assertEq(lpManager.getPosition(positionId).liquidity, 99e18);
    }

    function testFeeCollectionWithoutFeesRollsBackAndSecondCollectionRejects() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.NoFees.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        _seedPauseTestFees();
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.NoFees.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
    }

    function testClosePaysPrincipalAndUncollectedFeesInOneOperation() public {
        _seedPauseTestFees();
        uint256 snapshot = vm.snapshotState();
        uint256 stockBefore = stock.balanceOf(alice);
        uint256 quoteBefore = quote.balanceOf(alice);
        vm.startPrank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        lpManager.closePosition(positionId, _pauseTestBounds());
        vm.stopPrank();
        uint256 collectedStock = stock.balanceOf(alice) - stockBefore;
        uint256 collectedQuote = quote.balanceOf(alice) - quoteBefore;
        vm.revertToState(snapshot);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        lpManager.closePosition(positionId, _pauseTestBounds());
        assertEq(stock.balanceOf(alice) - stockBefore, collectedStock);
        assertEq(quote.balanceOf(alice) - quoteBefore, collectedQuote);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
        assertEq(lpManager.balanceOf(alice), 0);
    }

    function testInactiveLPContextAndUnauthorizedCallbacksReject() public {
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.activeLPContext();
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.unlockCallback("");
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(address(manager));
        lpManager.unlockCallback("");
    }

    function testForceExitRequiresAuthorityReasonAndEvidenceAndCannotRepeat() public {
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.forceExit(positionId, 0, 0, 0, keccak256("evidence"));
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), 0);
        assertEq(_swapStateDigest(DAY), beforeState);
        lpManager.grantRole(lpManager.FORCE_EXIT_ADMIN_ROLE(), address(this));
        lpManager.revokeRole(lpManager.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        vm.expectRevert(TSVLPManagerV1.InvalidPosition.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
    }

    function _rejectAllOwnerOperations(address actor, uint256 id, bytes4 reason) internal {
        for (uint8 i = 1; i < 5; i++) {
            vm.expectRevert(reason);
            vm.prank(actor);
            _operate(i, id, _pauseTestBounds());
        }
    }

    function _operate(uint8 action, uint256 id, LPBounds memory b) internal {
        if (action == 0) lpManager.openPosition(key, -600, 600, 1e18, b);
        else if (action == 1) lpManager.increaseLiquidity(id, 1e18, b);
        else if (action == 2) lpManager.decreaseLiquidity(id, 1e18, b);
        else if (action == 3) lpManager.collectFees(id, b);
        else lpManager.closePosition(id, b);
    }
}

```

### test/integration/local/liquidity/DeltaGuards.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Defensive LP checks when an external PoolManager supplies invalid signed deltas.
contract TSVLPDeltaGuardsTest is ProtocolFixture {
    function testActiveCallbackRejectsTamperedRequestHashBeforePositionOrSettlementChanges() public {
        bytes memory originalCode = address(manager).code;
        bytes32 beforeState = _swapStateDigest(DAY);
        LPCallbackFaultManager faulty = new LPCallbackFaultManager();
        vm.etch(address(manager), address(faulty).code);
        vm.expectRevert(TSVLPManagerV1.Unauthorized.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        vm.etch(address(manager), originalCode);
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
    }

    function testSignedMinimumLiquidityInputRejectedBeforeSettlement() public {
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(type(int128).min, 0), BalanceDelta.wrap(0))
        );
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.InputAmountTooLarge.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
    }

    function testCollectAndForceExitCannotCreateNewOwnerDebt() public {
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-1, 1), BalanceDelta.wrap(0))
        );
        bytes32 beforeState = _swapStateDigest(DAY);
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, _pauseTestBounds());
        assertEq(_swapStateDigest(DAY), beforeState);
        sbt.setHolder(alice, false);
        vm.expectRevert(TSVLPManagerV1.SlippageExceeded.selector);
        lpManager.forceExit(positionId, 0, 0, keccak256("reason"), keccak256("evidence"));
        assertEq(_swapStateDigest(DAY), beforeState);
        vm.clearMockedCalls();
    }
}

/// @dev Negative-path dependency fixture; preserves the real manager's address as callback sender.
contract LPCallbackFaultManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return TSVLPManagerV1(msg.sender).unlockCallback(bytes.concat(data, hex"01"));
    }
}

```

### test/integration/local/liquidity/HookCallbacks.t.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev Independently verifies hook callback caller, context, operation mode, and zero return deltas.
contract TSVLPHookCallbacksTest is ProtocolFixture {
    using PoolIdLibrary for PoolKey;

    function testDirectHookLiquidityCallbacksRequirePoolManager() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeAddLiquidity(address(lpManager), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.beforeRemoveLiquidity(address(lpManager), key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterAddLiquidity(address(lpManager), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        hook.afterRemoveLiquidity(address(lpManager), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function testLiquidityHookRejectsForeignSenderAndNonemptyHookData() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(alice, key, p, "");
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(lpManager), key, p, hex"01");
    }

    function testHookRejectsEveryMismatchedLPContextField() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        for (uint8 i; i < 6; i++) {
            LPHookContext memory ctx = _context(1, LPOperationMode.INCREASE);
            if (i == 0) ctx.poolId = 0;
            if (i == 1) ctx.poolId = keccak256("another-pool");
            if (i == 2) ctx.salt = bytes32(uint256(999));
            if (i == 3) ctx.tickLower = -660;
            if (i == 4) ctx.tickUpper = 660;
            if (i == 5) ctx.liquidityDelta = 2;
            _mockContext(ctx);
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            vm.prank(address(manager));
            hook.beforeAddLiquidity(address(lpManager), key, p, "");
        }
        vm.clearMockedCalls();
    }

    function testHookRejectsWrongModeAndLiquiditySign() public {
        for (uint8 i; i < 4; i++) {
            int256 delta = i == 0 ? int256(0) : i == 1 ? int256(-1) : int256(1);
            LPOperationMode mode = i < 2 ? LPOperationMode.INCREASE : LPOperationMode.COLLECT;
            _mockContext(_context(delta, mode));
            IPoolManager.ModifyLiquidityParams memory p =
                IPoolManager.ModifyLiquidityParams(-600, 600, delta, bytes32(positionId));
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            vm.prank(address(manager));
            if (i < 3) hook.beforeAddLiquidity(address(lpManager), key, p, "");
            else hook.beforeRemoveLiquidity(address(lpManager), key, p, "");
        }
        _mockContext(_context(0, LPOperationMode.FORCE_EXIT));
        vm.expectRevert(TSVHookV1.InvalidOperation.selector);
        vm.prank(address(manager));
        hook.beforeRemoveLiquidity(
            address(lpManager), key, IPoolManager.ModifyLiquidityParams(-600, 600, 0, bytes32(positionId)), ""
        );
        vm.clearMockedCalls();
    }

    function testAfterLiquidityCallbacksReturnZeroDelta() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams(-600, 600, 1, bytes32(positionId));
        vm.prank(address(manager));
        (bytes4 selector, BalanceDelta delta) =
            hook.afterAddLiquidity(address(lpManager), key, p, BalanceDelta.wrap(1), BalanceDelta.wrap(2), "");
        assertEq(selector, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), 0);
        vm.prank(address(manager));
        (selector, delta) =
            hook.afterRemoveLiquidity(address(lpManager), key, p, BalanceDelta.wrap(1), BalanceDelta.wrap(2), "");
        assertEq(selector, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), 0);
    }

    function testHookInitializationRejectsEveryDependencyWithoutCodeAndCanRetry() public {
        TSVHookV1 isolated = TSVHookV1(address(uint160(0x7FFF)));
        _installProxy(address(isolated), address(new TSVHookV1()));
        for (uint256 i; i < 5; i++) {
            address[5] memory deps =
                [address(manager), address(registry), address(ledger), address(router), address(lpManager)];
            deps[i] = address(0);
            vm.expectRevert(TSVHookV1.InvalidOperation.selector);
            isolated.initialize(address(anchor), deps[0], deps[1], deps[2], deps[3], deps[4]);
        }
        isolated.initialize(
            address(anchor), address(manager), address(registry), address(ledger), address(router), address(lpManager)
        );
        assertEq(isolated.router(), address(router));
    }

    function testInitializeHookCallbacksRejectAlreadyActivePool() public {
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(lpManager), key, uint160(1 << 96));
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterInitialize(address(lpManager), key, uint160(1 << 96), 0);
    }

    function _context(int256 delta, LPOperationMode mode) internal view returns (LPHookContext memory) {
        return LPHookContext(PoolId.unwrap(key.toId()), -600, 600, mode, bytes32(positionId), delta);
    }

    function _mockContext(LPHookContext memory ctx) internal {
        vm.mockCall(address(lpManager), abi.encodeCall(TSVLPManagerV1.activeLPContext, ()), abi.encode(ctx));
    }
}

```

### test/helpers/v1/DexRouterTestAdapter.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";

/// @dev TEST ONLY: implements the actual DEX sellBase/sellQuote callback ABI.
///      The pinned v1.0.10 DEX appends two words; the last is ORIGIN_PAYER | original caller.
///      Eligibility comes from this authenticated marker, never tx.origin or a request field.
contract DexRouterTestAdapter {
    using SafeERC20 for IERC20;
    uint256 public constant ORIGIN_PAYER = 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;
    address public immutable dexRouter;
    TSVSwapRouterV1 public immutable tsvRouter;
    address public lastParticipant;
    uint256 public lastActualIn;
    uint256 public lastActualOut;
    bool private entered;

    error UnauthorizedDex();
    error InvalidMarker(uint256 marker, uint256 calldataLength, uint256 expectedLength);
    error InvalidRoute();
    error Reentrancy();

    constructor(address dex, TSVSwapRouterV1 router) {
        require(dex.code.length != 0 && address(router).code.length != 0);
        dexRouter = dex;
        tsvRouter = router;
    }

    function sellBase(address to, address pool, bytes calldata moreInfo) external {
        _sell(to, pool, moreInfo, true);
    }

    function sellQuote(address to, address pool, bytes calldata moreInfo) external {
        _sell(to, pool, moreInfo, false);
    }

    function _sell(address to, address pool, bytes calldata moreInfo, bool direction) private {
        if (msg.sender != dexRouter) revert UnauthorizedDex();
        if (entered) revert Reentrancy();
        entered = true;
        uint256 marker;
        assembly ("memory-safe") { marker := calldataload(sub(calldatasize(), 32)) }
        if (
            msg.data.length != 196 + ((moreInfo.length + 31) / 32) * 32
                || (marker & ~uint256(type(uint160).max)) != ORIGIN_PAYER || address(uint160(marker)) == address(0)
        ) revert InvalidMarker(marker, msg.data.length, 196 + ((moreInfo.length + 31) / 32) * 32);
        address participant = address(uint160(marker));
        SwapRequest memory request = abi.decode(moreInfo, (SwapRequest));
        if (pool != address(tsvRouter) || to == address(0) || request.zeroForOne != direction) revert InvalidRoute();
        IERC20 input = IERC20(Currency.unwrap(direction ? request.key.currency0 : request.key.currency1));
        IERC20 output = IERC20(Currency.unwrap(direction ? request.key.currency1 : request.key.currency0));
        // This fixture consumes only the route's declared amount. Existing donations stay untouched.
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));
        require(inputBefore >= request.amountSpecified);
        input.forceApprove(address(tsvRouter), request.amountSpecified);
        (uint256 actualIn, uint256 actualOut) = tsvRouter.swapExactInputFromAdapter(request, participant);
        input.forceApprove(address(tsvRouter), 0);
        require(inputBefore - input.balanceOf(address(this)) == actualIn);
        require(output.balanceOf(address(this)) - outputBefore == actualOut);
        output.safeTransfer(to, actualOut);
        uint256 refund = uint256(request.amountSpecified) - actualIn;
        if (refund != 0) input.safeTransfer(participant, refund);
        lastParticipant = participant;
        lastActualIn = actualIn;
        lastActualOut = actualOut;
        entered = false;
    }
}

/// @dev A contract participant makes the DEX call itself; the controlling EOA is not the trader.
contract DexRouterTestWallet {
    address public immutable admin;

    constructor(address owner) {
        admin = owner;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == admin);
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(returned, 32), mload(returned)) }
        return returned;
    }
}

```

### test/helpers/v1/MockIssuerTokens.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Provides a configurable issuer-share token fixture for tests.
contract V1MockIssuerShares is IERC20 {
    string public constant name = "TSLAx mock";
    string public constant symbol = "TSLAx";
    uint8 public constant decimals = 18;
    uint256 public multiplier = 1e18;
    uint256 public multiplierNonce;
    uint256 private totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) private allowances;
    bool public rejectReceiver;
    address public blocked;

    /// @dev Updates the mock issuer conversion multiplier and version nonce.
    function setMultiplier(uint256 value, uint256 nonce) external {
        multiplier = value;
        multiplierNonce = nonce;
    }

    /// @dev Configures whether the mock share token rejects transfers to a recipient.
    function setBlocked(address recipient, bool reject) external {
        blocked = recipient;
        rejectReceiver = reject;
    }

    /// @dev Mints mock issuer shares to the selected account.
    function mintShares(address to, uint256 shares) external {
        sharesOf[to] += shares;
        totalShares += shares;
    }

    /// @dev Returns the total mock issuer share supply.
    function totalSupply() external view returns (uint256) {
        return totalShares * multiplier / 1e18;
    }

    /// @dev Returns the mock issuer share balance of an account.
    function balanceOf(address owner) public view returns (uint256) {
        return sharesOf[owner] * multiplier / 1e18;
    }

    /// @dev Returns the mock issuer share allowance for a spender.
    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    /// @dev Sets the mock issuer share allowance for a spender.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Transfers mock issuer shares to a recipient.
    function transfer(address to, uint256 amount) external returns (bool) {
        return transferShares(to, amount * 1e18 / multiplier);
    }

    /// @dev Transfers mock issuer shares using an allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "allowance");
        allowances[from][msg.sender] -= amount;
        _move(from, to, amount * 1e18 / multiplier);
        return true;
    }

    /// @dev Transfers a fixed number of issuer shares using an allowance.
    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool) {
        uint256 displayed = getUnderlyingAmountByShares(shares);
        require(allowances[from][msg.sender] >= displayed, "display allowance");
        allowances[from][msg.sender] -= displayed;
        _move(from, to, shares);
        return true;
    }

    /// @dev Transfers a fixed number of issuer shares.
    function transferShares(address to, uint256 shares) public returns (bool) {
        _move(msg.sender, to, shares);
        return true;
    }

    /// @dev Converts mock issuer shares to their configured underlying amount.
    function getUnderlyingAmountByShares(uint256 shares) public view returns (uint256) {
        return shares * multiplier / 1e18;
    }

    /// @dev Returns the configured multiplier and its mock metadata.
    function getCurrentMultiplier() external view returns (uint256, uint256, uint256) {
        return (multiplier, 0, multiplierNonce);
    }

    /// @dev Updates mock share balances and emits the corresponding transfer event.
    function _move(address from, address to, uint256 shares) private {
        require(!rejectReceiver || to != blocked, "issuer refused owner");
        require(sharesOf[from] >= shares, "shares");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, getUnderlyingAmountByShares(shares));
    }
}

/// @dev Provides a wrapped ERC-20 fixture for issuer settlement tests.
contract V1MockIssuerWrapped is ERC20 {
    V1MockIssuerShares public immutable underlying;

    /// @dev Binds the issuer-share token used as the wrapped token underlying.
    constructor(V1MockIssuerShares token) ERC20("Wrapped TSLAx", "wTSLAx") {
        underlying = token;
    }

    /// @dev Returns the underlying asset associated with the wrapped token.
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @dev Mints mock wrapped-token shares for a test.
    function mintTestShares(address receiver, uint256 shares) external {
        _mint(receiver, shares);
    }

    /// @dev Mints wrapped tokens to a recipient after pulling the matching issuer shares.
    function mint(uint256 shares, address receiver) external returns (uint256) {
        require(underlying.transferSharesFrom(msg.sender, address(this), shares));
        _mint(receiver, shares);
        return underlying.getUnderlyingAmountByShares(shares);
    }

    /// @dev Redeems wrapped tokens for the configured underlying amount.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        require(underlying.transferShares(receiver, shares));
        return underlying.getUnderlyingAmountByShares(shares);
    }
}

```

### test/helpers/v1/LocalMocks.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";

/// @dev Exposes token metadata required by the local integration fixture.
interface ITestTokenMetadata {
    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() external view returns (uint8);
}

/// @dev Provides a configurable ERC-20 fixture for local protocol tests.
contract V1LocalERC20 is ERC20 {
    address public blockedRecipient;
    address public feeSender;
    uint16 public senderFeeBps;
    // Faults are opt-in and affect only integration tests.
    uint8 public transferMode;
    address public callbackTarget;
    bytes public callbackData;
    bool private inCallback;

    /// @dev Initializes the local token fixture with matching name and symbol.
    constructor(string memory n) ERC20(n, n) {}

    /// @dev Mints local test tokens to a recipient.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Configures whether the local token rejects transfers to a recipient.
    function setBlockedRecipient(address to) external {
        blockedRecipient = to;
    }

    /// @dev Configures the fee deducted from the sender by the local token.
    function setSenderFee(address sender, uint16 feeBps) external {
        require(feeBps <= 10_000);
        feeSender = sender;
        senderFeeBps = feeBps;
    }

    /// @dev 0=standard, 1=recipient tax, 2=false return, 3=short transfer, 4=no return data.
    function setTransferMode(uint8 mode) external {
        require(mode <= 4);
        transferMode = mode;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly { return(0, 0) }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly { return(0, 0) }
        return true;
    }

    /// @dev Applies the local token transfer behavior, including configured fees and restrictions.
    function _update(address from, address to, uint256 value) internal override {
        require(to == address(0) || to != blockedRecipient, "issuer blocked recipient");
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && transferMode == 1) {
            super._update(to, address(0), value / 100);
        }
        if (from != address(0) && to != address(0) && from == feeSender && senderFeeBps != 0) {
            uint256 fee = (value * senderFeeBps) / 10_000;
            if (fee != 0) super._update(from, address(this), fee);
        }
        if (from != address(0) && to != address(0) && callbackTarget != address(0) && !inCallback) {
            inCallback = true;
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            if (!ok) assembly { revert(add(result, 32), mload(result)) }
            inCallback = false;
        }
    }
}

/// @dev Provides configurable SBT pause and credential behavior for local tests.
contract V1LocalSBT {
    mapping(address => bool) public holds;
    bool private paused_;
    bool public failVerify;
    bool public failPaused;

    /// @dev Configures the holder and token identifier accepted by the local SBT fixture.
    function setHolder(address owner, bool value) external {
        holds[owner] = value;
    }

    /// @dev Configures the pause state reported by the local SBT fixture.
    function setPaused(bool value) external {
        paused_ = value;
    }

    /// @dev Configures whether SBT view calls revert in the local fixture.
    function setFailReads(bool verify_, bool pausedRead_) external {
        failVerify = verify_;
        failPaused = pausedRead_;
    }

    /// @dev Returns the pause state reported by the local SBT fixture.
    function paused() external view returns (bool) {
        require(!failPaused, "paused read failed");
        return paused_;
    }

    /// @dev Checks the configured participant credential in the local SBT fixture.
    function verify(address owner, uint256) external view returns (bool) {
        require(!failVerify, "verify read failed");
        return holds[owner];
    }
}

/// @dev Provides a contract-wallet participant for direct-call integration tests.
contract V1TestParticipantWallet {
    address public immutable admin;

    /// @dev Sets the account authorized to execute calls through the participant wallet.
    constructor(address admin_) {
        admin = admin_;
    }

    /// @dev Approves the Swap Router to transfer a selected input token.
    function approveToken(address token, address spender) external {
        require(msg.sender == admin);
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Runs an exact-input swap through the test participant wallet.
    function swapExactInput(TSVSwapRouterV1 router, SwapRequest calldata request)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        require(msg.sender == admin);
        return router.swapExactInput(request);
    }
}

/// @dev Routes a test swap through the Router's external Adapter entry.
contract V1TestExternalAdapter {
    /// @dev Approves the Router to pull the test Adapter's input Currency.
    function approveToken(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Executes a Router exact-input swap for the supplied participant.
    function swapExactInput(TSVSwapRouterV1 router, SwapRequest calldata request, address participant)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        return router.swapExactInputFromAdapter(request, participant);
    }
}

/// @dev Precision fixture for settlement in pools whose currencies have different decimals.
contract V1LocalERC20Decimals is V1LocalERC20 {
    uint8 private immutable precision;

    constructor(string memory name_, uint8 decimals_) V1LocalERC20(name_) {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }
}

```

### test/helpers/v1/FoundationMocks.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Provides a basic ERC-20 token fixture for unit tests.
contract V1MockToken is ERC20 {
    uint8 private immutable tokenDecimals;

    /// @dev Creates a test token with the requested name and decimal precision.
    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        tokenDecimals = decimals_;
    }

    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    /// @dev Returns the test multiplier used to convert displayed balances.
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }
}

/// @dev Provides a deliberately incomplete adapter fixture for validation tests.
contract V1SnapshotOnlyAdapterMock {
    address public immutable poolCurrency;
    uint32 public immutable adapterVersion;

    /// @dev Configures the currency and version exposed by the incomplete adapter fixture.
    constructor(address currency_, uint32 version_) {
        poolCurrency = currency_;
        adapterVersion = version_;
    }
}


```

### test/helpers/v1/GovernanceHandler.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVGovernanceAnchor, IAnchoredProxyV1} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Independent authority/state model for randomized sequences, including rejected operations.
contract GovernanceHandler is Test {
    TSVGovernanceAnchor public immutable anchor;
    address public immutable council;
    address public modelGovernor;
    address public modelGuardian;
    address public previousGovernor;
    address public previousGuardian;
    uint64 public modelEpoch;
    uint64 public modelGuardianEpoch;
    uint64 public modelFreezeEpoch;
    bool public modelFrozen;
    bytes32 public modelFreezeId;
    uint256 public successfulUpgrades;
    uint256 public successfulRecoveries;
    uint256 private nextIdentity;
    address[6] public proxies;
    address[6] public expectedImplementations;
    address[6] private originalImplementations;
    address[6] private replacements;
    bytes32[] private proposalIds;

    struct ProposalModel {
        address governor;
        address guardian;
        uint64 epoch;
        uint64 guardianEpoch;
        bool active;
        bool approved;
    }
    mapping(bytes32 => ProposalModel) private proposals;

    constructor(
        TSVGovernanceAnchor root,
        address[6] memory targets,
        address[6] memory originals,
        address[6] memory next
    ) {
        anchor = root;
        council = root.recoveryCouncil();
        modelGovernor = root.governor();
        modelGuardian = root.guardian();
        proxies = targets;
        originalImplementations = originals;
        expectedImplementations = originals;
        replacements = next;
    }

    function propose(uint256 actorSeed, bool rotateGuardian) external {
        address actor = _actor(actorSeed);
        address nextGovernor = address(uint160(0x10000 + ++nextIdentity));
        address nextGuardian = rotateGuardian ? address(uint160(0x10000 + ++nextIdentity)) : modelGuardian;
        bytes32 salt = keccak256(abi.encode(nextIdentity, actorSeed));
        bytes32 evidence = keccak256("handler-recovery");
        bytes32 id = keccak256(
            abi.encode(
                block.chainid,
                address(anchor),
                modelEpoch,
                modelGuardianEpoch,
                nextGovernor,
                nextGuardian,
                salt,
                evidence
            )
        );
        bool allowed = actor == council;
        bytes memory result = _attempt(
            actor,
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.proposeRecovery, (nextGovernor, nextGuardian, salt, evidence)),
            allowed
        );
        if (allowed) {
            assertEq(abi.decode(result, (bytes32)), id);
            proposals[id] = ProposalModel(nextGovernor, nextGuardian, modelEpoch, modelGuardianEpoch, true, false);
            proposalIds.push(id);
        }
    }

    function approve(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGuardian && proposal.active && _current(proposal);
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.approveRecovery, (id)), allowed);
        if (allowed) proposal.approved = true;
    }

    function revoke(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGuardian && proposal.approved;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.revokeRecoveryApproval, (id)), allowed);
        if (allowed) proposal.approved = false;
    }

    function cancel(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == council && proposal.active;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.cancelRecovery, (id)), allowed);
        if (allowed) proposal.active = false;
    }

    function recover(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        bool allowed = proposal.active && proposal.approved && _current(proposal);
        _attempt(_actor(actorSeed), address(anchor), abi.encodeCall(TSVGovernanceAnchor.executeRecovery, (id)), allowed);
        if (allowed) {
            previousGovernor = modelGovernor;
            modelGovernor = proposal.governor;
            if (modelGuardian != proposal.guardian) {
                previousGuardian = modelGuardian;
                modelGuardian = proposal.guardian;
                ++modelGuardianEpoch;
            }
            ++modelEpoch;
            ++successfulRecoveries;
            proposal.active = false;
            proposal.approved = false;
        }
    }

    function freeze(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        bytes32 reason = keccak256(abi.encode("handler-risk", actorSeed));
        bool allowed = actor == modelGuardian && !modelFrozen;
        bytes memory result =
            _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.freezeUpgrades, (reason)), allowed);
        if (allowed) {
            ++modelFreezeEpoch;
            modelFrozen = true;
            modelFreezeId =
                keccak256(abi.encode(block.chainid, address(anchor), modelFreezeEpoch, modelGuardian, reason));
            assertEq(abi.decode(result, (bytes32)), modelFreezeId);
        }
    }

    function unfreeze(uint256 actorSeed, bool wrongIncident, bool missingEvidence) external {
        address actor = _actor(actorSeed);
        bytes32 id = wrongIncident ? keccak256("wrong-incident") : modelFreezeId;
        bytes32 evidence = missingEvidence ? bytes32(0) : keccak256("handler-resolved");
        bool allowed = actor == modelGuardian && modelFrozen && !wrongIncident && !missingEvidence;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.unfreezeUpgrades, (id, evidence)), allowed);
        if (allowed) modelFrozen = false;
    }

    function upgradeSingle(uint256 actorSeed, uint8 proxySeed) external {
        uint256 index = proxySeed % 6;
        address next = _nextImplementation(index);
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGovernor && !modelFrozen;
        _attempt(actor, proxies[index], abi.encodeCall(IAnchoredProxyV1.upgradeToAndCall, (next, bytes(""))), allowed);
        if (allowed) {
            expectedImplementations[index] = next;
            ++successfulUpgrades;
        }
    }

    function upgradeBatch(uint256 actorSeed, uint8 countSeed) external {
        uint256 count = 1 + countSeed % 6;
        address[] memory targets = new address[](count);
        address[] memory implementations = new address[](count);
        for (uint256 i; i < count; ++i) {
            targets[i] = proxies[i];
            implementations[i] = _nextImplementation(i);
        }
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGovernor && !modelFrozen;
        _attempt(
            actor,
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (targets, implementations, new bytes[](count))),
            allowed
        );
        if (allowed) {
            for (uint256 i; i < count; ++i) {
                expectedImplementations[i] = implementations[i];
            }
            successfulUpgrades += count;
        }
    }

    function _attempt(address actor, address target, bytes memory data, bool allowed)
        private
        returns (bytes memory result)
    {
        vm.prank(actor);
        bool ok;
        (ok, result) = target.call(data);
        assertEq(ok, allowed, "operation diverged from governance model");
    }

    function _current(ProposalModel storage proposal) private view returns (bool) {
        return proposal.epoch == modelEpoch && proposal.guardianEpoch == modelGuardianEpoch;
    }

    function _proposal(uint256 seed) private view returns (bytes32) {
        return proposalIds.length == 0 ? keccak256("unknown-proposal") : proposalIds[seed % proposalIds.length];
    }

    function _nextImplementation(uint256 index) private view returns (address) {
        return expectedImplementations[index] == originalImplementations[index]
            ? replacements[index]
            : originalImplementations[index];
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 index = seed % 6;
        if (index == 0) return modelGovernor;
        if (index == 1) return modelGuardian;
        if (index == 2) return council;
        if (index == 3) return address(0xDEAD);
        if (index == 4) return previousGovernor == address(0) ? address(0xCAFE) : previousGovernor;
        return previousGuardian == address(0) ? address(0xBABE) : previousGuardian;
    }
}

```

### test/helpers/v1/TradingLPHandler.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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

```

### test/helpers/v1/OperationsFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "./FoundationFixture.sol";

/// @dev Report builders and snapshots only. Success-path V4 tests use ProtocolFixture.
abstract contract OperationsFixture is FoundationFixture {
    struct ReportMetadata {
        uint64 timestamp;
        uint64 deadline;
        uint64 sequence;
        uint64 version;
        bytes32 id;
        bytes32 source;
    }

    function _metadata(uint64 sequence, uint64 version, bytes32 id) internal view returns (ReportMetadata memory) {
        return ReportMetadata(
            uint64(block.timestamp), uint64(block.timestamp + 100), sequence, version, id, keccak256("source")
        );
    }

    function _reportPayload(uint8 kind, ReportMetadata memory m) internal view returns (bytes memory) {
        if (kind == 0) {
            MarketReport memory market =
                _market(m.version == 1 ? MarketAction.HALT : MarketAction.RESUME, m.sequence, m.id);
            market.mode = PauseMode.TRADE;
            market.sourceTimestamp = m.timestamp;
            market.submitDeadline = m.deadline;
            market.sourceHash = m.source;
            return abi.encodeCall(TSVDataInboxV1.submitMarketStatus, (market));
        }
        if (kind == 1) {
            AdtvReport memory adtv = _adtv(SECURITY, 1000e18, m.version, m.sequence, m.id);
            adtv.sourceTimestamp = m.timestamp;
            adtv.submitDeadline = m.deadline;
            adtv.sourceHash = m.source;
            return abi.encodeCall(TSVDataInboxV1.submitAdtv, (adtv));
        }
        QuotaReport memory quota = _quota(2e18, 1, m.version, m.sequence, m.id);
        quota.sourceTimestamp = m.timestamp;
        quota.submitDeadline = m.deadline;
        quota.sourceHash = m.source;
        return abi.encodeCall(TSVDataInboxV1.submitQuota, (quota));
    }

    function _callInbox(bytes memory payload) internal {
        (bool ok, bytes memory result) = address(inbox).call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function _reportState(bytes32 securityId, uint32 month, uint32 day, bytes32 candidateId)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        inbox.lastSequence(0, securityId),
                        inbox.lastSourceTimestamp(0, securityId),
                        inbox.lastSequence(1, securityId),
                        inbox.lastSourceTimestamp(1, securityId),
                        inbox.lastSequence(2, securityId),
                        inbox.lastSourceTimestamp(2, securityId),
                        inbox.reportIdUsed(candidateId)
                    )
                ),
                registry.getSecurity(securityId),
                registry.marketPauseMode(securityId),
                registry.marketSequence(securityId),
                ledger.adtvOf(securityId, month),
                ledger.quotaOf(securityId, day),
                ledger.used(securityId, day)
            )
        );
    }

    function _reportState(bytes32 candidateId) internal view returns (bytes32) {
        return _reportState(SECURITY, uint32(MONTH), DAY, candidateId);
    }

    /// @dev Unit-only Hook call: legal shares are explicit test inputs, independent of Adapter conversion.
    function _charge(uint256 shares) internal {
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? shares : 0,
            stock0 ? 0 : shares
        );
    }
}

```

### test/helpers/v1/SplitFactorFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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
            id,
            keccak256("split-announcement")
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

```

### test/helpers/v1/OperationsMocks.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Credential fixture distinguishes IDs; fault injection is confined to its view selectors.
contract OperationsSbt {
    mapping(address => mapping(uint256 => bool)) private credentials;
    bool public paused;
    bool public failVerify;

    function setCredential(address owner, uint256 tokenId, bool held) external {
        credentials[owner][tokenId] = held;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setFailVerify(bool value) external {
        failVerify = value;
    }

    function verify(address owner, uint256 tokenId) external view returns (bool) {
        require(!failVerify, "verify unavailable");
        return credentials[owner][tokenId];
    }
}

contract OperationsPausedOnlySbt {
    function paused() external pure returns (bool) {
        return false;
    }
}

contract OperationsVerifyOnlySbt {
    function verify(address, uint256) external pure returns (bool) {
        return true;
    }
}

```

### test/helpers/v1/DirectUpgradeMock.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev Adds a stateful upgrade initializer to test atomic upgrade-and-call.
contract V1RegistryUpgradeMock is TSVRegistryV1 {
    error UpgradeInitFailed();
    uint256 public upgradeMarker;

    function initializeV2(uint256 marker, bool fail) external reinitializer(2) onlyGovernor {
        upgradeMarker = marker;
        if (fail) revert UpgradeInitFailed();
    }
}


```

### test/helpers/v1/ProtocolFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {
    TokenConfig,
    TokenStatus,
    MarketAction,
    PauseScope,
    PauseMode,
    LPBounds,
    SwapRequest
} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "./MockIssuerTokens.sol";
import {ITestTokenMetadata, V1LocalERC20, V1LocalSBT, V1TestExternalAdapter} from "./LocalMocks.sol";

/// @dev ProtocolFixture scenarios; inherited fixtures contain no test functions.
abstract contract ProtocolFixture is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant HOOK_ADDRESS = address(uint160(0x3FFF));
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant SECURITY = keccak256("SEC_A");
    uint32 internal constant DAY = 20261001;

    PoolManager internal manager;
    TSVGovernanceAnchor internal anchor;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    TSVLPManagerV1 internal lpManager;
    V1LocalSBT internal sbt;
    V1MockIssuerShares internal stockUnderlying;
    V1MockIssuerWrapped internal stock;
    V1LocalERC20 internal quote;
    PoolKey internal key;
    address internal alice;
    uint256 internal positionId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public virtual {
        vm.warp(1_790_827_201);
        alice = makeAddr("alice");
        manager = new PoolManager(address(this));
        anchor = new TSVGovernanceAnchor(address(this), makeAddr("guardian"), makeAddr("council"));
        registry = TSVRegistryV1(
            _newProxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor))))
        );
        ledger = TSVVolumeLedgerV1(
            _newProxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
            )
        );
        inbox = TSVDataInboxV1(
            _newProxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
            )
        );
        sbt = new V1LocalSBT();
        sbt.setHolder(alice, true);
        registry.setSbtConfig(address(sbt), 1, keccak256("sbt-config"));
        router = TSVSwapRouterV1(
            _newProxy(
                address(new TSVSwapRouterV1()),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize, (address(anchor), address(manager), address(registry), address(ledger))
                )
            )
        );
        lpManager = TSVLPManagerV1(
            _newProxy(
                address(new TSVLPManagerV1()),
                abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), address(manager), address(registry)))
            )
        );
        hook = TSVHookV1(HOOK_ADDRESS);
        _installProxy(HOOK_ADDRESS, address(new TSVHookV1()));
        hook.initialize(
            address(anchor), address(manager), address(registry), address(ledger), address(router), address(lpManager)
        );
        registry.bindComponents(address(hook), address(lpManager), address(inbox));
        ledger.bindWriters(address(hook), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        lpManager.grantRole(lpManager.POOL_CREATOR_ROLE(), address(this));
        lpManager.grantRole(lpManager.REVOKE_EXIT_EXECUTOR_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 10_000, 10, keccak256("tier"));
        stockUnderlying = new V1MockIssuerShares();
        stock = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1LocalERC20("QUOTE");
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        registry.admitSecurity(
            SECURITY, keccak256("STDx"), 1, _config(address(stock), SECURITY, address(adapter)), keccak256("stock")
        );
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));
        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        lpManager.initializePool(key, uint160(1 << 96), keccak256("price"));
        stock.mintTestShares(alice, 1e24);
        quote.mint(alice, 1e24);
        vm.startPrank(alice);
        stock.approve(address(lpManager), type(uint256).max);
        quote.approve(address(lpManager), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        positionId = lpManager.openPosition(key, -600, 600, 1e20, bounds);
        vm.stopPrank();
        _submitReports();
    }

    function _swapStateDigest(uint32 day) internal view returns (bytes32) {
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, id);
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(manager, id);
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                StateLibrary.getLiquidity(manager, id),
                keccak256(
                    abi.encode(
                        stock.balanceOf(alice),
                        quote.balanceOf(alice),
                        stock.balanceOf(address(router)),
                        quote.balanceOf(address(router)),
                        stock.balanceOf(address(manager)),
                        quote.balanceOf(address(manager)),
                        stock.balanceOf(address(lpManager)),
                        quote.balanceOf(address(lpManager))
                    )
                ),
                keccak256(abi.encode(lpManager.getPosition(positionId))),
                lpManager.ownerOf(positionId),
                ledger.used(SECURITY, day)
            )
        );
    }

    function _assertDirectLpLifecycle() internal {
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        LPBounds memory bounds;
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
        vm.startPrank(alice);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedBefore);

        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
        uint256 usedAfterSwap = ledger.used(SECURITY, DAY);
        assertGt(usedAfterSwap, usedBefore);
        vm.startPrank(alice);
        lpManager.collectFees(positionId, bounds);
        lpManager.closePosition(positionId, bounds);
        vm.stopPrank();
        assertEq(ledger.used(SECURITY, DAY), usedAfterSwap);
        assertFalse(lpManager.getPosition(positionId).active);
        vm.expectRevert();
        lpManager.ownerOf(positionId);
    }

    /// @dev Implements the PoolManager unlock callback used to test direct swap access.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        PoolKey memory target = abi.decode(data, (PoolKey));
        manager.swap(target, IPoolManager.SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1), "");
        return "";
    }

    function _exercisePauseBehavior(PauseMode mode, bool marketPause) internal {
        _seedPauseTestFees();
        if (marketPause) _submitLocalMarket(MarketAction.HALT, mode);
        else _pauseLocal(PauseScope.POOL, PoolId.unwrap(key.toId()), mode);
        bytes32 poolId = PoolId.unwrap(key.toId());
        assertEq(registry.isTradable(poolId), mode == PauseMode.LP);
        assertEq(registry.isLPAllowed(poolId), mode == PauseMode.TRADE);
        if (mode == PauseMode.LP) _exerciseAllowedTrading();
        else _assertTradingBlocked();
        if (mode == PauseMode.TRADE) _exerciseAllowedLPLifecycle();
        else _assertOrdinaryLPBlocked();
    }

    function _seedPauseTestFees() internal {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        vm.prank(alice);
        router.swapExactInput(_swapRequest(stockInput, 1e18));
    }

    function _assertTradingBlocked() internal {
        SwapRequest memory request = _swapRequest(true, 1e16);
        request.limitAmount = 1e18;
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        router.swapExactInput(request);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        vm.prank(alice);
        router.swapExactOutput(request);
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        vm.expectRevert(TSVSwapRouterV1.InvalidPool.selector);
        adapter.swapExactInput(router, request, alice);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _assertOrdinaryLPBlocked() internal {
        LPBounds memory bounds = _pauseTestBounds();
        uint128 liquidityBefore = lpManager.getPosition(positionId).liquidity;
        uint256 nextId = lpManager.nextPositionId();
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.openPosition(key, -600, 600, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.increaseLiquidity(positionId, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.decreaseLiquidity(positionId, 1e18, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.collectFees(positionId, bounds);
        vm.expectRevert(TSVLPManagerV1.InvalidPool.selector);
        vm.prank(alice);
        lpManager.closePosition(positionId, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, liquidityBefore);
        assertEq(lpManager.nextPositionId(), nextId);
        assertEq(lpManager.ownerOf(positionId), alice);
    }

    function _exerciseAllowedTrading() internal {
        bool stockInput = address(stock) == Currency.unwrap(key.currency0);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) = router.swapExactInput(_swapRequest(stockInput, 1e16));
        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        SwapRequest memory request = _swapRequest(!stockInput, 1e15);
        request.limitAmount = 1e18;
        vm.prank(alice);
        (, amountOut) = router.swapExactOutput(request);
        assertEq(amountOut, 1e15);
        V1TestExternalAdapter adapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(adapter), true);
        _runAdapterSwap(adapter, stockInput);
        _runAdapterSwap(adapter, !stockInput);
        assertGt(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _exerciseAllowedLPLifecycle() internal {
        LPBounds memory bounds = _pauseTestBounds();
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        vm.startPrank(alice);
        uint256 newId = lpManager.openPosition(key, -600, 600, 1e18, bounds);
        lpManager.collectFees(positionId, bounds);
        lpManager.increaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 11e19);
        lpManager.decreaseLiquidity(positionId, 1e19, bounds);
        assertEq(lpManager.getPosition(positionId).liquidity, 1e20);
        lpManager.closePosition(positionId, bounds);
        lpManager.closePosition(newId, bounds);
        vm.stopPrank();
        assertFalse(lpManager.getPosition(positionId).active);
        assertFalse(lpManager.getPosition(newId).active);
        assertEq(ledger.used(SECURITY, DAY), usedBefore);
    }

    function _pauseLocal(PauseScope scope, bytes32 target, PauseMode mode) internal returns (uint256) {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"), keccak256("source"));
    }

    function _submitLocalMarket(MarketAction action, PauseMode mode) internal {
        uint64 sequence = registry.marketSequence(SECURITY) + 1;
        MarketReport memory report = MarketReport(
            SECURITY,
            action,
            mode,
            keccak256("reason"),
            keccak256("exchange"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            keccak256(abi.encode("pause-mode-report", action, mode, sequence)),
            keccak256("source")
        );
        inbox.submitMarketStatus(report);
    }

    function _pauseTestBounds() internal view returns (LPBounds memory bounds) {
        bounds.maxPoolIn0 = 1e22;
        bounds.maxPoolIn1 = 1e22;
        bounds.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Deploys and initializes a proxy for the supplied implementation and initializer data.
    function _installProxy(address target, address implementation) internal {
        vm.etch(target, type(TSVERC1967Proxy).runtimeCode);
        vm.store(target, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
    }

    /// @dev Deploys an initialized proxy for the supplied implementation.
    function _newProxy(address implementation, bytes memory data) internal returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    /// @dev Builds a token registration configuration for the supplied currency and security.
    function _config(address token, bytes32 securityId, address legalAdapter)
        internal
        view
        returns (TokenConfig memory c)
    {
        c.poolCurrency = token;
        uint8 tokenDecimals = ITestTokenMetadata(token).decimals();
        c.poolDecimals = tokenDecimals;
        c.securityId = securityId;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        // Stock classification follows securityId and the bound adapter.
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("backed-policy");
        c.status = TokenStatus.APPROVED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter == address(0) ? bytes32(0) : legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    /// @dev Reads an account balance in the token display denomination.
    function _displayBalance(address account) internal view returns (uint256) {
        return stockUnderlying.getUnderlyingAmountByShares(stock.balanceOf(account));
    }

    /// @dev Builds a swap request for the selected pool and trade parameters.
    function _swapRequest(bool zeroForOne, uint128 amount) internal view returns (SwapRequest memory r) {
        r.key = key;
        r.zeroForOne = zeroForOne;
        r.amountSpecified = amount;
        r.limitAmount = 1;
        r.deadline = uint64(block.timestamp + 100);
    }

    /// @dev Funds an approved test Adapter, executes one direction, and verifies exact balance settlement.
    function _runAdapterSwap(V1TestExternalAdapter adapter, bool zeroForOne) internal {
        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address outputToken = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        vm.prank(alice);
        IERC20(inputToken).transfer(address(adapter), 1e18);
        adapter.approveToken(inputToken, address(router));

        uint256 inputBefore = IERC20(inputToken).balanceOf(address(adapter));
        uint256 outputBefore = IERC20(outputToken).balanceOf(address(adapter));
        SwapRequest memory request = _swapRequest(zeroForOne, 1e18);
        (uint256 actualIn, uint256 actualOut) = adapter.swapExactInput(router, request, alice);

        assertGt(actualIn, 0);
        assertGt(actualOut, 0);
        assertEq(inputBefore - IERC20(inputToken).balanceOf(address(adapter)), actualIn);
        assertEq(IERC20(outputToken).balanceOf(address(adapter)) - outputBefore, actualOut);
    }

    /// @dev Submits the monthly ADTV report required by the test; admission already opens the market.
    function _submitReports() internal {
        uint64 now_ = uint64(block.timestamp);
        AdtvReport memory adtv =
            AdtvReport(SECURITY, 202609, 1e24, now_ - 1, now_ + 100, 1, 1, keccak256("adtv"), keccak256("source"));
        inbox.submitAdtv(adtv);
    }
}

```

### test/helpers/v1/UpgradeDeployment.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryV2, LedgerV2, InboxV2, HookV2, RouterV2, LPManagerV2} from "./GovernanceUpgradeMocks.sol";

/// @dev Matching V2 implementations in the canonical six-component binding order.
library UpgradeDeployment {
    function deployV2() internal returns (address[6] memory implementations) {
        return [
            address(new RegistryV2()),
            address(new LedgerV2()),
            address(new InboxV2()),
            address(new HookV2()),
            address(new RouterV2()),
            address(new LPManagerV2())
        ];
    }
}

```

### test/helpers/v1/GovernanceUpgradeMocks.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @dev Observable external side effect used to prove whole-transaction rollback.
contract MigrationJournal {
    uint256 public entries;

    function record() external {
        ++entries;
    }
}

/// @dev Example V2 migration: append storage and authorize Governor or an active Anchor batch.
abstract contract GovernanceMigrationV2 is Initializable {
    error MigrationFailed();
    error UnauthorizedMigration();
    uint256 public migrationMarker;
    address public migrationCaller;

    function initializeV2(uint256 marker, bool fail) external reinitializer(2) {
        _migrate(marker);
        if (fail) revert MigrationFailed();
    }

    function initializeAndRecord(MigrationJournal journal, uint256 marker) external reinitializer(2) {
        _migrate(marker);
        journal.record();
    }

    function initializeWithCall(address target, bytes calldata data) external reinitializer(2) {
        _migrate(1);
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function _migrate(uint256 marker) private {
        TSVGovernanceAnchor root = TSVGoverned(address(this)).governanceAnchor();
        if (msg.sender != root.governor() && !(msg.sender == address(root) && root.upgradeContextActive())) {
            revert UnauthorizedMigration();
        }
        migrationMarker = marker;
        migrationCaller = msg.sender;
    }
}

contract RegistryV2 is TSVRegistryV1, GovernanceMigrationV2 {}

contract LedgerV2 is TSVVolumeLedgerV1, GovernanceMigrationV2 {}

contract InboxV2 is TSVDataInboxV1, GovernanceMigrationV2 {}

contract HookV2 is TSVHookV1, GovernanceMigrationV2 {}

contract RouterV2 is TSVSwapRouterV1, GovernanceMigrationV2 {}

contract LPManagerV2 is TSVLPManagerV1, GovernanceMigrationV2 {}

contract WrongUUIDImplementation {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Exposes the protected internal role paths without changing production visibility.
contract GovernedRoleHarness is TSVGoverned {
    function initialize(address root) external initializer {
        __TSVGoverned_init(root);
    }

    function internalGrant(bytes32 role, address account) external onlyGovernor {
        _grantRole(role, account);
    }

    function internalRevoke(bytes32 role, address account) external onlyGovernor {
        _revokeRole(role, account);
    }
}

/// @dev Contract Governor fixture. The callback is explicitly armed only for reentry tests.
contract GovernorExecutor {
    address public immutable owner;
    address public callbackProxy;

    constructor(address owner_) {
        owner = owner_;
    }

    function armCallback(address proxy) external {
        require(msg.sender == owner);
        callbackProxy = proxy;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner || msg.sender == callbackProxy, "executor: unauthorized");
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

```

### test/helpers/v1/GovernanceFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev GovernanceFixture scenarios; inherited fixtures contain no test functions.
abstract contract GovernanceFixture is Test {
    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;

    function setUp() public virtual {
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        anchor = new TSVGovernanceAnchor(address(this), guardian, council);
    }

    function _proposeRecovery(address governor_, address guardian_, string memory salt) internal returns (bytes32) {
        vm.prank(council);
        return anchor.proposeRecovery(governor_, guardian_, keccak256(bytes(salt)), keccak256("evidence"));
    }

    function _newRegistryProxy() internal returns (TSVERC1967Proxy) {
        return
            new TSVERC1967Proxy(
                address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
            );
    }
}

```

### test/helpers/v1/OperationsHandler.sol — TEST SCENARIO COVERAGE ONLY

```solidity
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
            AdtvReport(SECURITY, month, value, m.timestamp, m.deadline, m.version, m.sequence, m.id, m.source);
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
        QuotaReport memory report = QuotaReport(
            SECURITY, _date(dayIndex), action, value, m.timestamp, m.deadline, m.version, m.sequence, m.id, m.source
        );
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
            m.id,
            m.source
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

    function schedule(uint32 rawOffset, uint8 daysAhead, bool emptyReason) external {
        uint32 offset = uint32(bound(rawOffset, 0, 86399));
        uint256 ordinal = (modelTime - OCTOBER_MIDNIGHT) / 1 days + daysAhead % 4;
        uint32 oldOffset = _offset(ordinal);
        uint256 shift = offset > oldOffset ? offset - oldOffset : oldOffset - offset;
        uint256 count = modelCheckpoints.length;
        bool existingPending = pending && modelTime < _start(modelCheckpoints[count - 1].ordinal);
        bool expected = !emptyReason && !existingPending && ordinal != 0 && offset != oldOffset && shift <= 4 hours;
        if (ordinal != 0) expected = expected && modelTime < _start(ordinal - 1);
        if (count != 0) expected = expected && ordinal > modelCheckpoints[count - 1].ordinal;
        bytes32 reason = emptyReason ? bytes32(0) : keccak256(abi.encode("model-schedule", attempt++));
        (bool ok,) =
            address(ledger).call(abi.encodeCall(TSVVolumeLedgerV1.scheduleDayStart, (offset, _date(ordinal), reason)));
        assertEq(ok, expected, "schedule acceptance differs from model");
        if (ok) {
            modelCheckpoints.push(Checkpoint(ordinal, offset));
            pending = true;
        }
    }

    function cancel(bool emptyReason) external {
        uint256 count = modelCheckpoints.length;
        bool expected = !emptyReason && pending && count != 0;
        if (count != 0) expected = expected && modelTime < _start(modelCheckpoints[count - 1].ordinal - 1);
        (bool ok,) = address(ledger)
            .call(
                abi.encodeCall(
                    TSVVolumeLedgerV1.cancelPendingDayStart, (emptyReason ? bytes32(0) : keccak256("model-cancel"))
                )
            );
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
            keccak256(abi.encode("model-report", ++attempt)),
            keccak256("source")
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

```

### test/helpers/v1/FoundationFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "./MockIssuerTokens.sol";
import {V1MockToken} from "./FoundationMocks.sol";

/// @dev FoundationFixture scenarios; inherited fixtures contain no test functions.
abstract contract FoundationFixture is Test {
    bytes32 internal constant SECURITY = keccak256("SEC_A");
    uint32 internal constant DAY = 20261001;
    uint64 internal constant MONTH = 202609;

    TSVGovernanceAnchor internal anchor;
    address internal guardian;
    address internal council;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    V1MockIssuerShares internal stockUnderlying;
    V1MockIssuerWrapped internal stock;
    V1MockToken internal quote;
    BackedAutoFeeLegalShareAdapter internal stockAdapter;
    PoolKey internal key;
    bytes32 internal poolId;

    /// @dev Initializes the contracts, accounts and fixture state shared by this test suite.
    function setUp() public virtual {
        vm.warp(1_790_827_201);
        guardian = makeAddr("guardian");
        council = makeAddr("council");
        anchor = new TSVGovernanceAnchor(address(this), guardian, council);
        registry = TSVRegistryV1(
            address(
                new ERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(anchor)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new ERC1967Proxy(
                    address(new TSVVolumeLedgerV1()),
                    abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
                )
            )
        );
        inbox = TSVDataInboxV1(
            address(
                new ERC1967Proxy(
                    address(new TSVDataInboxV1()),
                    abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
                )
            )
        );
        registry.bindComponents(address(this), address(this), address(inbox));
        ledger.bindWriters(address(this), address(inbox));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        inbox.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        inbox.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.setTierPolicy(1, 25, 10, keccak256("tier"));

        stockUnderlying = new V1MockIssuerShares();
        stock = new V1MockIssuerWrapped(stockUnderlying);
        quote = new V1MockToken("QUOTE6", 6);
        stockAdapter = new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        registry.admitSecurity(
            SECURITY, keccak256("STDx"), 1, _config(address(stock), SECURITY, address(stockAdapter)), keccak256("stock")
        );
        registry.registerToken(_config(address(quote), 0, address(0)), keccak256("quote"));

        address a = address(stock) < address(quote) ? address(stock) : address(quote);
        address b = address(stock) < address(quote) ? address(quote) : address(stock);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        poolId = registry.registerPendingPool(key);
        registry.markPoolActive(poolId, uint160(1 << 96), address(this), keccak256("price"));
    }

    function _grantPauseRoles() internal {
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
    }

    function _pauseTarget(PauseScope scope) internal view returns (bytes32) {
        if (scope == PauseScope.GLOBAL) return 0;
        if (scope == PauseScope.SECURITY) return SECURITY;
        if (scope == PauseScope.TOKEN) return bytes32(uint256(uint160(address(stock))));
        return poolId;
    }

    function _pause(PauseScope scope, bytes32 target, PauseMode mode) internal returns (uint256) {
        return registry.addEmergencyPause(scope, target, mode, keccak256("pause"), keccak256("source"));
    }

    function _assertOperationGates(bool tradeAllowed, bool lpAllowed) internal view {
        assertEq(registry.isTradable(poolId), tradeAllowed);
        assertEq(registry.isLPAllowed(poolId), lpAllowed);
    }

    function _assertMarketPause(PauseMode mode, bool tradeAllowed, bool lpAllowed) internal view {
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(mode));
        assertEq(
            uint8(registry.marketStatus(SECURITY)),
            uint8(mode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED)
        );
        _assertOperationGates(tradeAllowed, lpAllowed);
    }

    function _submitMarketMode(MarketAction action, PauseMode mode, uint64 sequence) internal {
        MarketReport memory report =
            _market(action, sequence, keccak256(abi.encode("market-mode", action, mode, sequence)));
        report.mode = mode;
        inbox.submitMarketStatus(report);
    }

    function _rejectMarketMode(MarketAction action, PauseMode mode, uint64 sequence, bytes4 expectedError) internal {
        MarketReport memory report =
            _market(action, sequence, keccak256(abi.encode("rejected-market-mode", action, mode, sequence)));
        report.mode = mode;
        uint64 previousSequence = registry.marketSequence(SECURITY);
        vm.expectRevert(expectedError);
        inbox.submitMarketStatus(report);
        assertEq(registry.marketSequence(SECURITY), previousSequence);
        assertEq(inbox.lastSequence(0, SECURITY), previousSequence);
        assertFalse(inbox.reportIdUsed(report.reportId));
    }

    function _admitAdditionalSecurity(bytes32 securityId, bytes32 symbolHash) internal {
        registry.admitSecurity(securityId, symbolHash, 1, _newStockConfig(securityId), keccak256("admission"));
    }

    function _newStockConfig(bytes32 securityId) internal returns (TokenConfig memory) {
        V1MockIssuerShares underlying = new V1MockIssuerShares();
        V1MockIssuerWrapped wrapped = new V1MockIssuerWrapped(underlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(underlying), address(wrapped), 1);
        return _config(address(wrapped), securityId, address(adapter));
    }

    /// @dev Builds a token registration configuration for the supplied currency and security.
    function _config(address token, bytes32 securityId, address legalAdapter)
        internal
        view
        returns (TokenConfig memory c)
    {
        c.poolCurrency = token;
        c.poolDecimals = IERC20Metadata(token).decimals();
        c.securityId = securityId;
        c.legalShareAdapter = legalAdapter;
        c.legalAdapterVersion = securityId == 0 ? 0 : 1;
        c.legalSharePolicyHash = securityId == 0 ? bytes32(0) : keccak256("share-policy");
        c.status = TokenStatus.APPROVED;
        c.poolRuntimeCodeHash = token.codehash;
        c.legalAdapterCodeHash = legalAdapter.codehash;
        c.reviewHash = keccak256("review");
    }

    /// @dev Builds a market-state report with the supplied action and sequence metadata.
    function _market(MarketAction action, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (MarketReport memory report)
    {
        report = MarketReport(
            SECURITY,
            action,
            PauseMode.ALL,
            keccak256("reason"),
            keccak256("exchange"),
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            sequence,
            reportId,
            keccak256("source")
        );
    }

    /// @dev Submits a market-state report to the data Inbox.
    function _submitMarket(MarketAction action, uint64 sequence, bytes32 reportId) internal {
        MarketReport memory report = _market(action, sequence, reportId);
        inbox.submitMarketStatus(report);
    }

    /// @dev Submits a monthly ADTV report for the configured security.
    function _submitAdtv(uint256 value) internal {
        AdtvReport memory report = _adtv(SECURITY, value, 1, 1, keccak256("adtv"));
        inbox.submitAdtv(report);
    }

    /// @dev Builds an ADTV report with the supplied value and replay-protection metadata.
    function _adtv(bytes32 securityId, uint256 value, uint64 version, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (AdtvReport memory)
    {
        return AdtvReport(
            securityId,
            uint32(MONTH),
            value,
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            version,
            sequence,
            reportId,
            keccak256("source")
        );
    }

    /// @dev Submits a daily quota override report for the configured security.
    function _submitQuota(uint256 value) internal {
        QuotaReport memory report = _quota(value, 1, 1, 1, keccak256("quota"));
        inbox.submitQuota(report);
    }

    /// @dev Builds a daily quota report with the supplied action and replay-protection metadata.
    function _quota(uint256 value, uint8 action, uint64 version, uint64 sequence, bytes32 reportId)
        internal
        view
        returns (QuotaReport memory)
    {
        return QuotaReport(
            SECURITY,
            DAY,
            action,
            value,
            uint64(block.timestamp - 1),
            uint64(block.timestamp + 100),
            version,
            sequence,
            reportId,
            keccak256("source")
        );
    }
}

```

### test/helpers/v1/SixProxyFixture.sol — TEST SCENARIO COVERAGE ONLY

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernanceFixture} from "./GovernanceFixture.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @dev Six real UUPS proxies. CREATE2 mining is tested separately by the factory suite.
abstract contract SixProxyFixture is GovernanceFixture {
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    TSVLPManagerV1 internal lp;
    address[6] internal businessProxies;

    struct UpgradePlan {
        address[] targets;
        address[] implementations;
        bytes[] calls;
    }

    function setUp() public virtual override {
        super.setUp();
        registry = TSVRegistryV1(address(_newRegistryProxy()));
        ledger = TSVVolumeLedgerV1(
            _proxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
            )
        );
        inbox = TSVDataInboxV1(
            _proxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
            )
        );
        router = TSVSwapRouterV1(
            _proxy(
                address(new TSVSwapRouterV1()),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize, (address(anchor), address(this), address(registry), address(ledger))
                )
            )
        );
        lp = TSVLPManagerV1(
            _proxy(
                address(new TSVLPManagerV1()),
                abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), address(this), address(registry)))
            )
        );
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook.initialize(
            address(anchor), address(this), address(registry), address(ledger), address(router), address(lp)
        );
        registry.bindComponents(address(hook), address(lp), address(inbox));
        ledger.bindWriters(address(hook), address(inbox));
        businessProxies =
            [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lp)];
        if (_bindInSetUp()) anchor.bindProxies(businessProxies);
    }

    function _bindInSetUp() internal pure virtual returns (bool) {
        return true;
    }

    function _proxy(address implementation, bytes memory data) internal returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    function _implementation(address proxy) internal view returns (address) {
        return TSVERC1967Proxy(payable(proxy)).tsvImplementation();
    }

    function _currentPlan(uint256 count) internal view returns (UpgradePlan memory plan) {
        plan.targets = new address[](count);
        plan.implementations = new address[](count);
        plan.calls = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            plan.targets[i] = businessProxies[i];
            plan.implementations[i] = _implementation(businessProxies[i]);
        }
    }

    function _execute(UpgradePlan memory plan) internal {
        anchor.upgradeBatch(plan.targets, plan.implementations, plan.calls);
    }

    function _assertImplementations(UpgradePlan memory plan) internal view {
        for (uint256 i; i < plan.targets.length; ++i) {
            assertEq(_implementation(plan.targets[i]), plan.implementations[i], "unexpected implementation");
        }
        assertFalse(anchor.upgradeContextActive(), "batch context leaked");
    }
}

```

