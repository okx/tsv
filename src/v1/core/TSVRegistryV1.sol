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
    PoolLifecycle,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";
import {IPermissionsAdapterFactory} from
    "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @dev Defines the SBT pause and credential-verification views required by the Registry.
interface ISmartWalletSbtV1 {
    /// @notice Checks whether `user` holds the configured credential token.
    /// @param user Account whose credential ownership is checked.
    /// @param tokenId SBT identity token ID configured in the Registry.
    /// @return Whether `user` currently holds `tokenId`.
    function verify(address user, uint256 tokenId) external view returns (bool);

    /// @notice Reports whether the SBT contract has globally paused credential checks.
    /// @return Whether the SBT issuer is paused.
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
    /// @dev Reverts when permissioned-pool dependencies have not been bound yet.
    error PermissionedEnvironmentNotBound();
    /// @dev Reverts when a permissioned-stock admission or recovery check fails.
    error InvalidPermissionedConfig();
    /// @dev Reverts when a registered permissioned adapter cannot be verified against the Factory.
    /// @param currency Permissioned stock adapter that failed provenance verification.
    error UnverifiedPermissionedAdapter(address currency);
    /// @dev Reverts when current token metadata no longer matches the stored admission record.
    error PermissionedMetadataMismatch();
    /// @dev Reverts when a permissioned-stock ownership or policy invariant is not satisfied.
    error PermissionedPolicyMismatch();
    /// @dev Reverts when a token is neither a registered permissioned stock nor a registered quote asset.
    /// @param currency Token address that failed asset admission.
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
    /// @notice Factory that mints/verifies permissioned stock adapters.
    address public permissionsAdapterFactory;
    /// @notice Uniswap V4 PoolManager used by the permissioned adapter Factory.
    address public permissionedPoolManager;
    /// @notice TSV Hook authorized for registered pools.
    address public hook;
    /// @notice LP Manager authorized to register pools and validate LP callbacks.
    address public lpManager;
    /// @notice DataInbox authorized to apply sequenced market-state reports.
    address public dataInbox;
    /// @notice SBT contract used for participant identity and operation permissions.
    address public participantSbt;

    // Registered participant identities and their operation permissions.
    /// @notice Registered SBT token IDs and their TSV operation permission flags.
    /// @dev The autogenerated getter returns one `SbtIdentityConfig` for a token ID.
    mapping(uint256 => SbtIdentityConfig) public sbtIdentityConfig;
    /// @dev Append-only list of SBT token IDs registered in `sbtIdentityConfig`.
    uint256[] private identityTokenIds;

    // Security admission and tier capacity.
    /// @dev Security records keyed by TSV security ID.
    mapping(bytes32 => SecurityConfig) private securities;
    /// @dev Listing-cap policies keyed by nonzero tier ID.
    mapping(uint8 => TierPolicy) private tiers;

    // W/U/Q admission and configuration. Each W references its shared U record.
    /// @dev Permissioned stock adapter records keyed by W token address.
    mapping(address => PermissionedCurrencyConfig) private currencies;
    /// @dev Canonical underlying records keyed by U token address.
    mapping(address => UnderlyingConfig) private underlyings;
    /// @dev Quote token records keyed by quote ERC-20 address.
    mapping(address => QuoteTokenConfig) private quoteTokens;
    /// @notice Permissioned stock owners approved for adapter policy checks.
    /// @dev The autogenerated getter accepts an owner address and returns whether it is approved.
    mapping(address => bool) public isPermissionedOwnerApproved;
    /// @notice Shared exit receiver, keyed by underlying U.
    mapping(address => address) public exitAdminOf;
    /// @dev Permissioned stock adapters grouped by their canonical underlying U.
    mapping(address => address[]) private currenciesByUnderlying;

