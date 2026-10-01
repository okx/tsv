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
    PauseScope
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
    mapping(bytes32 => MarketStatus) private marketStatuses;
    mapping(bytes32 => uint64) public marketSequence;
    mapping(uint256 => EmergencyPause) public emergencyPauses;
    mapping(uint8 => mapping(bytes32 => uint256)) public activePauseCount;
    ISmartWalletSbtV1 public participantSbt;
    uint256 public sbtTokenId;

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
        bytes32 indexed securityId, uint8 oldStatus, uint8 newStatus, uint64 sequence, bytes32 indexed reportId
    );
    /// @notice Emitted when an emergency pause record was opened.
    event EmergencyPauseOpened(uint256 indexed recordId, uint8 scope, bytes32 indexed target, bytes32 reasonCode);
    /// @notice Emitted when an emergency pause record was closed.
    event EmergencyPauseClosed(uint256 indexed recordId, bytes32 reasonCode);
    /// @notice Emitted when the configured participant SBT or token identifier was changed.
    event SbtConfigChanged(
        address indexed oldSbt, address indexed newSbt, uint256 oldTokenId, uint256 newTokenId, bytes32 evidenceHash
    );

    /// @notice Initializes governance and starts emergency-pause IDs at one.
    /// @param authority Business authority used by the governed base contract.
    /// @param timelock Upgrade timelock used by the governed base contract.
    /// @param controller Emergency upgrade controller used by the governed base contract.
    function initialize(address authority, address timelock, address controller) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
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

    /// @notice Lists a new security and reserves its unique symbol and one slot in its tier.
    /// @param securityId Unique internal identifier for the security.
    /// @param symbolHash Unique digest of its display symbol or ticker.
    /// @param tierId Configured tier with available listing capacity.
    /// @param evidenceHash Nonzero digest of the listing evidence.
    function listSecurity(bytes32 securityId, bytes32 symbolHash, uint8 tierId, bytes32 evidenceHash)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        if (
            securityId == 0 || symbolHash == 0 || evidenceHash == 0 || securities[securityId].securityId != 0
                || symbolToSecurity[symbolHash] != 0
        ) revert InvalidConfig();
        _takeTierSlot(tierId);
        securities[securityId] = SecurityConfig(securityId, symbolHash, tierId, true, 0, 1);
        symbolToSecurity[symbolHash] = securityId;
        emit SecurityListed(securityId, symbolHash, tierId, evidenceHash);
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

    /// @notice Registers a token after validating its runtime code, decimals, security, and share adapter.
    /// @param config Token configuration; new entries must start as UNREVIEWED.
    /// @param evidenceHash Nonzero digest of the token registration evidence.
    function registerToken(TokenConfig calldata config, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        if (
            config.poolCurrency == address(0) || config.status != TokenStatus.UNREVIEWED || evidenceHash == 0
                || tokens[config.poolCurrency].poolCurrency != address(0) || config.poolDecimals > 18
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
    }

    /// @notice Changes a registered token's review status, enforcing approval prerequisites.
    /// @param currency Registered pool Currency to update.
    /// @param status New review status.
    /// @param evidenceHash Nonzero digest of the status-change evidence.
    function setTokenStatus(address currency, TokenStatus status, bytes32 evidenceHash)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        TokenConfig storage config = tokens[currency];
        if (config.poolCurrency == address(0) || evidenceHash == 0 || config.status == status) revert InvalidStatus();
        if (
            status == TokenStatus.UNREVIEWED
                || (config.status == TokenStatus.UNREVIEWED && status != TokenStatus.APPROVED)
        ) {
            revert InvalidStatus();
        }
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
        if (!this.isTradable(poolId)) revert InvalidStatus();
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

    /// @notice Returns the current reported market state for a security.
    /// @param securityId Security identifier to query.
    /// @return Current market state, or UNINITIALIZED when no state was reported.
    function marketStatus(bytes32 securityId) external view returns (MarketStatus) {
        return marketStatuses[securityId];
    }

    /// @notice Applies the next valid market-state transition from the bound DataInbox.
    /// @param securityId Listed security whose market state changes.
    /// @param action Initial-state, halt, or resume action from the report.
    /// @param sequence Report sequence for this security.
    /// @param reportId Unique ID of the accepted MarketReport.
    function applyMarketStatus(bytes32 securityId, MarketAction action, uint64 sequence, bytes32 reportId) external {
        if (
            msg.sender != dataInbox || securityId == 0 || !securities[securityId].listed
                || sequence <= marketSequence[securityId]
        ) revert InvalidStatus();
        MarketStatus old = marketStatuses[securityId];
        MarketStatus next;
        if (action == MarketAction.INITIAL_OPEN && old == MarketStatus.UNINITIALIZED) next = MarketStatus.OPEN;
        else if (action == MarketAction.INITIAL_HALTED && old == MarketStatus.UNINITIALIZED) next = MarketStatus.HALTED;
        else if (action == MarketAction.HALT && old == MarketStatus.OPEN) next = MarketStatus.HALTED;
        else if (action == MarketAction.RESUME && old == MarketStatus.HALTED) next = MarketStatus.OPEN;
        else revert InvalidStatus();
        marketStatuses[securityId] = next;
        marketSequence[securityId] = sequence;
        emit MarketStatusChanged(securityId, uint8(old), uint8(next), sequence, reportId);
    }

    /// @notice Opens a scoped emergency pause and returns its record ID.
    /// @param scope GLOBAL, SECURITY, TOKEN, or POOL pause scope.
    /// @param target Scope-specific target key; zero only for GLOBAL.
    /// @param reasonCode Nonzero operational reason code.
    /// @param sourceHash Nonzero digest of the incident source material.
    /// @return recordId New emergency-pause record identifier.
    function addEmergencyPause(PauseScope scope, bytes32 target, bytes32 reasonCode, bytes32 sourceHash)
        external
        onlyRole(EMERGENCY_PAUSER_ROLE)
        returns (uint256 recordId)
    {
        if (
            reasonCode == 0 || sourceHash == 0 || (scope == PauseScope.GLOBAL && target != 0)
                || (scope != PauseScope.GLOBAL && target == 0)
        ) revert InvalidConfig();
        recordId = nextPauseId++;
        emergencyPauses[recordId] =
            EmergencyPause(scope, target, reasonCode, sourceHash, msg.sender, uint64(block.timestamp), true);
        activePauseCount[uint8(scope)][target]++;
        emit EmergencyPauseOpened(recordId, uint8(scope), target, reasonCode);
    }

    /// @notice Closes an active emergency-pause record and decrements its scope's active count.
    /// @param recordId Active pause record to close.
    /// @param reasonCode Nonzero reason code for clearing the pause.
    function clearEmergencyPause(uint256 recordId, bytes32 reasonCode) external onlyRole(EMERGENCY_RESUMER_ROLE) {
        EmergencyPause storage record = emergencyPauses[recordId];
        if (!record.active || reasonCode == 0) revert InvalidStatus();
        record.active = false;
        activePauseCount[uint8(record.scope)][record.target]--;
        emit EmergencyPauseClosed(recordId, reasonCode);
    }

    /// @notice Returns whether a pool and both assets pass status, market, and emergency-pause checks.
    /// @param poolId Pool identifier to check.
    /// @return Whether the pool is active, assets are approved, securities are open, and no pause applies.
    function isTradable(bytes32 poolId) external view returns (bool) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.ACTIVE) return false;
        address c0 = Currency.unwrap(pool.key.currency0);
        address c1 = Currency.unwrap(pool.key.currency1);
        if (tokens[c0].status != TokenStatus.APPROVED || tokens[c1].status != TokenStatus.APPROVED) return false;
        if (
            _isPaused(PauseScope.GLOBAL, 0) || _isPaused(PauseScope.POOL, poolId)
                || _isPaused(PauseScope.TOKEN, _addressKey(c0)) || _isPaused(PauseScope.TOKEN, _addressKey(c1))
        ) return false;
        if (
            pool.securityId0 != 0
                && (!securities[pool.securityId0].listed
                    || marketStatuses[pool.securityId0] != MarketStatus.OPEN
                    || _isPaused(PauseScope.SECURITY, pool.securityId0))
        ) return false;
        if (
            pool.securityId1 != 0
                && (!securities[pool.securityId1].listed
                    || marketStatuses[pool.securityId1] != MarketStatus.OPEN
                    || _isPaused(PauseScope.SECURITY, pool.securityId1))
        ) return false;
        return true;
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

    /// @dev Allows adapter replacement when the currency has no active pools or is emergency-paused.
    /// @param currency Pool Currency whose replacement conditions are checked.
    /// @return Whether no active pool uses the currency or a global/token pause is active.
    function _assetPausedForReplacement(address currency) private view returns (bool) {
        return activePoolCountByCurrency[currency] == 0 || _isPaused(PauseScope.GLOBAL, 0)
            || _isPaused(PauseScope.TOKEN, _addressKey(currency));
    }

    /// @dev Checks whether at least one active pause record exists for the scope and target.
    /// @param scope Pause scope to inspect.
    /// @param target Scope-specific target key.
    /// @return Whether the active pause count is nonzero.
    function _isPaused(PauseScope scope, bytes32 target) private view returns (bool) {
        return activePauseCount[uint8(scope)][target] != 0;
    }

    /// @dev Encodes an address as the bytes32 target key used by token-scoped pauses.
    /// @param a Address to encode.
    /// @return Address left-padded to bytes32.
    function _addressKey(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
