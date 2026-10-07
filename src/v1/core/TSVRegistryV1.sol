// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig,
    PermissionedAdmission,
    SecurityConfig,
    PoolConfig,
    AssetStatus,
    PoolStatus,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IPermissionsAdapter, IERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IAllowlistChecker, IERC165} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";

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
contract TSVRegistryV1 is TSVGoverned, IAllowlistChecker, IPermissionsAdapterFactory {
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

    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error FactoryEntryReentrancy();
    error UnsupportedAsset(address currency);

    address public permissionsAdapterFactory;
    address public permissionedPoolManager;
    address public permissionedRouter;
    mapping(address => PermissionedCurrencyConfig) private currencies;
    mapping(address => UnderlyingConfig) private underlyings;
    mapping(address => QuoteTokenConfig) private quoteTokens;
    mapping(address => bool) public isPermissionedOwnerApproved;
    mapping(address => address) public exitAdminOf;
    mapping(address => uint64) public exitAdminVersion;
    bool private factoryEntryEntered;

    address public hook;
    address public lpManager;
    address public dataInbox;
    uint256 public nextPauseId;

    mapping(bytes32 => SecurityConfig) private securities;
    mapping(uint8 => TierPolicy) private tiers;
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
    /// @notice Emitted when a security was added to the Registry with its listing tier.
    event SecurityListed(bytes32 indexed securityId, uint8 tierId);
    /// @notice Emitted when a security was removed from the active listing set.
    event SecurityDelisted(bytes32 indexed securityId);
    /// @notice Emitted when a listed security was assigned a different tier.
    event SecurityTierChanged(bytes32 indexed securityId, uint8 oldTierId, uint8 newTierId);
    /// @notice Emitted when a security tier policy was created or updated.
    event TierPolicyChanged(uint8 indexed tierId, uint16 tierBps, uint32 maxListed);
    event PermissionedComponentsBound(address indexed factory, address indexed poolManager, address indexed router);
    event UnderlyingBound(
        address indexed underlying, bytes32 indexed securityId, address legalShareAdapter, uint8 rawDecimals
    );
    event PermissionedCurrencyRegistered(
        address indexed currency, address indexed underlying, bytes32 indexed securityId
    );
    event PermissionedCurrencyStatusChanged(
        address indexed currency, uint8 oldStatus, uint8 newStatus, uint64 configVersion
    );
    event QuoteTokenRegistered(address indexed quote, uint8 rawDecimals);
    event QuoteTokenStatusChanged(address indexed quote, uint8 oldStatus, uint8 newStatus, uint64 configVersion);
    event UnderlyingLegalShareAdapterChanged(
        address indexed underlying, address oldAdapter, address newAdapter, uint32 legalAdapterVersion
    );
    event PermissionedOwnerApprovalChanged(address indexed owner, bool approved);
    event PermissionedExpectedOwnerChanged(
        address indexed currency, address oldOwner, address newOwner, uint64 configVersion
    );
    event ExitAdminUpdated(address indexed currency, address oldAdmin, address newAdmin, uint64 version);
    /// @notice Emitted when a pending pool completed initialization and became active.
    event PoolInitialized(bytes32 indexed poolId, uint160 sqrtPriceX96, address indexed creator);
    /// @notice Emitted when a registered pool status was changed.
    event PoolStatusChanged(bytes32 indexed poolId, uint8 oldStatus, uint8 newStatus);
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
    event SbtConfigChanged(address indexed oldSbt, address indexed newSbt, uint256 oldTokenId, uint256 newTokenId);

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

    /// @notice Binds the real Factory and Router once after the common components are bound.
    function bindPermissionedComponents(address factory, address router_) external onlyGovernor {
        if (permissionsAdapterFactory != address(0)) revert InvalidStatus();
        address pm = PermissionedValidationLib.validateEnvironment(_environment(), factory, router_);
        permissionsAdapterFactory = factory;
        permissionedPoolManager = pm;
        permissionedRouter = router_;
        emit PermissionedComponentsBound(factory, pm, router_);
    }

    /// @notice Returns the stateless validator address linked into this implementation.
    function permissionedValidationLibrary() external pure returns (address) {
        return address(PermissionedValidationLib);
    }

    function permissionedAllowlistChecker() external view returns (address) {
        return address(this);
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function POOL_MANAGER() external view returns (address) {
        return permissionsAdapterFactory == address(0)
            ? address(0)
            : IPermissionsAdapterFactory(permissionsAdapterFactory).POOL_MANAGER();
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function permissionsAdapterOf(address w) external view returns (address) {
        return permissionsAdapterFactory == address(0)
            ? address(0)
            : IPermissionsAdapterFactory(permissionsAdapterFactory).permissionsAdapterOf(w);
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function verifiedPermissionsAdapterOf(address w) external view returns (address) {
        return permissionsAdapterFactory == address(0)
            ? address(0)
            : IPermissionsAdapterFactory(permissionsAdapterFactory).verifiedPermissionsAdapterOf(w);
    }

    modifier factoryEntry() {
        _requireEnvironment();
        if (factoryEntryEntered) revert FactoryEntryReentrancy();
        factoryEntryEntered = true;
        _;
        factoryEntryEntered = false;
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function createPermissionsAdapter(IERC20 u, address initialOwner, IAllowlistChecker checker)
        external
        factoryEntry
        returns (address)
    {
        if (address(checker) != address(this)) revert InvalidPermissionedConfig();
        return IPermissionsAdapterFactory(permissionsAdapterFactory).createPermissionsAdapter(u, initialOwner, checker);
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function verifyPermissionsAdapter(address w) external factoryEntry {
        IPermissionsAdapterFactory(permissionsAdapterFactory).verifyPermissionsAdapter(w);
    }

    /// @inheritdoc IAllowlistChecker
    function checkAllowlist(address account, address u) external view returns (PermissionFlag) {
        PermissionedCurrencyConfig storage config = currencies[msg.sender];
        if (
            account == address(0) || u == address(0) || config.underlying != u || config.status != AssetStatus.APPROVED
                || underlyings[u].securityId == 0 || !securities[underlyings[u].securityId].listed
                || address(participantSbt) == address(0)
        ) return PermissionFlags.NONE;
        return
            _isEligible(account)
                ? PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED
                : PermissionFlags.NONE;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IAllowlistChecker).interfaceId
            || interfaceId == type(IPermissionsAdapterFactory).interfaceId || super.supportsInterface(interfaceId);
    }

    function _isEligible(address account) private view returns (bool) {
        return !participantSbt.paused() && participantSbt.verify(account, sbtTokenId);
    }

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

    /// @notice Configures the participant SBT after checking that its required view methods respond.
    /// @param sbt_ SBT contract implementing `verify` and `paused`.
    /// @param tokenId_ Credential token ID checked for participants.
    function setSbtConfig(address sbt_, uint256 tokenId_) external onlyGovernor {
        if (sbt_.code.length == 0) revert InvalidConfig();
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
        emit SbtConfigChanged(oldSbt, sbt_, oldTokenId, tokenId_);
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
        return _isEligible(owner);
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
        securities[admission.securityId] = SecurityConfig(admission.securityId, tierId, true, 0, 1);
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
        config.version++;
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
        uint8 old = config.tierId;
        config.tierId = tierId;
        config.version++;
        emit SecurityTierChanged(securityId, old, tierId);
    }

    /// @notice Delists a security only after all of its active pools have been disabled.
    /// @param securityId Listed security to remove from admission.
    function delistSecurity(bytes32 securityId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed || config.activePoolCount != 0) revert InvalidStatus();
        config.listed = false;
        config.version++;
        tiers[config.tierId].listedCount--;
        emit SecurityDelisted(securityId);
    }

    /// @notice Returns the stored listing, tier, version, and active-pool data for a security.
    /// @param securityId Security identifier to query.
    /// @return Stored security record; unknown IDs return a default record.
    function getSecurity(bytes32 securityId) external view returns (SecurityConfig memory) {
        return securities[securityId];
    }

    /// @notice Adds a stock W to an already listed security, sharing its U configuration.
    function registerPermissionedCurrency(PermissionedAdmission calldata admission)
        external
        onlyRole(SYMBOL_ADMIN_ROLE)
    {
        _registerPermissionedCurrency(admission);
    }

    function _registerPermissionedCurrency(PermissionedAdmission calldata admission) private {
        _requireEnvironment();
        address w = admission.currency;
        if (
            currencies[w].underlying != address(0) || quoteTokens[w].status != AssetStatus.ABSENT
                || underlyings[w].securityId != 0 || !securities[admission.securityId].listed
        ) revert InvalidPermissionedConfig();
        address u = _candidateUnderlying(w);
        _validateAssetIdentities(w, u);
        uint8 decimals = _stockDecimals(w, u);
        UnderlyingConfig storage canonical = underlyings[u];
        uint32 version = canonical.securityId == 0 ? 1 : canonical.legalAdapterVersion;
        if (
            canonical.securityId != 0
                && (canonical.securityId != admission.securityId
                    || canonical.rawDecimals != decimals
                    || canonical.legalShareAdapter != admission.legalShareAdapter)
        ) {
            revert InvalidPermissionedConfig();
        }
        _validateLegalShareAdapter(admission.legalShareAdapter, u, version);
        _validatePolicy(w, u, admission.expectedOwner);
        if (u == admission.legalShareAdapter || w == admission.legalShareAdapter) revert InvalidPermissionedConfig();
        PermissionedValidationLib.validateInitialInventory(permissionedPoolManager, w, u);
        if (canonical.securityId == 0) {
            underlyings[u] = UnderlyingConfig(admission.securityId, admission.legalShareAdapter, 1, decimals);
            emit UnderlyingBound(u, admission.securityId, admission.legalShareAdapter, decimals);
        }
        currencies[w] = PermissionedCurrencyConfig(u, admission.expectedOwner, AssetStatus.APPROVED, 1);
        emit PermissionedCurrencyRegistered(w, u, admission.securityId);
        emit PermissionedCurrencyStatusChanged(w, uint8(AssetStatus.ABSENT), uint8(AssetStatus.APPROVED), 1);
    }

    /// @notice Registers an original quote ERC-20; stock identities cannot become quotes.
    function registerQuoteToken(address quote) external onlyRole(SYMBOL_ADMIN_ROLE) {
        _requireEnvironment();
        if (quoteTokens[quote].status != AssetStatus.ABSENT) revert InvalidStatus();
        _validateQuoteIdentity(quote);
        uint8 decimals = _readDecimals(quote);
        quoteTokens[quote] = QuoteTokenConfig(decimals, AssetStatus.APPROVED, 1);
        emit QuoteTokenRegistered(quote, decimals);
        emit QuoteTokenStatusChanged(quote, uint8(AssetStatus.ABSENT), uint8(AssetStatus.APPROVED), 1);
    }

    function setPermissionedCurrencyStatus(address w, AssetStatus status) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PermissionedCurrencyConfig storage config = currencies[w];
        if (config.underlying == address(0) || status == AssetStatus.ABSENT || config.status == status) {
            revert InvalidStatus();
        }
        if (status == AssetStatus.APPROVED) {
            UnderlyingConfig storage u = underlyings[config.underlying];
            if (!securities[u.securityId].listed) revert InvalidStatus();
            if (_candidateUnderlying(w) != config.underlying) revert InvalidPermissionedConfig();
            _validateAssetIdentities(w, config.underlying);
            if (_stockDecimals(w, config.underlying) != u.rawDecimals) revert PermissionedMetadataMismatch();
            _validateLegalShareAdapter(u.legalShareAdapter, config.underlying, u.legalAdapterVersion);
            _validatePolicy(w, config.underlying, config.expectedOwner);
        }
        AssetStatus old = config.status;
        config.status = status;
        config.configVersion++;
        emit PermissionedCurrencyStatusChanged(w, uint8(old), uint8(status), config.configVersion);
    }

    function setQuoteTokenStatus(address quote, AssetStatus status) external onlyRole(SYMBOL_ADMIN_ROLE) {
        QuoteTokenConfig storage config = quoteTokens[quote];
        if (config.status == AssetStatus.ABSENT || status == AssetStatus.ABSENT || config.status == status) {
            revert InvalidStatus();
        }
        if (status == AssetStatus.APPROVED) {
            _validateQuoteIdentity(quote);
            if (_readDecimals(quote) != config.rawDecimals) revert PermissionedMetadataMismatch();
        }
        AssetStatus old = config.status;
        config.status = status;
        config.configVersion++;
        emit QuoteTokenStatusChanged(quote, uint8(old), uint8(status), config.configVersion);
    }

    function setPermissionedOwnerApproval(address owner, bool approved) external onlyGovernor {
        if (owner == address(0) || (approved && owner.code.length == 0)) revert PermissionedPolicyMismatch();
        isPermissionedOwnerApproved[owner] = approved;
        emit PermissionedOwnerApprovalChanged(owner, approved);
    }

    function updatePermissionedExpectedOwner(address w, address newOwner) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PermissionedCurrencyConfig storage config = currencies[w];
        if (
            config.underlying == address(0) || config.status != AssetStatus.DISABLED || newOwner == config.expectedOwner
        ) revert InvalidStatus();
        _validateOwner(w, config.underlying, newOwner);
        address old = config.expectedOwner;
        config.expectedOwner = newOwner;
        config.configVersion++;
        emit PermissionedExpectedOwnerChanged(w, old, newOwner, config.configVersion);
    }

    /// @notice Replaces the canonical U converter while the entire security is paused for trade and LP.
    function replaceUnderlyingLegalShareAdapter(address u, address newAdapter) external onlyRole(SYMBOL_ADMIN_ROLE) {
        UnderlyingConfig storage config = underlyings[u];
        if (
            config.securityId == 0 || newAdapter == config.legalShareAdapter
                || !_securityPausedForReplacement(config.securityId, PauseMode.TRADE)
                || !_securityPausedForReplacement(config.securityId, PauseMode.LP)
        ) revert InvalidConfig();
        uint32 version = config.legalAdapterVersion + 1;
        _validateLegalShareAdapter(newAdapter, u, version);
        address old = config.legalShareAdapter;
        config.legalShareAdapter = newAdapter;
        config.legalAdapterVersion = version;
        emit UnderlyingLegalShareAdapterChanged(u, old, newAdapter, version);
    }

    /// @notice Configures a separate receiver for a verified candidate or admitted stock W.
    function setExitAdmin(address w, address newAdmin) external onlyGovernor {
        _requireEnvironment();
        address u = _candidateUnderlying(w);
        _validateAssetIdentities(w, u);
        if (currencies[w].underlying != address(0) && currencies[w].underlying != u) {
            revert InvalidPermissionedConfig();
        }
        if (newAdmin == exitAdminOf[w]) revert InvalidStatus();
        _validateExitAdmin(w, u, newAdmin, currencies[w].expectedOwner);
        address old = exitAdminOf[w];
        exitAdminOf[w] = newAdmin;
        uint64 version = ++exitAdminVersion[w];
        emit ExitAdminUpdated(w, old, newAdmin, version);
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

    /// @notice Registers a pending pool for the LP Manager after validating its key and currencies.
    /// @param key Candidate V4 pool key.
    /// @return poolId Identifier derived from the full pool key.
    function registerPendingPool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (msg.sender != lpManager) revert InvalidPool();
        _requireEnvironment();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != hook || c0 == address(0) || c0 >= c1 || key.fee >= 1_000_000 || key.tickSpacing < 1
                || key.tickSpacing > 32767 || !_assetApproved(c0) || !_assetApproved(c1)
        ) revert InvalidPool();
        bytes32 s0 = underlyings[currencies[c0].underlying].securityId;
        bytes32 s1 = underlyings[currencies[c1].underlying].securityId;
        if ((s0 == 0) == (s1 == 0)) revert InvalidPool();
        poolId = PoolId.unwrap(key.toId());
        if (pools[poolId].status != PoolStatus.ABSENT) revert InvalidPool();
        pools[poolId] = PoolConfig(key, s0, s1, PoolStatus.PENDING, 1);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.ABSENT), uint8(PoolStatus.PENDING));
    }

    /// @notice Activates a pending pool and increments its currencies' and security's active-pool counts.
    /// @param poolId Registered pending pool to activate.
    /// @param sqrtPriceX96 Initial price used by PoolManager.
    /// @param creator Address that created the pool.
    function markPoolActive(bytes32 poolId, uint160 sqrtPriceX96, address creator) external {
        if (msg.sender != lpManager || pools[poolId].status != PoolStatus.PENDING) revert InvalidPool();
        PoolConfig storage pool = pools[poolId];
        pool.status = PoolStatus.ACTIVE;
        pool.version++;
        _updatePoolCounts(pool, true);
        emit PoolInitialized(poolId, sqrtPriceX96, creator);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.PENDING), uint8(PoolStatus.ACTIVE));
    }

    /// @notice Disables an active pool and decrements its currencies' and security's active-pool counts.
    /// @param poolId Active pool to disable.
    function disablePool(bytes32 poolId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.ACTIVE) revert InvalidStatus();
        pool.status = PoolStatus.DISABLED;
        pool.version++;
        _updatePoolCounts(pool, false);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.ACTIVE), uint8(PoolStatus.DISABLED));
    }

    /// @notice Re-enables a disabled pool only when both tokens and listed securities remain valid.
    /// @param poolId Disabled pool to enable.
    function enablePool(bytes32 poolId) external onlyRole(SYMBOL_ADMIN_ROLE) {
        PoolConfig storage pool = pools[poolId];
        if (pool.status != PoolStatus.DISABLED) revert InvalidStatus();
        address c0 = Currency.unwrap(pool.key.currency0);
        address c1 = Currency.unwrap(pool.key.currency1);
        if (
            !_assetApproved(c0) || !_assetApproved(c1)
                || (pool.securityId0 != 0 && !securities[pool.securityId0].listed)
                || (pool.securityId1 != 0 && !securities[pool.securityId1].listed)
        ) revert InvalidStatus();
        pool.status = PoolStatus.ACTIVE;
        pool.version++;
        if (!_isOperationAllowed(poolId, PauseMode.TRADE) || !_isOperationAllowed(poolId, PauseMode.LP)) {
            revert InvalidStatus();
        }
        _updatePoolCounts(pool, true);
        emit PoolStatusChanged(poolId, uint8(PoolStatus.DISABLED), uint8(PoolStatus.ACTIVE));
    }

    function _updatePoolCounts(PoolConfig storage pool, bool increment) private {
        address c0 = Currency.unwrap(pool.key.currency0);
        address c1 = Currency.unwrap(pool.key.currency1);
        // Every registered pool has exactly one permanent stock security.
        bytes32 securityId = pool.securityId0 == 0 ? pool.securityId1 : pool.securityId0;
        if (increment) {
            activePoolCountByCurrency[c0]++;
            activePoolCountByCurrency[c1]++;
            securities[securityId].activePoolCount++;
        } else {
            activePoolCountByCurrency[c0]--;
            activePoolCountByCurrency[c1]--;
            securities[securityId].activePoolCount--;
        }
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
        if (!_assetApproved(c0) || !_assetApproved(c1)) return false;
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

    /// @dev Immutable environment identities passed to the stateless linked validator.
    function _environment() private view returns (PermissionedValidationLib.Environment memory) {
        return PermissionedValidationLib.Environment(
            permissionsAdapterFactory,
            permissionedPoolManager,
            permissionedRouter,
            hook,
            lpManager,
            dataInbox,
            address(governanceAnchor),
            address(participantSbt)
        );
    }

    function _requireEnvironment() private view {
        if (permissionsAdapterFactory == address(0)) revert PermissionedEnvironmentNotBound();
    }

    function _securityPausedForReplacement(bytes32 securityId, PauseMode operation) private view returns (bool) {
        return _isPaused(PauseScope.GLOBAL, 0, operation) || _isPaused(PauseScope.SECURITY, securityId, operation)
            || (uint8(marketPauseMode[securityId]) & uint8(operation)) != 0;
    }

    function _assetApproved(address asset) private view returns (bool) {
        address u = currencies[asset].underlying;
        return u != address(0)
            ? currencies[asset].status == AssetStatus.APPROVED && securities[underlyings[u].securityId].listed
            : quoteTokens[asset].status == AssetStatus.APPROVED;
    }

    function _validateLegalShareAdapter(address adapter, address currency, uint32 version) private view {
        PermissionedValidationLib.validateLegalShareAdapter(adapter, currency, version);
    }

    function _candidateUnderlying(address w) private view returns (address) {
        return PermissionedValidationLib.candidateUnderlying(_environment(), w);
    }

    function _validateAssetIdentities(address w, address u) private view {
        PermissionedValidationLib.validateAssetIdentities(_environment(), w, u);
    }

    function _readDecimals(address token) private view returns (uint8) {
        return PermissionedValidationLib.readDecimals(token);
    }

    function _stockDecimals(address w, address u) private view returns (uint8) {
        return PermissionedValidationLib.stockDecimals(w, u);
    }

    function _validateOwner(address w, address u, address owner) private view {
        PermissionedValidationLib.validateOwner(w, u, owner);
    }

    function _validateExitAdmin(address w, address u, address admin, address expectedOwner) private view {
        PermissionedValidationLib.validateExitAdmin(_environment(), w, u, admin, expectedOwner);
    }

    function _validatePolicy(address w, address u, address owner) private view {
        PermissionedValidationLib.validatePolicy(_environment(), w, u, owner);
    }

    function _validateQuoteIdentity(address quote) private view {
        PermissionedValidationLib.validateQuoteIdentity(_environment(), quote);
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