    // Registered pool keys and their permanent security associations.
    /// @dev Registered pool configuration keyed by raw Uniswap V4 pool ID.
    mapping(bytes32 => PoolConfig) private pools;
    /// @dev Append-only pool ID list grouped by the pool's single stock security ID.
    mapping(bytes32 => bytes32[]) private poolsBySecurity;
    /// @dev One-based index of a pool ID inside `poolsBySecurity[pool.securityId]`; zero means absent.
    mapping(bytes32 => uint256) private poolSecurityIndex;
    /// @notice Explicit lifecycle for each registered pool.
    /// @dev DELIST blocks swaps and ordinary LP, LIST allows both through later gates, PAUSE blocks swaps only.
    mapping(bytes32 => PoolLifecycle) public poolLifecycle;
    /// @notice Number of pools for a security whose Lifecycle is DELIST.
    /// @dev Used by `delistSecurity` to require all related pools to have no active ticks first.
    mapping(bytes32 => uint32) public listPoolCountBySecurity;
    /// @notice Current active tick/NFT count for each registered pool.
    /// @dev The LP Manager updates this value through `updatePoolTickCount` with signed deltas.
    mapping(bytes32 => uint256) public poolTickCount;

    // Market reports and emergency pause records.
    /// @notice Last accepted market-report sequence per security ID.
    mapping(bytes32 => uint64) public marketSequence;
    /// @notice Emergency pause records keyed by monotonically increasing record ID.
    mapping(uint256 => EmergencyPause) public emergencyPauses;
    /// @notice Number of active records for exactly the specified scope, target, and mode.
    mapping(uint8 => mapping(bytes32 => mapping(uint8 => uint256))) public activePauseCount;
    /// @notice Current market pause mask; admitted securities default to NONE.
    mapping(bytes32 => PauseMode) public marketPauseMode;
    /// @notice Next emergency pause record ID to allocate.
    uint256 public nextPauseId;

