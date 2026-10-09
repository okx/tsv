// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    SbtIdentityConfig,
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig,
    PermissionedAdmission,
    SecurityConfig,
    PoolConfig,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

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
    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    /// @dev Stores the listing limit and quota multiplier for a security tier.
    struct TierPolicy {
        /// @dev ADTV hard-cap multiplier in basis points.
        uint16 tierBps;
        /// @dev Maximum number of securities that may be listed in this tier.
        uint32 maxListed;
        /// @dev Number of securities currently assigned to this tier.
        uint32 listedCount;
    }

    /// @dev Records the reason, operator and timing associated with an emergency pause.
    struct EmergencyPause {
        /// @dev Scope of the pause, such as one token, security, pool, or all pools.
        PauseScope scope;
        /// @dev Scope-specific target identifier; zero for a global pause.
        bytes32 target;
        /// @dev Trading, ordinary LP operations, or both blocked by this record.
        PauseMode mode;
        /// @dev Operational reason assigned to the pause.
        bytes32 reasonCode;
        /// @dev Account that opened the pause.
        address openedBy;
        /// @dev Timestamp when the pause was opened.
        uint64 openedAt;
        /// @dev Whether this pause currently blocks operations.
        bool active;
    }

    // Bound venue and permissioned-pool dependencies.
    address public permissionsAdapterFactory;
    address public permissionedPoolManager;
    address public hook;
    address public lpManager;
    address public dataInbox;
    address public participantSbt;

    // Registered participant identities and their operation permissions.
    mapping(uint256 => SbtIdentityConfig) public sbtIdentityConfig;
    uint256[] private identityTokenIds;

    // Security admission and tier capacity.
    mapping(bytes32 => SecurityConfig) private securities;
    mapping(uint8 => TierPolicy) private tiers;

    // W/U/Q admission and configuration. Each W references its shared U record.
    mapping(address => PermissionedCurrencyConfig) private currencies;
    mapping(address => UnderlyingConfig) private underlyings;
    mapping(address => QuoteTokenConfig) private quoteTokens;
    mapping(address => bool) public isPermissionedOwnerApproved;
    /// @notice Shared exit receiver, keyed by underlying U.
    mapping(address => address) public exitAdminOf;
    mapping(address => address[]) private currenciesByUnderlying;

    // Registered pool keys and their permanent security associations.
    mapping(bytes32 => PoolConfig) private pools;

    // Market reports and emergency pause records.
    mapping(bytes32 => uint64) public marketSequence;
    mapping(uint256 => EmergencyPause) public emergencyPauses;
    /// @notice Number of active records for exactly the specified scope, target, and mode.
    mapping(uint8 => mapping(bytes32 => mapping(uint8 => uint256))) public activePauseCount;
    /// @notice Current market pause mask; admitted securities default to NONE.
    mapping(bytes32 => PauseMode) public marketPauseMode;
    uint256 public nextPauseId;

    /// @notice Emitted when core component addresses were bound to the Registry.
    event ComponentsBound(
        address indexed hook,
        address indexed lpManager,
        address indexed dataInbox,
        address factory,
        address poolManager,
        address sbt
    );
    /// @notice Emitted when a security was added to the Registry with its listing tier.
    event SecurityListed(bytes32 indexed securityId, uint8 tierId);
    /// @notice Emitted when a security was removed from the active listing set.
    event SecurityDelisted(bytes32 indexed securityId);
    /// @notice Emitted when a listed security was assigned a different tier.
    event SecurityTierChanged(bytes32 indexed securityId, uint8 oldTierId, uint8 newTierId);
    /// @notice Emitted when a security tier policy was created or updated.
    event TierPolicyChanged(uint8 indexed tierId, uint16 tierBps, uint32 maxListed);
    event UnderlyingBound(
        address indexed underlying, bytes32 indexed securityId, address legalShareAdapter, uint8 rawDecimals
    );
    event PermissionedCurrencyRegistered(
        address indexed currency, address indexed underlying, bytes32 indexed securityId
    );
    event QuoteTokenRegistered(address indexed quote, uint8 rawDecimals);
    event UnderlyingLegalShareAdapterChanged(address indexed underlying, address oldAdapter, address newAdapter);
    event PermissionedOwnerApprovalChanged(address indexed owner, bool approved);
    event PermissionedExpectedOwnerChanged(address indexed currency, address oldOwner, address newOwner);
    event ExitAdminUpdated(address indexed underlying, address oldAdmin, address newAdmin);
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
    /// @notice Emitted when an identity is registered or its operation permissions are updated.
    event SbtConfigChanged(address indexed sbt, uint256 indexed tokenId, PermissionFlag permissions);

    /// @notice Initializes governance and starts emergency-pause IDs at one.
    /// @param anchor Fixed governance Anchor used by the governed base contract.
    function initialize(address anchor) external initializer {
        __TSVGoverned_init(anchor);
        nextPauseId = 1;
    }

    // Component binding.
    /// @notice Binds Registry dependencies once, after all components are deployed.
    /// @param hook_ TSV Hook authorized for pool callbacks.
    /// @param lpManager_ LP Manager authorized to register exact pool keys before initialization.
    /// @param dataInbox_ DataInbox authorized to apply market reports.
    /// @param factory Real issuer Factory used to verify W provenance and derive PoolManager.
    /// @param sbt_ Fixed SBT contract supplying participant identities.
    function bindComponents(address hook_, address lpManager_, address dataInbox_, address factory, address sbt_)
        external
        onlyGovernor
    {
        if (permissionsAdapterFactory != address(0)) revert InvalidStatus();
        if (
            hook_.code.length == 0 || lpManager_.code.length == 0 || dataInbox_.code.length == 0
                || factory.code.length == 0 || sbt_.code.length == 0
        ) {
            revert InvalidConfig();
        }
        try ISmartWalletSbtV1(sbt_).paused() returns (bool) {}
        catch {
            revert InvalidConfig();
        }
        try ISmartWalletSbtV1(sbt_).verify(address(this), 0) returns (bool) {}
        catch {
            revert InvalidConfig();
        }
        address poolManager = IPermissionsAdapterFactory(factory).POOL_MANAGER();
        if (poolManager.code.length == 0) revert InvalidConfig();
        hook = hook_;
        lpManager = lpManager_;
        dataInbox = dataInbox_;
        permissionsAdapterFactory = factory;
        permissionedPoolManager = poolManager;
        participantSbt = sbt_;
        emit ComponentsBound(hook_, lpManager_, dataInbox_, factory, poolManager, sbt_);
    }

    /// @notice Returns the stateless validator address linked into this implementation.
    function permissionedValidationLibrary() external pure returns (address) {
        return address(PermissionedValidationLib);
    }

    // SBT identities and operation permissions.
    /// @notice Registers one identity or updates its swap/LP permissions on the bound SBT.
    /// @param tokenId Identity to register or update.
    /// @param permissions TSV operation flags: NONE, SWAP_ALLOWED, LIQUIDITY_ALLOWED, or their union.
    function setSbtConfig(uint256 tokenId, PermissionFlag permissions) external onlyGovernor {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        if (uint16(PermissionFlag.unwrap(permissions)) > 3) revert InvalidConfig();
        try ISmartWalletSbtV1(participantSbt).verify(address(this), tokenId) returns (bool) {}
        catch {
            revert InvalidConfig();
        }
        if (!sbtIdentityConfig[tokenId].registered) identityTokenIds.push(tokenId);
        sbtIdentityConfig[tokenId] = SbtIdentityConfig(true, permissions);
        emit SbtConfigChanged(participantSbt, tokenId, permissions);
    }

    /// @notice Enumerates registered identities, including identities with both permissions disabled.
    function sbtTokenIds() external view returns (uint256[] memory) {
        return identityTokenIds;
    }

    /// @notice Checks a registered identity independently of operation permissions and global pause.
    function hasIdentity(address owner, uint256 tokenId) external view returns (bool) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        if (!sbtIdentityConfig[tokenId].registered) revert InvalidConfig();
        return ISmartWalletSbtV1(participantSbt).verify(owner, tokenId);
    }

    /// @notice Whether `owner` holds any registered identity; permissions and pause do not affect this view.
    function hasCredential(address owner) public view returns (bool held) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        (held,) = _credentialState(owner);
    }

    /// @notice Active operation permissions, combining every held identity; paused SBT returns NONE.
    function permissionsOf(address owner) public view returns (PermissionFlag permissions) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        if (ISmartWalletSbtV1(participantSbt).paused()) return PermissionFlags.NONE;
        (, permissions) = _credentialState(owner);
    }

    /// @notice Checks TSV identity permissions.
    /// @param permission SWAP_ALLOWED or LIQUIDITY_ALLOWED.
    /// @param account Participant whose permissions are checked.
    function isAllowed(PermissionFlag permission, address account) external view returns (bool) {
        if (!(permission == PermissionFlags.SWAP_ALLOWED || permission == PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert InvalidConfig();
        }
        return (permissionsOf(account) & permission) == permission;
    }

    // Securities and tier capacity.
    /// @notice Sets a tier's quota multiplier and maximum number of listed securities.
    /// @param tierId Nonzero tier identifier.
    /// @param tierBps Volume multiplier in basis points, from 1 through 10,000.
    /// @param maxListed Maximum number of securities that may be listed in this tier.
    function setTierPolicy(uint8 tierId, uint16 tierBps, uint32 maxListed) external onlyGovernor {
        TierPolicy storage tier = tiers[tierId];
        if (tierId == 0 || tierBps == 0 || tierBps > 10_000 || maxListed < tier.listedCount) {
            revert InvalidConfig();
        }
        tier.tierBps = tierBps;
        tier.maxListed = maxListed;
        emit TierPolicyChanged(tierId, tierBps, maxListed);
    }

    /// @notice Returns the quota and listing-cap policy currently configured for `tierId`.
    /// @param tierId Tier identifier to query.
    /// @return Multiplier, capacity, and current listing count.
    function tierPolicy(uint8 tierId) external view returns (TierPolicy memory) {
        return tiers[tierId];
    }

    /// @notice Atomically lists a security and admits its first stock W.
    function admitPermissionedSecurity(uint8 tierId, PermissionedAdmission calldata admission)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        if (admission.securityId == 0 || securities[admission.securityId].securityId != 0) {
            revert InvalidConfig();
        }
        _takeTierSlot(tierId);
        securities[admission.securityId] = SecurityConfig(admission.securityId, tierId, true);
        emit SecurityListed(admission.securityId, tierId);
        _registerPermissionedCurrency(admission);
    }

    /// @notice Relists a delisted security under its existing tier.
    /// @param securityId Existing security to relist.
    function relistSecurity(bytes32 securityId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (config.securityId == 0 || config.listed) revert InvalidStatus();
        _takeTierSlot(config.tierId);
        config.listed = true;
        emit SecurityListed(securityId, config.tierId);
    }

    /// @notice Moves a listed security to another tier and updates both tier listing counts.
    /// @param securityId Listed security whose tier changes.
    /// @param tierId Configured destination tier with available capacity.
    function setSecurityTier(bytes32 securityId, uint8 tierId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed || config.tierId == tierId) revert InvalidStatus();
        _takeTierSlot(tierId);
        tiers[config.tierId].listedCount--;
        uint8 oldTierId = config.tierId;
        config.tierId = tierId;
        emit SecurityTierChanged(securityId, oldTierId, tierId);
    }

    /// @notice Delists a security, blocking ordinary operations across all its registered pools.
    /// @param securityId Listed security to remove from admission.
    function delistSecurity(bytes32 securityId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed) revert InvalidStatus();
        config.listed = false;
        tiers[config.tierId].listedCount--;
        emit SecurityDelisted(securityId);
    }

    /// @notice Returns the stored listing and tier for a security.
    /// @param securityId Security identifier to query.
    /// @return Stored security record; unknown IDs return a default record.
    function getSecurity(bytes32 securityId) external view returns (SecurityConfig memory) {
        return securities[securityId];
    }

    // W, U, and Q admission and configuration.
    /// @notice Adds a stock W to an already listed security, sharing its U configuration.
    function registerPermissionedCurrency(PermissionedAdmission calldata admission)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        _registerPermissionedCurrency(admission);
    }

    /// @notice Registers an original quote ERC-20; stock identities cannot become quotes.
    function registerQuoteToken(address quote) external onlyRole(SYMBOL_ADMIN_ROLE) {
        _requireEnvironment();
        if (quoteTokens[quote].registered) revert InvalidStatus();
        PermissionedValidationLib.validateQuoteIdentity(quote);
        uint8 rawDecimals = PermissionedValidationLib.readDecimals(quote);
        quoteTokens[quote] = QuoteTokenConfig(rawDecimals, true);
        emit QuoteTokenRegistered(quote, rawDecimals);
    }

    function setPermissionedOwnerApproval(address owner, bool approved) external onlyGovernor {
        if (owner == address(0) || (approved && owner.code.length == 0)) revert PermissionedPolicyMismatch();
        isPermissionedOwnerApproved[owner] = approved;
        emit PermissionedOwnerApprovalChanged(owner, approved);
    }

    function updatePermissionedExpectedOwner(address w, address newOwner) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PermissionedCurrencyConfig storage config = currencies[w];
        if (config.underlying == address(0) || newOwner == config.expectedOwner) revert InvalidStatus();
        bytes32 securityId = underlyings[config.underlying].securityId;
        // A TOKEN, SECURITY, or GLOBAL pause must cover both ordinary operation types.
        if (
            !(_isPaused(PauseScope.TOKEN, _addressKey(w), PauseMode.TRADE)
                    || _securityPausedForReplacement(securityId, PauseMode.TRADE))
                || !(_isPaused(PauseScope.TOKEN, _addressKey(w), PauseMode.LP)
                    || _securityPausedForReplacement(securityId, PauseMode.LP))
        ) revert InvalidStatus();
        PermissionedValidationLib.validateOwner(w, config.underlying, newOwner);
        address previousExpectedOwner = config.expectedOwner;
        config.expectedOwner = newOwner;
        emit PermissionedExpectedOwnerChanged(w, previousExpectedOwner, newOwner);
    }

    /// @notice Replaces the canonical U converter while the entire security is paused for trade and LP.
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter) external onlyRole(SYMBOL_ADMIN_ROLE) {
        UnderlyingConfig storage config = underlyings[u];
        if (
            config.securityId == 0 || newAdapter == config.legalShareAdapter
                || !_securityPausedForReplacement(config.securityId, PauseMode.TRADE)
                || !_securityPausedForReplacement(config.securityId, PauseMode.LP)
        ) revert InvalidConfig();
        PermissionedValidationLib.validateLegalShareAdapter(newAdapter, u);
        address previousAdapter = config.legalShareAdapter;
        config.legalShareAdapter = newAdapter;
        emit UnderlyingLegalShareAdapterChanged(u, previousAdapter, newAdapter);
    }

    /// @notice Configures the receiver shared by every W for underlying U, including before first admission.
    function setExitAdmin(address u, address newAdmin) external onlyGovernor {
        _requireEnvironment();
        if (newAdmin == exitAdminOf[u]) revert InvalidStatus();
        PermissionedValidationLib.validateExitAdmin(u, newAdmin, currenciesByUnderlying[u]);
        address previousExitAdmin = exitAdminOf[u];
        exitAdminOf[u] = newAdmin;
        emit ExitAdminUpdated(u, previousExitAdmin, newAdmin);
    }

    function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory) {
        return currencies[w];
    }

    function getUnderlying(address u) external view returns (UnderlyingConfig memory) {
        return underlyings[u];
    }

    function getQuoteToken(address quote) external view returns (QuoteTokenConfig memory) {
        return quoteTokens[quote];
    }

    // Pool registration and lookup.
    /// @notice Registers the exact key before the LP Manager initializes it in the same transaction.
    /// @param key Candidate V4 pool key.
    /// @return poolId Identifier derived from the full pool key.
    function registerPool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (msg.sender != lpManager) revert InvalidPool();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != hook || currency0 == address(0) || currency0 >= currency1 || key.fee >= 1_000_000
                || key.tickSpacing < 1 || key.tickSpacing > 32767 || !_assetAllowed(currency0)
                || !_assetAllowed(currency1)
        ) revert InvalidPool();
        bytes32 securityId0 = underlyings[currencies[currency0].underlying].securityId;
        bytes32 securityId1 = underlyings[currencies[currency1].underlying].securityId;
        if ((securityId0 == 0) == (securityId1 == 0)) revert InvalidPool();
        poolId = PoolId.unwrap(key.toId());
        if (isKnownPool(poolId)) revert InvalidPool();
        pools[poolId] = PoolConfig(key, securityId0, securityId1);
    }

    /// @notice Returns the registered key and permanent securities for a pool.
    /// @param poolId Pool identifier to query.
    /// @return Stored pool record; unknown IDs return a default record.
    function getPool(bytes32 poolId) external view returns (PoolConfig memory) {
        return pools[poolId];
    }

    /// @notice Returns whether the pool has been registered, including pools of delisted securities.
    /// @param poolId Pool identifier to query.
    /// @return Whether a nonzero first Currency is stored for this pool.
    function isKnownPool(bytes32 poolId) public view returns (bool) {
        return Currency.unwrap(pools[poolId].key.currency0) != address(0);
    }

    // Market state and emergency pauses.
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
        PauseMode previousPauseMode = marketPauseMode[securityId];
        MarketStatus previousStatus = previousPauseMode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED;
        PauseMode nextPauseMode;
        if (action == MarketAction.HALT) {
            nextPauseMode = PauseMode(uint8(previousPauseMode) | uint8(mode));
        } else {
            nextPauseMode = PauseMode(uint8(previousPauseMode) & ~uint8(mode));
        }
        if (nextPauseMode == previousPauseMode) revert InvalidStatus();
        MarketStatus nextStatus = nextPauseMode == PauseMode.NONE ? MarketStatus.OPEN : MarketStatus.HALTED;
        marketPauseMode[securityId] = nextPauseMode;
        marketSequence[securityId] = sequence;
        emit MarketStatusChanged(
            securityId,
            uint8(previousStatus),
            uint8(nextStatus),
            uint8(previousPauseMode),
            uint8(nextPauseMode),
            sequence,
            reportId
        );
    }

    /// @notice Opens a scoped emergency pause and returns its record ID.
    /// @param scope GLOBAL, SECURITY, TOKEN, or POOL pause scope.
    /// @param target Scope-specific target key; zero only for GLOBAL.
    /// @param mode TRADE, LP, or ALL; NONE cannot open a pause record.
    /// @param reasonCode Nonzero operational reason code.
    /// @return recordId New emergency-pause record identifier.
    function addEmergencyPause(PauseScope scope, bytes32 target, PauseMode mode, bytes32 reasonCode)
        external
        onlyRole(EMERGENCY_PAUSER_ROLE)
        returns (uint256 recordId)
    {
        if (
            mode == PauseMode.NONE || reasonCode == 0 || (scope == PauseScope.GLOBAL && target != 0)
                || (scope != PauseScope.GLOBAL && target == 0)
        ) revert InvalidConfig();
        recordId = nextPauseId++;
        emergencyPauses[recordId] =
            EmergencyPause(scope, target, mode, reasonCode, msg.sender, uint64(block.timestamp), true);
        activePauseCount[uint8(scope)][target][uint8(mode)]++;
        emit EmergencyPauseOpened(recordId, uint8(scope), target, uint8(mode), reasonCode);
    }

    /// @notice Closes an active emergency-pause record and decrements its scope's active count.
    /// @param recordId Active pause record to close.
    /// @param reasonCode Nonzero reason code for clearing the pause.
    function clearEmergencyPause(uint256 recordId, bytes32 reasonCode) external onlyRole(EMERGENCY_RESUMER_ROLE) {
        EmergencyPause storage record = emergencyPauses[recordId];
        if (!record.active || reasonCode == 0) revert InvalidStatus();
        // TOKEN recovery rechecks admitted assets; unknown targets may still have preemptive pauses.
        if (record.scope == PauseScope.TOKEN) _validateAssetForRecovery(address(uint160(uint256(record.target))));
        record.active = false;
        activePauseCount[uint8(record.scope)][record.target][uint8(record.mode)]--;
        emit EmergencyPauseClosed(recordId, reasonCode);
    }

    /// @notice Returns whether a registered pool permits swaps after admission and trading-pause checks.
    /// @param poolId Pool identifier to check.
    /// @return Whether pool and asset admission checks pass and no trading pause applies.
    function isTradable(bytes32 poolId) external view returns (bool) {
        return _isOperationAllowed(poolId, PauseMode.TRADE);
    }

    /// @notice Returns whether a registered pool permits ordinary LP operations after admission and LP-pause checks.
    /// @param poolId Pool identifier to check.
    /// @return Whether pool and asset admission checks pass and no LP pause applies.
    function isLPAllowed(bytes32 poolId) external view returns (bool) {
        return _isOperationAllowed(poolId, PauseMode.LP);
    }

    // Private helpers, grouped by identity, admission, pool, and pause duties.
    /// @dev Read every registered ID: an unavailable identity must never be treated as revoked.
    function _credentialState(address owner) private view returns (bool held, PermissionFlag permissions) {
        for (uint256 i; i < identityTokenIds.length; ++i) {
            uint256 tokenId = identityTokenIds[i];
            if (ISmartWalletSbtV1(participantSbt).verify(owner, tokenId)) {
                held = true;
                permissions = permissions | sbtIdentityConfig[tokenId].permissions;
            }
        }
    }

    /// @dev Checks the tier is configured and below capacity, then reserves one listing slot.
    /// @param tierId Tier whose listing slot is reserved.
    function _takeTierSlot(uint8 tierId) private {
        TierPolicy storage tier = tiers[tierId];
        if (tier.tierBps == 0 || tier.listedCount >= tier.maxListed) revert InvalidConfig();
        tier.listedCount++;
    }

    function _requireEnvironment() private view {
        if (permissionsAdapterFactory == address(0)) revert PermissionedEnvironmentNotBound();
    }

    function _registerPermissionedCurrency(PermissionedAdmission calldata admission) private {
        _requireEnvironment();
        address currency = admission.currency;
        if (currencies[currency].underlying != address(0) || !securities[admission.securityId].listed) {
            revert InvalidPermissionedConfig();
        }
        address underlying = PermissionedValidationLib.candidateUnderlying(currency);
        uint8 rawDecimals = PermissionedValidationLib.stockDecimals(currency, underlying);
        UnderlyingConfig storage canonicalUnderlying = underlyings[underlying];
        if (
            canonicalUnderlying.securityId != 0
                && (canonicalUnderlying.securityId != admission.securityId
                    || canonicalUnderlying.rawDecimals != rawDecimals
                    || canonicalUnderlying.legalShareAdapter != admission.legalShareAdapter)
        ) {
            revert InvalidPermissionedConfig();
        }
        PermissionedValidationLib.validateLegalShareAdapter(admission.legalShareAdapter, underlying);
        PermissionedValidationLib.validatePolicy(currency, underlying, admission.expectedOwner);
        if (underlying == admission.legalShareAdapter || currency == admission.legalShareAdapter) {
            revert InvalidPermissionedConfig();
        }
        PermissionedValidationLib.validateInitialInventory(permissionedPoolManager, currency, underlying);
        if (canonicalUnderlying.securityId == 0) {
            underlyings[underlying] = UnderlyingConfig(admission.securityId, admission.legalShareAdapter, rawDecimals);
            emit UnderlyingBound(underlying, admission.securityId, admission.legalShareAdapter, rawDecimals);
        }
        currencies[currency] = PermissionedCurrencyConfig(underlying, admission.expectedOwner);
        currenciesByUnderlying[underlying].push(currency);
        emit PermissionedCurrencyRegistered(currency, underlying, admission.securityId);
    }

    function _securityPausedForReplacement(bytes32 securityId, PauseMode operation) private view returns (bool) {
        return _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.SECURITY, securityId, operation)
            || (uint8(marketPauseMode[securityId]) & uint8(operation)) != 0;
    }

    function _assetAllowed(address asset) private view returns (bool) {
        address underlying = currencies[asset].underlying;
        return underlying != address(0)
            ? securities[underlyings[underlying].securityId].listed
            : quoteTokens[asset].registered;
    }

    /// @dev Recovery checks current identity and policy without repeating first-admission inventory checks.
    function _validateAssetForRecovery(address asset) private view {
        PermissionedCurrencyConfig storage currencyConfig = currencies[asset];
        if (currencyConfig.underlying != address(0)) {
            UnderlyingConfig storage underlyingConfig = underlyings[currencyConfig.underlying];
            if (!securities[underlyingConfig.securityId].listed) revert InvalidStatus();
            if (PermissionedValidationLib.candidateUnderlying(asset) != currencyConfig.underlying) {
                revert InvalidPermissionedConfig();
            }
            if (
                PermissionedValidationLib.stockDecimals(asset, currencyConfig.underlying)
                    != underlyingConfig.rawDecimals
            ) {
                revert PermissionedMetadataMismatch();
            }
            PermissionedValidationLib.validateLegalShareAdapter(
                underlyingConfig.legalShareAdapter, currencyConfig.underlying
            );
            PermissionedValidationLib.validatePolicy(asset, currencyConfig.underlying, currencyConfig.expectedOwner);
        } else if (quoteTokens[asset].registered) {
            PermissionedValidationLib.validateQuoteIdentity(asset);
            if (PermissionedValidationLib.readDecimals(asset) != quoteTokens[asset].rawDecimals) {
                revert PermissionedMetadataMismatch();
            }
        }
    }

    /// @dev Applies admission and pause checks for one pool operation type.
    function _isOperationAllowed(bytes32 poolId, PauseMode operation) private view returns (bool) {
        PoolConfig storage pool = pools[poolId];
        if (!isKnownPool(poolId)) return false;
        address currency0 = Currency.unwrap(pool.key.currency0);
        address currency1 = Currency.unwrap(pool.key.currency1);
        if (!_assetAllowed(currency0) || !_assetAllowed(currency1)) return false;
        if (
            _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.POOL, poolId, operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(currency0), operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(currency1), operation)
        ) return false;
        // Admission guarantees exactly one stock security per pool.
        bytes32 securityId = pool.securityId0 == 0 ? pool.securityId1 : pool.securityId0;
        return (uint8(marketPauseMode[securityId]) & uint8(operation)) == 0
            && !_isPaused(PauseScope.SECURITY, securityId, operation);
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