    /// @notice Emitted when core component addresses were bound to the Registry.
    /// @param hook TSV Hook authorized for registered pool callbacks.
    /// @param lpManager LP Manager authorized for pool registration and LP validation.
    /// @param dataInbox DataInbox authorized to apply market reports.
    /// @param factory Permissioned adapter Factory used for W provenance checks.
    /// @param poolManager PoolManager returned by `factory`.
    /// @param sbt Participant SBT used for identity checks.
    event ComponentsBound(
        address indexed hook,
        address indexed lpManager,
        address indexed dataInbox,
        address factory,
        address poolManager,
        address sbt
    );
    /// @notice Emitted when a security was added to the Registry with its listing tier.
    /// @param securityId TSV security identifier that is now listed.
    /// @param tierId Tier assigned to the security.
    event SecurityListed(bytes32 indexed securityId, uint8 tierId);
    /// @notice Emitted when a security was removed from the active listing set.
    /// @param securityId TSV security identifier that is now delisted.
    event SecurityDelisted(bytes32 indexed securityId);
    /// @notice Emitted when a listed security was assigned a different tier.
    /// @param securityId Listed security whose tier changed.
    /// @param oldTierId Previous tier ID.
    /// @param newTierId New tier ID.
    event SecurityTierChanged(bytes32 indexed securityId, uint8 oldTierId, uint8 newTierId);
    /// @notice Emitted when a security tier policy was created or updated.
    /// @param tierId Tier whose policy changed.
    /// @param tierBps ADTV multiplier in basis points.
    /// @param maxListed Maximum listed-security capacity for the tier.
    event TierPolicyChanged(uint8 indexed tierId, uint16 tierBps, uint32 maxListed);
    /// @notice Emitted when the first permissioned stock binds a canonical underlying to a security.
    /// @param underlying Canonical underlying stock token U.
    /// @param securityId TSV security identifier assigned to the underlying.
    /// @param legalShareAdapter Canonical converter used for legal-share accounting.
    /// @param rawDecimals Decimals read from the permissioned stock and underlying pair.
    event UnderlyingBound(
        address indexed underlying, bytes32 indexed securityId, address legalShareAdapter, uint8 rawDecimals
    );
    /// @notice Emitted when a permissioned stock adapter W is admitted.
    /// @param currency Permissioned stock adapter address.
    /// @param underlying Canonical underlying U derived from the adapter.
    /// @param securityId TSV security identifier for the stock.
    event PermissionedCurrencyRegistered(
        address indexed currency, address indexed underlying, bytes32 indexed securityId
    );
    /// @notice Emitted when an original quote ERC-20 is admitted.
    /// @param quote Quote token address.
    /// @param rawDecimals Decimals read from the quote token.
    event QuoteTokenRegistered(address indexed quote, uint8 rawDecimals);
    /// @notice Emitted when the canonical legal-share converter for an underlying changes.
    /// @param underlying Canonical underlying U whose converter changed.
    /// @param oldAdapter Previous legal-share adapter.
    /// @param newAdapter New legal-share adapter.
    event UnderlyingLegalShareAdapterChanged(address indexed underlying, address oldAdapter, address newAdapter);
    /// @notice Emitted when a permissioned-stock owner approval changes.
    /// @param owner Owner contract whose approval changed.
    /// @param approved Whether the owner is approved after the change.
    event PermissionedOwnerApprovalChanged(address indexed owner, bool approved);
    /// @notice Emitted when a permissioned stock's expected owner changes.
    /// @param currency Permissioned stock adapter whose expected owner changed.
    /// @param oldOwner Previous expected owner.
    /// @param newOwner New expected owner.
    event PermissionedExpectedOwnerChanged(address indexed currency, address oldOwner, address newOwner);
    /// @notice Emitted when the exit receiver for an underlying changes.
    /// @param underlying Canonical underlying U whose exit receiver changed.
    /// @param oldAdmin Previous exit receiver.
    /// @param newAdmin New exit receiver.
    event ExitAdminUpdated(address indexed underlying, address oldAdmin, address newAdmin);
    /// @notice Emitted when a security market-state report was accepted.
    /// @param securityId Security whose market pause mask changed.
    /// @param oldStatus Previous derived market status.
    /// @param newStatus New derived market status.
    /// @param oldPauseMode Previous pause mask.
    /// @param newPauseMode New pause mask.
    /// @param sequence Accepted report sequence number.
    /// @param reportId Unique report identifier supplied by DataInbox.
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
    /// @param recordId Newly allocated emergency pause record ID.
    /// @param scope Pause scope encoded as `PauseScope`.
    /// @param target Scope-specific target key; zero for GLOBAL.
    /// @param mode Pause mode encoded as `PauseMode`.
    /// @param reasonCode Operational reason code for opening the pause.
    event EmergencyPauseOpened(
        uint256 indexed recordId, uint8 scope, bytes32 indexed target, uint8 mode, bytes32 reasonCode
    );
    /// @notice Emitted when an emergency pause record was closed.
    /// @param recordId Emergency pause record ID that was closed.
    /// @param reasonCode Operational reason code for clearing the pause.
    event EmergencyPauseClosed(uint256 indexed recordId, bytes32 reasonCode);
    /// @notice Emitted when an identity is registered or its operation permissions are updated.
    /// @param sbt Bound SBT contract used for the identity.
    /// @param tokenId Identity token ID whose configuration changed.
    /// @param permissions TSV operation permission flags assigned to the identity.
    event SbtConfigChanged(address indexed sbt, uint256 indexed tokenId, PermissionFlag permissions);
    /// @notice Emitted when an LP Manager registers a new TSV pool.
    /// @param poolId Raw Uniswap V4 pool ID derived from the full pool key.
    /// @param securityId Single stock security assigned to the pool.
    /// @param tierId Security tier captured at registration time.
    /// @param lifecycle Initial lifecycle assigned to the pool.
    event PoolRegistered(
        bytes32 indexed poolId, bytes32 indexed securityId, uint8 indexed tierId, PoolLifecycle lifecycle
    );
    /// @notice Emitted when a registered pool changes lifecycle.
    /// @param poolId Raw Uniswap V4 pool ID whose lifecycle changed.
    /// @param securityId Single stock security assigned to the pool.
    /// @param oldLifecycle Previous lifecycle value.
    /// @param newLifecycle New lifecycle value.
    event PoolLifecycleChanged(
        bytes32 indexed poolId, bytes32 indexed securityId, PoolLifecycle oldLifecycle, PoolLifecycle newLifecycle
    );

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
    /// @return Address of `PermissionedValidationLib`.
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
    /// @return Token IDs registered through `setSbtConfig`.
    function sbtTokenIds() external view returns (uint256[] memory) {
        return identityTokenIds;
    }

    /// @notice Checks a registered identity independently of operation permissions and global pause.
    /// @param owner Account whose SBT identity ownership is checked.
    /// @param tokenId Registered SBT token ID to check.
    /// @return Whether `owner` currently holds `tokenId`.
    function hasIdentity(address owner, uint256 tokenId) external view returns (bool) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        if (!sbtIdentityConfig[tokenId].registered) revert InvalidConfig();
        return ISmartWalletSbtV1(participantSbt).verify(owner, tokenId);
    }

    /// @notice Whether `owner` holds any registered identity; permissions and pause do not affect this view.
    /// @param owner Account whose registered identity ownership is checked.
    /// @return held Whether `owner` holds at least one registered SBT identity.
    function hasCredential(address owner) public view returns (bool held) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        (held,) = _credentialState(owner);
    }

    /// @notice Active operation permissions, combining every held identity; paused SBT returns NONE.
    /// @param owner Account whose active operation permissions are checked.
    /// @return permissions Bitmask of active TSV operation permissions.
    function permissionsOf(address owner) public view returns (PermissionFlag permissions) {
        if (participantSbt == address(0)) revert SbtNotConfigured();
        if (ISmartWalletSbtV1(participantSbt).paused()) return PermissionFlags.NONE;
        (, permissions) = _credentialState(owner);
    }

    /// @notice Checks TSV identity permissions.
    /// @param permission SWAP_ALLOWED or LIQUIDITY_ALLOWED.
    /// @param account Participant whose permissions are checked.
    /// @return Whether `account` currently has `permission`.
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
    /// @return Tier policy containing multiplier, capacity, and current listing count.
    function tierPolicy(uint8 tierId) external view returns (TierPolicy memory) {
        return tiers[tierId];
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
        if (!config.listed || listPoolCountBySecurity[securityId] != 0) revert InvalidStatus();
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
    /// @notice Atomically lists a new security with its first stock W, or adds a W to an existing listed security.
    /// @param admission Permissioned stock admission payload for the W/U/security binding.
    /// @param tierId Tier to assign to a newly listed security, or the existing security tier for additional W.
    function registerPermissionedCurrency(PermissionedAdmission calldata admission, uint8 tierId)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        if (admission.securityId == 0) revert InvalidConfig();
        _requireEnvironment();
        SecurityConfig storage config = securities[admission.securityId];
        if (config.securityId == 0) {
            _takeTierSlot(tierId);
            securities[admission.securityId] = SecurityConfig(admission.securityId, tierId, true);
            emit SecurityListed(admission.securityId, tierId);
        } else if (!config.listed || config.tierId != tierId) {
            revert InvalidStatus();
        }
        _registerPermissionedCurrency(admission);
    }

    /// @notice Registers an original quote ERC-20; stock identities cannot become quotes.
    /// @param quote Quote token address to admit.
    function registerQuoteToken(address quote) external onlyRole(SYMBOL_ADMIN_ROLE) {
        _requireEnvironment();
        if (quoteTokens[quote].registered) revert InvalidStatus();
        PermissionedValidationLib.validateQuoteIdentity(quote);
        uint8 rawDecimals = PermissionedValidationLib.readDecimals(quote);
        quoteTokens[quote] = QuoteTokenConfig(rawDecimals, true);
        emit QuoteTokenRegistered(quote, rawDecimals);
    }

    /// @notice Adds or removes an approved permissioned-stock owner contract.
    /// @param owner Owner contract whose approval status changes.
    /// @param approved Whether the owner should be accepted by future policy checks.
    function setPermissionedOwnerApproval(address owner, bool approved) external onlyGovernor {
        if (owner == address(0) || (approved && owner.code.length == 0)) revert PermissionedPolicyMismatch();
        isPermissionedOwnerApproved[owner] = approved;
        emit PermissionedOwnerApprovalChanged(owner, approved);
    }

    /// @notice Updates the expected owner recorded for an admitted permissioned stock adapter.
    /// @dev The token, security, or global pause state must cover both TRADE and LP before replacement.
    /// @param w Permissioned stock adapter whose expected owner is updated.
    /// @param newOwner New owner contract expected by adapter policy validation.
    function updatePermissionedExpectedOwner(address w, address newOwner) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PermissionedCurrencyConfig storage config = currencies[w];
        if (config.underlying == address(0) || newOwner == config.expectedOwner) revert InvalidStatus();
        bytes32 securityId = underlyings[config.underlying].securityId;
        // A TOKEN, SECURITY, or GLOBAL pause must cover both ordinary operation types.
        if (
            !(
                _isPaused(PauseScope.TOKEN, _addressKey(w), PauseMode.TRADE)
                    || _securityPausedForReplacement(securityId, PauseMode.TRADE)
            )
                || !(
                    _isPaused(PauseScope.TOKEN, _addressKey(w), PauseMode.LP)
                        || _securityPausedForReplacement(securityId, PauseMode.LP)
                )
        ) revert InvalidStatus();
        PermissionedValidationLib.validateOwner(w, config.underlying, newOwner);
        address previousExpectedOwner = config.expectedOwner;
        config.expectedOwner = newOwner;
        emit PermissionedExpectedOwnerChanged(w, previousExpectedOwner, newOwner);
    }

    /// @notice Replaces the canonical U converter while the entire security is paused for trade and LP.
    /// @param u Canonical underlying whose legal-share adapter is replaced.
    /// @param newAdapter New legal-share adapter for `u`.
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
    /// @param u Canonical underlying whose exit receiver changes.
    /// @param newAdmin New receiver for forced exits and related recovery flows.
    function setExitAdmin(address u, address newAdmin) external onlyGovernor {
        _requireEnvironment();
        if (newAdmin == exitAdminOf[u]) revert InvalidStatus();
        PermissionedValidationLib.validateExitAdmin(u, newAdmin, currenciesByUnderlying[u]);
        address previousExitAdmin = exitAdminOf[u];
        exitAdminOf[u] = newAdmin;
        emit ExitAdminUpdated(u, previousExitAdmin, newAdmin);
    }

    /// @notice Returns the stored permissioned stock adapter configuration.
    /// @param w Permissioned stock adapter address to query.
    /// @return Stored W configuration; unknown adapters return a default record.
    function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory) {
        return currencies[w];
    }

    /// @notice Returns the stored canonical underlying configuration.
    /// @param u Canonical underlying address to query.
    /// @return Stored U configuration; unknown underlyings return a default record.
    function getUnderlying(address u) external view returns (UnderlyingConfig memory) {
        return underlyings[u];
    }

    /// @notice Returns the stored quote token configuration.
    /// @param quote Quote token address to query.
    /// @return Stored quote configuration; unknown quotes return a default record.
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
                || key.tickSpacing < 1 || key.tickSpacing > 32767 || !_assetAllowed(currency0) || !_assetAllowed(currency1)
        ) revert InvalidPool();
        bytes32 securityId0 = underlyings[currencies[currency0].underlying].securityId;
        bytes32 securityId1 = underlyings[currencies[currency1].underlying].securityId;
        if ((securityId0 == 0) == (securityId1 == 0)) revert InvalidPool();
        bytes32 securityId = securityId0 == 0 ? securityId1 : securityId0;
        SecurityConfig storage security = securities[securityId];
        if (!security.listed) revert InvalidPool();
        uint8 tierId = security.tierId;
        poolId = PoolId.unwrap(key.toId());
        if (isKnownPool(poolId)) revert InvalidPool();
        pools[poolId] = PoolConfig(key, securityId, tierId);
        poolsBySecurity[securityId].push(poolId);
        poolSecurityIndex[poolId] = poolsBySecurity[securityId].length;
        poolLifecycle[poolId] = PoolLifecycle.LIST;
        emit PoolRegistered(poolId, securityId, tierId, PoolLifecycle.LIST);
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

    /// @notice Returns the explicit lifecycle of a registered pool.
    /// @param poolId Raw Uniswap V4 pool ID to query.
    /// @return lifecycle Current pool lifecycle; unknown pools return the enum default DELIST.
    function getPoolLifeCycle(bytes32 poolId) external view returns (PoolLifecycle lifecycle) {
        return poolLifecycle[poolId];
    }


    /// @notice Returns the explicit lifecycle for the pool derived from a full PoolKey.
    /// @param key Full Uniswap V4 pool key whose derived pool ID is queried.
    /// @return lifecycle Current pool lifecycle; unknown pools return the enum default DELIST.
    function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        return poolLifecycle[poolId];
    }

    /// @notice Updates one registered pool's lifecycle.
    /// @param poolId Raw Uniswap V4 pool ID whose lifecycle changes.
    /// @param lifecycle New lifecycle to set.
    /// @return Whether storage changed.
    function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
        returns (bool)
    {
        PoolConfig storage pool = pools[poolId];
        if (!isKnownPool(poolId)) revert InvalidPool();
        return _updatePoolLifecycle(poolId, pool, lifecycle);
    }

    /// @notice Updates many registered pools to the same lifecycle.
    /// @param poolIds Pool IDs whose lifecycle should be updated.
    /// @param lifecycle New lifecycle to apply to every pool.
    /// @return changedCount Number of pools whose stored lifecycle changed.
    function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
        returns (uint256 changedCount)
    {
        if (poolIds.length == 0) revert InvalidConfig();
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            PoolConfig storage pool = pools[poolId];
            if (!isKnownPool(poolId)) revert InvalidPool();
            if (_updatePoolLifecycle(poolId, pool, lifecycle)) changedCount++;
        }
    }

    /// @notice Applies an LP Manager tick-count delta for a registered pool key.
    /// @dev Positive deltas activate a zero-count pool; negative deltas cannot reduce below zero.
    /// @param key Full V4 pool key whose derived pool ID must already be registered.
    /// @param delta Signed tick-count change to apply.
    /// @return Whether the update was accepted.
    function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool) {
        if (msg.sender != lpManager) revert InvalidPool();
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolConfig storage pool = pools[poolId];
        if (!isKnownPool(poolId)) revert InvalidPool();
        if (delta > 0 && (poolLifecycle[poolId] == PoolLifecycle.DELIST || !securities[pool.securityId].listed)) {
            revert InvalidStatus();
        }
        _applyPoolTickDelta(poolId, delta);
        return true;
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

    /// @notice Whether a protocol-wide emergency pause currently blocks ordinary operation.
    /// @return Whether a GLOBAL TRADE, GLOBAL LP, or GLOBAL ALL emergency pause is active.
    function isPaused() external view returns (bool) {
        return _isPaused(PauseScope.GLOBAL, 0, PauseMode.TRADE) || _isPaused(PauseScope.GLOBAL, 0, PauseMode.LP);
    }

    // Private helpers, grouped by identity, admission, pool, and pause duties.
    /// @dev Read every registered ID: an unavailable identity must never be treated as revoked.
    /// @param owner Account whose SBT holdings are aggregated.
    /// @return held Whether `owner` holds at least one registered SBT identity.
    /// @return permissions Union of TSV operation permissions from every held identity.
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

    /// @dev Requires the permissioned-pool dependency set to have been bound.
    function _requireEnvironment() private view {
        if (permissionsAdapterFactory == address(0)) revert PermissionedEnvironmentNotBound();
    }

    /// @dev Validates and stores one permissioned stock adapter under an already listed security.
    /// @param admission Permissioned stock admission payload to validate and store.
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
                && (
                    canonicalUnderlying.securityId != admission.securityId || canonicalUnderlying.rawDecimals != rawDecimals
                        || canonicalUnderlying.legalShareAdapter != admission.legalShareAdapter
                )
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

    /// @dev Checks whether replacement-sensitive operations are paused for a security.
    /// @param securityId Security whose replacement gate is checked.
    /// @param operation Operation mode that must be paused.
    /// @return Whether global, security, or market pause state covers `operation`.
    function _securityPausedForReplacement(bytes32 securityId, PauseMode operation) private view returns (bool) {
        return _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.SECURITY, securityId, operation)
            || (uint8(marketPauseMode[securityId]) & uint8(operation)) != 0;
    }

    /// @dev Checks whether an asset is currently admitted for pool operations.
    /// @param asset Token address to check as either W or Q.
    /// @return Whether `asset` is an admitted quote or a listed permissioned stock.
    function _assetAllowed(address asset) private view returns (bool) {
        address underlying = currencies[asset].underlying;
        return underlying != address(0)
            ? securities[underlyings[underlying].securityId].listed
            : quoteTokens[asset].registered;
    }

    /// @dev Recovery checks current identity and policy without repeating first-admission inventory checks.
    /// @param asset Token address whose current identity and metadata are revalidated.
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
    /// @param poolId Registered pool ID to check.
    /// @param operation TRADE or LP operation gate to evaluate.
    /// @return Whether the operation may continue through Registry gates.
    function _isOperationAllowed(bytes32 poolId, PauseMode operation) private view returns (bool) {
        PoolConfig storage pool = pools[poolId];
        if (!isKnownPool(poolId)) return false;
        PoolLifecycle lifecycle = poolLifecycle[poolId];
        if (operation == PauseMode.TRADE) {
            if (lifecycle != PoolLifecycle.LIST) return false;
        } else if (operation == PauseMode.LP) {
            if (lifecycle == PoolLifecycle.DELIST) return false;
        }
        address currency0 = Currency.unwrap(pool.key.currency0);
        address currency1 = Currency.unwrap(pool.key.currency1);
        if (!_assetAllowed(currency0) || !_assetAllowed(currency1)) return false;
        if (
            _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.POOL, poolId, operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(currency0), operation)
                || _isPaused(PauseScope.TOKEN, _addressKey(currency1), operation)
        ) return false;
        bytes32 securityId = pool.securityId;
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

    /// @dev Applies one lifecycle transition.
    /// @param poolId Registered pool whose lifecycle is updated.
    /// @param pool Stored pool configuration for `poolId`.
    /// @param lifecycle New lifecycle value.
    /// @return Whether the stored lifecycle changed.
    function _updatePoolLifecycle(bytes32 poolId, PoolConfig storage pool, PoolLifecycle lifecycle)
        private
        returns (bool)
    {
        PoolLifecycle previousLifecycle = poolLifecycle[poolId];
        if (lifecycle == PoolLifecycle.DELIST && poolTickCount[poolId] != 0) revert InvalidStatus();
        bytes32 securityId = pool.securityId;
        if (previousLifecycle == lifecycle) return false;
        if (lifecycle != PoolLifecycle.DELIST && !securities[securityId].listed) revert InvalidStatus();
        if (previousLifecycle == PoolLifecycle.DELIST) {
            listPoolCountBySecurity[securityId]++;
        } else if (lifecycle == PoolLifecycle.DELIST) {
            listPoolCountBySecurity[securityId]--;
        }
        poolLifecycle[poolId] = lifecycle;
        emit PoolLifecycleChanged(poolId, securityId, previousLifecycle, lifecycle);
        return true;
    }

    /// @dev Applies a signed tick-count delta and keeps the per-security active-pool count in sync.
    /// @param poolId Registered pool whose tick count is updated.
    /// @param securityId Security assigned to `poolId`.
    /// @param delta Signed tick-count change to apply.
    function _applyPoolTickDelta(bytes32 poolId, int256 delta) private {
        if (delta == 0) return;
        uint256 current = poolTickCount[poolId];
        uint256 updated;
        if (delta > 0) {
            updated = current + uint256(delta);
        } else {
            uint256 decrease = uint256(-(delta + 1)) + 1;
            if (decrease > current) revert InvalidStatus();
            updated = current - decrease;
        }
        poolTickCount[poolId] = updated;
    }
}
