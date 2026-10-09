### src/v1/core/TSVRegistryV1.sol

```solidity
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

```

### src/v1/periphery/TSVSwapRouterV1.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SwapRequest, AssetStatus} from "tsv-v1/types/TSVTypes.sol";
import {SettlementAssetKind, SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
import {ISwapHookViews} from "tsv-v1/libraries/TSVSwapValidationLib.sol";
import {PermissionedValidationLib} from "tsv-v1/libraries/PermissionedValidationLib.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {IV4Router} from "tsv-v1/vendor/v4-router/interfaces/IV4Router.sol";
import {Actions} from "tsv-v1/vendor/v4-router/libraries/Actions.sol";
import {CalldataDecoder} from "tsv-v1/vendor/v4-router/libraries/CalldataDecoder.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice One-pool W/Q swaps. Users pay and receive U for stocks and original Q for quotes.
contract TSVSwapRouterV1 is TSVGoverned, PermissionedV4Router {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using CalldataDecoder for bytes;

    error InvalidRequest();
    error InvalidPool();
    error Expired();
    error SlippageExceeded();
    error InputAmountTooLarge();
    error SettlementMismatch();
    error Reentrancy();
    error WrappedExternalAdapterUnsupported();
    error InvalidCallbackContext();
    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    bool private entered;
    bytes32 private activeRequestHash;
    bytes32 private activePayloadHash;
    bytes32 private activePolicyHash;
    bytes32 private activePoolId;
    address private activeParticipant;
    address private activeSettlementParticipant;
    uint64 private activeDeadline;
    bool private activeExactInput;
    bool private callbackConsumed;
    uint256 private activeAmountIn;
    uint256 private activeAmountOut;
    address private activeInputCurrency;
    address private activeOutputCurrency;
    uint256 private activeStockSurplus;

    event SwapExecuted(
        bytes32 indexed poolId,
        address indexed participant,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint32 tradeDayId
    );

    /// @dev PM and the Registry Factory interface are fixed in implementation bytecode.
    constructor(address pm, address registry_)
        PermissionedV4Router(IPoolManager(pm), IPermissionsAdapterFactory(registry_))
    {}

    /// @notice Linked stateless validator used for runtime policy snapshots.
    function permissionedValidationLibrary() external pure returns (address) {
        return address(PermissionedValidationLib);
    }

    function initialize(address anchor, address pm, address registry_, address ledger_) external initializer {
        __TSVGoverned_init(anchor);
        if (
            pm.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0 || pm != address(poolManager)
                || registry_ != address(PERMISSIONS_ADAPTER_FACTORY)
        ) revert InvalidRequest();
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
        if (
            address(registry.governanceAnchor()) != anchor || address(ledger.governanceAnchor()) != anchor
                || address(ledger.registry()) != registry_
        ) revert InvalidRequest();
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Exact input may fill partially; only realized input is paid.
    function swapExactInput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swapUser(request, true);
    }

    /// @notice Exact output must fill exactly the requested amount.
    function swapExactOutput(SwapRequest calldata request)
        external
        nonReentrant
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swapUser(request, false);
    }

    /// @notice Reserved rejection entry for external DEX consumers.
    function swapExactInputFromAdapter(SwapRequest calldata, address) external pure returns (uint256, uint256) {
        revert WrappedExternalAdapterUnsupported();
    }

    /// @notice Returns the real user during an active operation, or zero while idle.
    function msgSender() public view override returns (address) {
        return entered ? activeParticipant : address(0);
    }

    function _swapUser(SwapRequest memory request, bool exactInput)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        _checkRequest(request);
        if (msg.sender == address(this)) revert Unauthorized();
        activeParticipant = msg.sender;
        activeSettlementParticipant = msg.sender;
        (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy) = _plans(request.key, msg.sender);
        bytes memory payload = _payload(request, exactInput);
        activePoolId = PoolId.unwrap(request.key.toId());
        activeDeadline = request.deadline;
        activeExactInput = exactInput;
        activeInputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency0 : request.key.currency1);
        activeOutputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency1 : request.key.currency0);
        activePayloadHash = keccak256(payload);
        activePolicyHash = policy;
        activeRequestHash = _requestHash(request, p0, p1);
        activeStockSurplus = _stockSurplus(p0, p1);
        bytes memory result = poolManager.unlock(payload);
        if (!callbackConsumed) revert InvalidCallbackContext();
        BalanceDelta delta;
        (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
        if (
            actualIn != activeAmountIn || actualOut != activeAmountOut
                || BalanceDelta.unwrap(delta) != BalanceDelta.unwrap(_delta(request.zeroForOne))
        ) revert InvalidCallbackContext();
        (, uint32 day) = ledger.currentTradeDay();
        int128 amountIn = -int128(uint128(actualIn));
        int128 amountOut = int128(uint128(actualOut));
        emit SwapExecuted(
            activePoolId,
            activeParticipant,
            request.zeroForOne,
            request.zeroForOne ? amountIn : amountOut,
            request.zeroForOne ? amountOut : amountIn,
            day
        );
        _clearContext();
    }

    /// @dev SafeCallback retains the external onlyPoolManager gate. This adds one-operation binding.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (
            !entered || callbackConsumed || activeParticipant == address(0) || activeRequestHash == bytes32(0)
                || keccak256(data) != activePayloadHash
        ) revert InvalidCallbackContext();
        callbackConsumed = true;
        SwapRequest memory request = _decodePayload(data);
        _checkRequest(request);
        (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy) =
            _plans(request.key, activeParticipant);
        if (policy != activePolicyHash || _requestHash(request, p0, p1) != activeRequestHash) {
            revert InvalidCallbackContext();
        }
        super._unlockCallback(data);
        _checkAmounts(request, activeAmountIn, activeAmountOut);
        if (
            poolManager.currencyDelta(address(this), request.key.currency0) != 0
                || poolManager.currencyDelta(address(this), request.key.currency1) != 0
        ) revert SettlementMismatch();
        (p0, p1, policy) = _plans(request.key, activeParticipant);
        if (policy != activePolicyHash || _requestHash(request, p0, p1) != activeRequestHash) {
            revert InvalidCallbackContext();
        }
        if (_stockSurplus(p0, p1) != activeStockSurplus) revert SettlementMismatch();
        return abi.encode(activeAmountIn, activeAmountOut, _delta(request.zeroForOne));
    }

    function _validatePoolKey(PoolKey memory key) internal view override {
        if (
            !entered || !callbackConsumed || PoolId.unwrap(key.toId()) != activePoolId
                || !registry.isTradable(activePoolId)
                || keccak256(abi.encode(registry.getPool(activePoolId).key)) != keccak256(abi.encode(key))
        ) revert InvalidPool();
        super._validatePoolKey(key);
    }

    /// @dev Captures both realized deltas before paying. Exactly one sync/pay/settle sequence.
    function _settle(Currency currency, address payer, uint256 amount) internal override {
        if (
            !entered || !callbackConsumed || payer != activeParticipant
                || Currency.unwrap(currency) != activeInputCurrency || activeAmountIn != 0 || amount == 0
                || amount != _getFullDebt(currency)
        ) revert InvalidCallbackContext();
        uint256 output = _getFullCredit(Currency.wrap(activeOutputCurrency));
        _checkRepresentable(amount, output);
        activeAmountIn = amount;
        activeAmountOut = output;
        poolManager.sync(currency);
        // Parent _pay enforces swappingEnabled and isAllowed, then calls a transfer-only implementation.
        _pay(currency, activeSettlementParticipant, amount);
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        address q = Currency.unwrap(currency);
        if (
            q != activeInputCurrency || payer != activeSettlementParticipant || payer == address(this)
                || registry.getCurrency(q).underlying != address(0)
                || registry.getQuoteToken(q).status != AssetStatus.APPROVED
        ) revert UnsupportedAsset(q);
        TSVPermissionedSettlementLib.transferExact(q, payer, address(poolManager), amount);
    }

    function _payPermissionedFromPayer(address payer, IPermissionsAdapter permissionsAdapter, address u, uint256 amount)
        internal
        override
    {
        address w = address(permissionsAdapter);
        if (
            w != activeInputCurrency || payer != activeSettlementParticipant || payer == address(this)
                || registry.getCurrency(w).underlying != u
        ) revert InvalidPermissionedConfig();
        TSVPermissionedSettlementLib.payStock(w, u, address(poolManager), payer, amount);
    }

    function _take(Currency currency, address recipient, uint256 amount) internal override {
        address c = Currency.unwrap(currency);
        if (
            !entered || !callbackConsumed || recipient != activeParticipant || c != activeOutputCurrency
                || activeAmountIn == 0 || amount == 0 || amount != activeAmountOut || amount != _getFullCredit(currency)
        ) revert InvalidCallbackContext();
        recipient = activeSettlementParticipant;
        address u = registry.getCurrency(c).underlying;
        if (u == address(0)) {
            if (registry.getQuoteToken(c).status != AssetStatus.APPROVED) revert UnsupportedAsset(c);
            uint256 pmBefore = IERC20(c).balanceOf(address(poolManager));
            uint256 recipientBefore = IERC20(c).balanceOf(recipient);
            super._take(currency, recipient, amount);
            TSVPermissionedSettlementLib.assertDecrease(pmBefore, IERC20(c).balanceOf(address(poolManager)), amount);
            TSVPermissionedSettlementLib.assertIncrease(recipientBefore, IERC20(c).balanceOf(recipient), amount);
        } else {
            TSVPermissionedSettlementLib.StockInventory memory before_ =
                TSVPermissionedSettlementLib.stockInventory(c, u, address(poolManager), recipient);
            uint256 recipientBefore = IERC20(u).balanceOf(recipient);
            super._take(currency, recipient, amount);
            TSVPermissionedSettlementLib.assertStockTake(
                before_, recipientBefore, c, u, address(poolManager), recipient, amount
            );
        }
    }

    function _plans(PoolKey memory key, address participant)
        private
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policy)
    {
        if (registry.hook() != address(0) && ISwapHookViews(registry.hook()).ledger() != address(ledger)) {
            revert InvalidPermissionedConfig();
        }
        return PermissionedValidationLib.swapPlans(address(registry), address(poolManager), key, participant);
    }

    function _stockSurplus(SettlementLegPlan memory p0, SettlementLegPlan memory p1) private view returns (uint256) {
        SettlementLegPlan memory stock = p0.kind == SettlementAssetKind.PERMISSIONED_STOCK ? p0 : p1;
        TSVPermissionedSettlementLib.StockInventory memory inventory = TSVPermissionedSettlementLib.stockInventory(
            stock.currency, stock.underlying, address(poolManager), activeSettlementParticipant
        );
        return inventory.collateral - inventory.supply;
    }

    function _checkRequest(SwapRequest memory request) private view {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
    }

    function _checkRepresentable(uint256 amountIn, uint256 amountOut) private pure {
        if (amountIn > uint256(uint128(type(int128).max))) revert InputAmountTooLarge();
        if (amountIn == 0 || amountOut == 0 || amountOut > uint256(uint128(type(int128).max))) {
            revert SlippageExceeded();
        }
    }

    function _checkAmounts(SwapRequest memory request, uint256 amountIn, uint256 amountOut) private view {
        _checkRepresentable(amountIn, amountOut);
        if (activeExactInput) {
            if (amountIn > request.amountSpecified || amountOut < request.limitAmount) revert SlippageExceeded();
        } else if (amountOut != request.amountSpecified || amountIn > request.limitAmount) {
            revert SlippageExceeded();
        }
    }

    function _requestHash(SwapRequest memory request, SettlementLegPlan memory p0, SettlementLegPlan memory p1)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                request,
                activeExactInput,
                activeParticipant,
                activeSettlementParticipant,
                p0,
                p1,
                activePayloadHash
            )
        );
    }

    function _payload(SwapRequest memory request, bool exactInput) private pure returns (bytes memory) {
        bytes[] memory params = new bytes[](3);
        Currency input = request.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.zeroForOne ? request.key.currency1 : request.key.currency0;
        if (exactInput) {
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, bytes("")
                )
            );
        } else {
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, bytes("")
                )
            );
        }
        params[1] = abi.encode(input, exactInput ? request.amountSpecified : request.limitAmount);
        params[2] = abi.encode(output, exactInput ? request.limitAmount : request.amountSpecified);
        return abi.encode(
            abi.encodePacked(
                uint8(exactInput ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _decodePayload(bytes calldata data) private view returns (SwapRequest memory request) {
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        if (
            actions.length != 3 || params.length != 3
                || uint8(actions[0])
                    != (activeExactInput ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE)
                || uint8(actions[1]) != Actions.SETTLE_ALL || uint8(actions[2]) != Actions.TAKE_ALL
        ) revert InvalidCallbackContext();
        if (activeExactInput) {
            IV4Router.ExactInputSingleParams calldata p = params[0].decodeSwapExactInSingleParams();
            if (p.hookData.length != 0 || p.minHopPriceX36 != 0) revert InvalidCallbackContext();
            request = SwapRequest(p.poolKey, p.zeroForOne, p.amountIn, p.amountOutMinimum, activeDeadline);
        } else {
            IV4Router.ExactOutputSingleParams calldata p = params[0].decodeSwapExactOutSingleParams();
            if (p.hookData.length != 0 || p.minHopPriceX36 != 0) revert InvalidCallbackContext();
            request = SwapRequest(p.poolKey, p.zeroForOne, p.amountOut, p.amountInMaximum, activeDeadline);
        }
        (Currency input, uint256 maxIn) = params[1].decodeCurrencyAndUint256();
        (Currency output, uint256 minOut) = params[2].decodeCurrencyAndUint256();
        if (
            Currency.unwrap(input) != activeInputCurrency || Currency.unwrap(output) != activeOutputCurrency
                || maxIn != (activeExactInput ? request.amountSpecified : request.limitAmount)
                || minOut != (activeExactInput ? request.limitAmount : request.amountSpecified)
        ) revert InvalidCallbackContext();
    }

    function _delta(bool zeroForOne) private view returns (BalanceDelta) {
        int128 input = -int128(uint128(activeAmountIn));
        int128 output = int128(uint128(activeAmountOut));
        return toBalanceDelta(zeroForOne ? input : output, zeroForOne ? output : input);
    }

    function _clearContext() private {
        delete activeRequestHash;
        delete activePayloadHash;
        delete activePolicyHash;
        delete activePoolId;
        delete activeParticipant;
        delete activeSettlementParticipant;
        delete activeDeadline;
        delete activeExactInput;
        delete callbackConsumed;
        delete activeAmountIn;
        delete activeAmountOut;
        delete activeInputCurrency;
        delete activeOutputCurrency;
        delete activeStockSurplus;
    }

    /// @dev Future upgrades must preserve immutable PM/Registry identities and the new storage layout.
    function _authorizeUpgrade(address implementation) internal view override {
        super._authorizeUpgrade(implementation);
        if (entered) revert Reentrancy();
        if (
            address(TSVSwapRouterV1(implementation).poolManager()) != address(poolManager)
                || address(TSVSwapRouterV1(implementation).PERMISSIONS_ADAPTER_FACTORY()) != address(registry)
        ) revert InvalidRequest();
    }
}

```

### src/v1/libraries/PermissionedValidationLib.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionedCurrencyConfig, UnderlyingConfig, QuoteTokenConfig, AssetStatus} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC165} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {TSVSwapValidationLib} from "tsv-v1/libraries/TSVSwapValidationLib.sol";

interface IPermissionedRegistryViews {
    function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory);
    function getUnderlying(address u) external view returns (UnderlyingConfig memory);
    function getQuoteToken(address q) external view returns (QuoteTokenConfig memory);
    function isPermissionedOwnerApproved(address owner) external view returns (bool);
    function exitAdminOf(address w) external view returns (address);
    function exitAdminVersion(address w) external view returns (uint64);
}

interface IPermissionedComponentV1 {
    function poolManager() external view returns (address);
    function registry() external view returns (address);
    function PERMISSIONS_ADAPTER_FACTORY() external view returns (address);
    function router() external view returns (address);
    function lpManager() external view returns (address);
    function ledger() external view returns (address);
}

interface IERC20DecimalsV1 {
    function decimals() external view returns (uint8);
}

/// @notice Linked, stateless read-only checks; Registry/Router retain roles, state and fund movements.
/// @dev External library calls execute by delegatecall. address(this) is the calling Registry or Router proxy.
library PermissionedValidationLib {
    error InvalidConfig();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    struct Environment {
        address permissionsAdapterFactory;
        address permissionedPoolManager;
        address permissionedRouter;
        address hook;
        address lpManager;
        address dataInbox;
        address governanceAnchor;
        address participantSbt;
    }

    /// @notice Router reuses the approved stateless library for runtime policy snapshots.
    /// @dev Delegatecall address(this) is the Router here; Registry views use the explicit R parameter.
    function swapPlans(address registry, address pm, PoolKey memory key, address participant)
        external
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policyHash)
    {
        return TSVSwapValidationLib.plans(ITSVPermissionedRegistry(registry), pm, key, participant);
    }

    /// @notice First-admission inventory only; reapproval deliberately does not invoke this check.
    function validateInitialInventory(address pm, address w, address u) external view {
        if (
            _staticWord(w, IERC20.totalSupply.selector, 0, 4) != 0
                || _staticWord(w, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                || _staticWord(u, IERC20.balanceOf.selector, uint160(w), 36) == 0
                || _staticWord(u, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                || IPoolManager(pm).protocolFeesAccrued(Currency.wrap(w)) != 0
        ) revert InvalidPermissionedConfig();
    }

    function validateLegalShareAdapter(address adapter, address currency, uint32 version) external view {
        _validateLegalShareAdapter(adapter, currency, version);
    }

    function candidateUnderlying(Environment memory e, address w) external view returns (address) {
        return _candidateUnderlying(e, w);
    }

    function validateAssetIdentities(Environment memory e, address w, address u) external view {
        _validateAssetIdentities(e, w, u);
    }

    function readDecimals(address token) external view returns (uint8) {
        return _readDecimals(token);
    }

    function stockDecimals(address w, address u) external view returns (uint8) {
        return _stockDecimals(w, u);
    }

    function validateOwner(address w, address u, address owner) external view {
        _validateOwner(w, u, owner);
    }

    function validateExitAdmin(Environment memory e, address w, address u, address admin, address expectedOwner)
        external
        view
    {
        _validateExitAdmin(e, w, u, admin, expectedOwner);
    }

    function validatePolicy(Environment memory e, address w, address u, address owner) external view {
        _validatePolicy(e, w, u, owner);
    }

    function validateQuoteIdentity(Environment memory e, address quote) external view {
        _validateQuoteIdentity(e, quote);
    }

    function validateEnvironment(Environment memory e, address factory, address router_)
        external
        view
        returns (address pm)
    {
        if (
            e.hook == address(0) || e.lpManager == address(0) || e.dataInbox == address(0) || factory.code.length == 0
                || router_.code.length == 0 || _isSystem(e, factory) || _isSystem(e, router_) || factory == router_
        ) revert InvalidPermissionedConfig();
        pm = _readAddress(factory, IPermissionsAdapterFactory.POOL_MANAGER.selector);
        if (
            pm.code.length == 0 || _isSystem(e, pm) || pm == factory || pm == router_
                || _readAddress(router_, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(e.hook, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(e.lpManager, IPermissionedComponentV1.poolManager.selector) != pm
                || _readAddress(router_, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(e.hook, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(e.lpManager, IPermissionedComponentV1.registry.selector) != address(this)
                || _readAddress(router_, IPermissionedComponentV1.PERMISSIONS_ADAPTER_FACTORY.selector) != address(this)
                || _readAddress(e.hook, IPermissionedComponentV1.router.selector) != router_
                || _readAddress(e.hook, IPermissionedComponentV1.lpManager.selector) != e.lpManager
        ) revert InvalidPermissionedConfig();
    }

    function _validateLegalShareAdapter(address adapter, address currency, uint32 version) private view {
        if (adapter.code.length == 0) revert InvalidConfig();
        (bool ok, bytes memory result) = adapter.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IDirectLegalShareAdapter).interfaceId)
        );
        uint256 supported;
        if (result.length >= 32) assembly ("memory-safe") { supported := mload(add(result, 32)) }
        if (
            !ok || supported != 1 || _readAddress(adapter, IDirectLegalShareAdapter.poolCurrency.selector) != currency
                || _staticWord(adapter, IDirectLegalShareAdapter.adapterVersion.selector, 0, 4) != version
        ) revert InvalidConfig();
    }

    /// @dev Shared strict getter decoding avoids duplicating external-call code at every policy check.
    function _staticWord(address target, bytes4 selector, uint256 argument, uint256 inputLength)
        private
        view
        returns (uint256 value)
    {
        bytes4 invalidSelector = InvalidPermissionedConfig.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), argument)
            let ok := staticcall(gas(), target, ptr, inputLength, 0, 32)
            if iszero(ok) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 32) {
                mstore(0, invalidSelector)
                revert(0, 4)
            }
            value := mload(0)
        }
    }

    function _readAddress(address target, bytes4 selector) private view returns (address) {
        uint256 value = _staticWord(target, selector, 0, 4);
        if (value > type(uint160).max) revert InvalidPermissionedConfig();
        return address(uint160(value));
    }

    function _readAddressArgument(address target, bytes4 selector, address argument) private view returns (address) {
        uint256 value = _staticWord(target, selector, uint160(argument), 36);
        if (value > type(uint160).max) revert InvalidPermissionedConfig();
        return address(uint160(value));
    }

    function _readBool(address target, bytes4 selector, address argument) private view returns (bool) {
        uint256 value = _staticWord(target, selector, uint160(argument), 36);
        if (value > 1) revert InvalidPermissionedConfig();
        return value == 1;
    }

    function _candidateUnderlying(Environment memory e, address w) private view returns (address u) {
        u = _readAddressArgument(
            e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, w
        );
        if (
            u == address(0)
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.verifiedPermissionsAdapterOf.selector, w
                    ) != u
        ) revert UnverifiedPermissionedAdapter(w);
        if (
            w.code.length == 0
                || _readAddress(w, IPermissionsAdapter.POOL_MANAGER.selector) != e.permissionedPoolManager
                || _readAddress(w, IPermissionsAdapter.PERMISSIONED_TOKEN.selector) != u
                || _readAddress(w, IPermissionsAdapter.allowListChecker.selector) != address(this)
        ) revert InvalidPermissionedConfig();
    }

    function _isSystem(Environment memory e, address a) private view returns (bool) {
        return a == address(this) || a == e.permissionedPoolManager || a == e.permissionsAdapterFactory
            || a == e.permissionedRouter || a == e.hook || a == e.lpManager || a == e.dataInbox
            || a == e.governanceAnchor || a == e.participantSbt
            || (e.hook != address(0) && a == _readAddress(e.hook, IPermissionedComponentV1.ledger.selector));
    }

    function _validateAssetIdentities(Environment memory e, address w, address u) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            u.code.length == 0 || w == u || _isSystem(e, w) || _isSystem(e, u)
                || r.getQuoteToken(w).status != AssetStatus.ABSENT || r.getQuoteToken(u).status != AssetStatus.ABSENT
                || r.getUnderlying(w).securityId != 0 || r.getCurrency(u).underlying != address(0)
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, u
                    ) != address(0)
        ) revert InvalidPermissionedConfig();
    }

    function _readDecimals(address token) private view returns (uint8 decimals) {
        try IERC20DecimalsV1(token).decimals() returns (uint8 value) {
            decimals = value;
        } catch {
            revert PermissionedMetadataMismatch();
        }
        if (decimals > 18) revert PermissionedMetadataMismatch();
    }

    function _stockDecimals(address w, address u) private view returns (uint8 decimals) {
        decimals = _readDecimals(u);
        if (_readDecimals(w) != decimals) revert PermissionedMetadataMismatch();
    }

    function _validateOwner(address w, address u, address owner) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            owner.code.length == 0 || !r.isPermissionedOwnerApproved(owner) || owner == w || owner == u
                || owner == r.exitAdminOf(w) || _readAddress(w, IPermissionsAdapter.owner.selector) != owner
        ) revert PermissionedPolicyMismatch();
    }

    function _validateExitAdmin(Environment memory e, address w, address u, address admin, address expectedOwner)
        private
        view
    {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            admin.code.length == 0 || admin == u || admin == w || _isSystem(e, admin)
                || r.getCurrency(admin).underlying != address(0) || r.getUnderlying(admin).securityId != 0
                || r.getQuoteToken(admin).status != AssetStatus.ABSENT
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, admin
                    ) != address(0) || admin == expectedOwner
                || admin == _readAddress(w, IPermissionsAdapter.owner.selector)
        ) revert PermissionedPolicyMismatch();
    }

    function _validatePolicy(Environment memory e, address w, address u, address owner) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        _validateOwner(w, u, owner);
        if (
            !_readBool(w, IPermissionsAdapter.allowedWrappers.selector, e.permissionedRouter)
                || !_readBool(w, IPermissionsAdapter.allowedHooks.selector, e.hook) || r.exitAdminVersion(w) == 0
        ) revert PermissionedPolicyMismatch();
        _validateExitAdmin(e, w, u, r.exitAdminOf(w), owner);
    }

    function _validateQuoteIdentity(Environment memory e, address quote) private view {
        IPermissionedRegistryViews r = IPermissionedRegistryViews(address(this));
        if (
            quote.code.length == 0 || _isSystem(e, quote) || r.getCurrency(quote).underlying != address(0)
                || r.getUnderlying(quote).securityId != 0
                || _readAddressArgument(
                        e.permissionsAdapterFactory, IPermissionsAdapterFactory.permissionsAdapterOf.selector, quote
                    ) != address(0)
        ) revert UnsupportedAsset(quote);
    }
}

```

### src/v1/libraries/TSVSwapValidationLib.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {
    AssetStatus,
    PoolStatus,
    PoolConfig,
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    QuoteTokenConfig
} from "tsv-v1/types/TSVTypes.sol";
import {SettlementAssetKind, SettlementLegPlan} from "tsv-v1/types/TSVSettlementTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Internal-only runtime policy derivation. No storage, role changes or asset transfers.
library TSVSwapValidationLib {
    using PoolIdLibrary for PoolKey;

    error InvalidPool();
    error Unauthorized();
    error PermissionedEnvironmentNotBound();
    error InvalidPermissionedConfig();
    error UnverifiedPermissionedAdapter(address currency);
    error PermissionedMetadataMismatch();
    error PermissionedPolicyMismatch();
    error UnsupportedAsset(address currency);

    function plans(ITSVPermissionedRegistry r, address pm, PoolKey memory key, address participant)
        internal
        view
        returns (SettlementLegPlan memory p0, SettlementLegPlan memory p1, bytes32 policyHash)
    {
        address f = r.permissionsAdapterFactory();
        if (f == address(0)) revert PermissionedEnvironmentNotBound();
        if (
            r.permissionedPoolManager() != pm || r.POOL_MANAGER() != pm || r.permissionedRouter() != address(this)
                || r.permissionedAllowlistChecker() != address(r)
        ) revert InvalidPermissionedConfig();
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory pool = r.getPool(id);
        if (
            pool.status != PoolStatus.ACTIVE || !r.isTradable(id) || address(key.hooks) != r.hook()
                || keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))
        ) revert InvalidPool();
        p0 = _leg(r, pm, f, Currency.unwrap(key.currency0), pool.securityId0, participant);
        p1 = _leg(r, pm, f, Currency.unwrap(key.currency1), pool.securityId1, participant);
        if (p0.kind == p1.kind) revert InvalidPool();
        policyHash = keccak256(
            abi.encode(
                address(r),
                f,
                pm,
                address(this),
                r.hook(),
                r.lpManager(),
                r.dataInbox(),
                address(r.governanceAnchor()),
                address(r.participantSbt()),
                r.sbtTokenId(),
                pool.version,
                r.getSecurity(pool.securityId0).version,
                r.getSecurity(pool.securityId1).version,
                r.marketSequence(pool.securityId0),
                r.marketSequence(pool.securityId1),
                p0,
                p1
            )
        );
    }

    function _leg(ITSVPermissionedRegistry r, address pm, address f, address c, bytes32 securityId, address participant)
        private
        view
        returns (SettlementLegPlan memory p)
    {
        PermissionedCurrencyConfig memory w = r.getCurrency(c);
        p.currency = c;
        if (w.underlying == address(0)) {
            QuoteTokenConfig memory q = r.getQuoteToken(c);
            if (
                c.code.length == 0 || q.status != AssetStatus.APPROVED || securityId != 0
                    || r.getUnderlying(c).securityId != 0 || _system(r, pm, f, c)
                    || IPermissionsAdapterFactory(f).permissionsAdapterOf(c) != address(0)
            ) revert UnsupportedAsset(c);
            if (_decimals(c) != q.rawDecimals) revert PermissionedMetadataMismatch();
            p.kind = SettlementAssetKind.QUOTE_ERC20;
            p.rawDecimals = q.rawDecimals;
            p.configVersion = q.configVersion;
            return p;
        }
        UnderlyingConfig memory u = r.getUnderlying(w.underlying);
        if (w.status != AssetStatus.APPROVED || securityId == 0 || u.securityId != securityId) revert InvalidPool();
        IPermissionsAdapter adapter = IPermissionsAdapter(c);
        if (
            IPermissionsAdapterFactory(f).permissionsAdapterOf(c) != w.underlying
                || IPermissionsAdapterFactory(f).verifiedPermissionsAdapterOf(c) != w.underlying
        ) revert UnverifiedPermissionedAdapter(c);
        if (
            c.code.length == 0 || w.underlying.code.length == 0 || c == w.underlying || adapter.POOL_MANAGER() != pm
                || address(adapter.PERMISSIONED_TOKEN()) != w.underlying
                || address(adapter.allowListChecker()) != address(r) || _system(r, pm, f, c)
                || _system(r, pm, f, w.underlying) || r.getQuoteToken(c).status != AssetStatus.ABSENT
                || r.getQuoteToken(w.underlying).status != AssetStatus.ABSENT
                || r.getCurrency(w.underlying).underlying != address(0)
                || IPermissionsAdapterFactory(f).permissionsAdapterOf(w.underlying) != address(0)
        ) revert InvalidPermissionedConfig();
        if (_decimals(c) != u.rawDecimals || _decimals(w.underlying) != u.rawDecimals) {
            revert PermissionedMetadataMismatch();
        }
        if (
            u.legalShareAdapter.code.length == 0 || u.legalAdapterVersion == 0
                || !IERC165(u.legalShareAdapter).supportsInterface(type(IDirectLegalShareAdapter).interfaceId)
                || IDirectLegalShareAdapter(u.legalShareAdapter).poolCurrency() != w.underlying
                || IDirectLegalShareAdapter(u.legalShareAdapter).adapterVersion() != u.legalAdapterVersion
        ) revert InvalidPermissionedConfig();
        address exitAdmin = r.exitAdminOf(c);
        uint64 exitVersion = r.exitAdminVersion(c);
        if (
            w.expectedOwner.code.length == 0 || adapter.owner() != w.expectedOwner
                || !r.isPermissionedOwnerApproved(w.expectedOwner) || !adapter.allowedWrappers(address(this))
                || !adapter.allowedHooks(IHooks(r.hook())) || !adapter.swappingEnabled() || exitVersion == 0
                || exitAdmin.code.length == 0 || exitAdmin == w.expectedOwner || exitAdmin == c
                || exitAdmin == w.underlying || _system(r, pm, f, exitAdmin)
                || r.getCurrency(exitAdmin).underlying != address(0) || r.getUnderlying(exitAdmin).securityId != 0
                || r.getQuoteToken(exitAdmin).status != AssetStatus.ABSENT
                || IPermissionsAdapterFactory(f).permissionsAdapterOf(exitAdmin) != address(0)
        ) revert PermissionedPolicyMismatch();
        if (!adapter.isAllowed(participant, PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
        p.kind = SettlementAssetKind.PERMISSIONED_STOCK;
        p.underlying = w.underlying;
        p.rawDecimals = u.rawDecimals;
        p.expectedOwner = w.expectedOwner;
        p.configVersion = w.configVersion;
        p.securityId = u.securityId;
        p.legalShareAdapter = u.legalShareAdapter;
        p.legalAdapterVersion = u.legalAdapterVersion;
        p.exitAdmin = exitAdmin;
        p.exitAdminVersion = exitVersion;
    }

    function _system(ITSVPermissionedRegistry r, address pm, address f, address a) private view returns (bool) {
        return a == address(r) || a == pm || a == f || a == address(this) || a == r.hook() || a == r.lpManager()
            || a == r.dataInbox() || a == address(r.governanceAnchor()) || a == address(r.participantSbt())
            || a == ISwapHookViews(r.hook()).ledger();
    }

    function _decimals(address token) private view returns (uint8 value) {
        try IERC20Metadata(token).decimals() returns (uint8 actual) {
            value = actual;
        } catch {
            revert PermissionedMetadataMismatch();
        }
        if (value > 18) revert PermissionedMetadataMismatch();
    }
}

interface ISwapHookViews {
    function ledger() external view returns (address);
}

```

### src/v1/libraries/TSVPermissionedSettlementLib.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

/// @notice Internal-only exact transfer and inventory checks. Never syncs or settles PoolManager debt.
library TSVPermissionedSettlementLib {
    using SafeERC20 for IERC20;

    error SettlementMismatch();

    struct StockInventory {
        uint256 collateral;
        uint256 supply;
        uint256 pmBalance;
    }

    function stockInventory(address w, address u, address pm, address participant)
        internal
        view
        returns (StockInventory memory s)
    {
        s.collateral = IERC20(u).balanceOf(w);
        s.supply = IERC20(w).totalSupply();
        s.pmBalance = IERC20(w).balanceOf(pm);
        if (
            s.collateral < s.supply || s.pmBalance != s.supply || IERC20(u).balanceOf(pm) != 0
                || IERC20(u).balanceOf(address(this)) != 0 || IERC20(w).balanceOf(address(this)) != 0
                || IERC20(w).balanceOf(participant) != 0
        ) revert SettlementMismatch();
    }

    function transferExact(address token, address payer, address recipient, uint256 amount) internal {
        uint256 payerBefore = IERC20(token).balanceOf(payer);
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransferFrom(payer, recipient, amount);
        assertDecrease(payerBefore, IERC20(token).balanceOf(payer), amount);
        assertIncrease(recipientBefore, IERC20(token).balanceOf(recipient), amount);
    }

    function payStock(address w, address u, address pm, address payer, uint256 amount) internal {
        StockInventory memory before_ = stockInventory(w, u, pm, payer);
        transferExact(u, payer, w, amount);
        IPermissionsAdapter(w).wrapToPoolManager(amount);
        StockInventory memory after_ = stockInventory(w, u, pm, payer);
        assertIncrease(before_.collateral, after_.collateral, amount);
        assertIncrease(before_.supply, after_.supply, amount);
        assertIncrease(before_.pmBalance, after_.pmBalance, amount);
        if (before_.collateral - before_.supply != after_.collateral - after_.supply) revert SettlementMismatch();
    }

    function assertStockTake(
        StockInventory memory before_,
        uint256 recipientBefore,
        address w,
        address u,
        address pm,
        address recipient,
        uint256 amount
    ) internal view {
        StockInventory memory after_ = stockInventory(w, u, pm, recipient);
        assertDecrease(before_.collateral, after_.collateral, amount);
        assertDecrease(before_.supply, after_.supply, amount);
        assertDecrease(before_.pmBalance, after_.pmBalance, amount);
        assertIncrease(recipientBefore, IERC20(u).balanceOf(recipient), amount);
        if (before_.collateral - before_.supply != after_.collateral - after_.supply) revert SettlementMismatch();
    }

    function assertIncrease(uint256 before_, uint256 after_, uint256 amount) internal pure {
        if (after_ < before_ || after_ - before_ != amount) revert SettlementMismatch();
    }

    function assertDecrease(uint256 before_, uint256 after_, uint256 amount) internal pure {
        if (after_ > before_ || before_ - after_ != amount) revert SettlementMismatch();
    }
}

```

### src/v1/types/TSVTypes.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Admission state for a pool Currency registered in the Registry.
enum AssetStatus {
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

/// @notice A registered stock PermissionsAdapter (W); underlying identity is permanent.
struct PermissionedCurrencyConfig {
    address underlying;
    address expectedOwner;
    AssetStatus status;
    uint64 configVersion;
}

/// @notice Canonical security, precision and legal-share conversion for an underlying (U).
struct UnderlyingConfig {
    bytes32 securityId;
    address legalShareAdapter;
    uint32 legalAdapterVersion;
    uint8 rawDecimals;
}

/// @notice An independently registered original quote ERC-20 (Q).
struct QuoteTokenConfig {
    uint8 rawDecimals;
    AssetStatus status;
    uint64 configVersion;
}

/// @notice Reviewed stock admission input; U and decimals are derived from trusted contracts.
struct PermissionedAdmission {
    address currency;
    bytes32 securityId;
    address expectedOwner;
    address legalShareAdapter;
}

/// @notice Registry state for one listed or delisted security.
struct SecurityConfig {
    /// @notice Unique internal security identifier.
    bytes32 securityId;
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

/// @notice One-pool user request for permissioned-stock/original-quote exact-in/out swaps.
/// @dev W raw equals U raw; users approve and exchange U for the stock leg. External Adapters are rejected.
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

### src/v1/types/TSVSettlementTypes.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Runtime classification for a single swap; never persisted as asset configuration.
enum SettlementAssetKind {
    PERMISSIONED_STOCK,
    QUOTE_ERC20
}

/// @notice Immutable-for-the-operation settlement policy derived from the Registry and actual contracts.
struct SettlementLegPlan {
    SettlementAssetKind kind;
    address currency;
    address underlying;
    uint8 rawDecimals;
    address expectedOwner;
    uint64 configVersion;
    bytes32 securityId;
    address legalShareAdapter;
    uint32 legalAdapterVersion;
    address exitAdmin;
    uint64 exitAdminVersion;
}

```

### src/v1/core/TSVHookV1.sol

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
import {
    PoolConfig,
    PoolStatus,
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    AssetStatus,
    LPHookContext,
    LPOperationMode
} from "tsv-v1/types/TSVTypes.sol";
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
        PermissionedCurrencyConfig memory config = registry.getCurrency(currency);
        if (config.underlying == address(0)) {
            if (registry.getQuoteToken(currency).status != AssetStatus.APPROVED || securityId != 0) {
                revert InvalidPool();
            }
            return 0;
        }
        UnderlyingConfig memory underlying = registry.getUnderlying(config.underlying);
        if (
            config.status != AssetStatus.APPROVED || securityId == 0 || underlying.securityId != securityId
                || underlying.legalShareAdapter == address(0) || underlying.legalAdapterVersion == 0
        ) revert InvalidPool();
        IDirectLegalShareAdapter adapter = IDirectLegalShareAdapter(underlying.legalShareAdapter);
        if (adapter.poolCurrency() != config.underlying || adapter.adapterVersion() != underlying.legalAdapterVersion) {
            revert InvalidPool();
        }
        if (delta == 0) return 0;
        uint256 rawAmount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        uint256 shares = adapter.toLegalShares(config.underlying, rawAmount);
        if (shares == 0) revert InvalidPool();
        return shares;
    }
}

```

### src/v1/core/TSVVolumeLedgerV1.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    PermissionedCurrencyConfig,
    UnderlyingConfig,
    AssetStatus,
    PoolConfig,
    PoolStatus
} from "tsv-v1/types/TSVTypes.sol";
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
        PermissionedCurrencyConfig memory config = registry.getCurrency(currency);
        if (config.underlying == address(0)) {
            if (
                registry.getQuoteToken(currency).status != AssetStatus.APPROVED || securityId != 0
                    || legalSharesWad != 0
            ) revert InvalidLegalShareAmount();
            return;
        }
        UnderlyingConfig memory underlying = registry.getUnderlying(config.underlying);
        if (
            config.status != AssetStatus.APPROVED || securityId == 0 || underlying.securityId != securityId
                || underlying.legalShareAdapter == address(0) || underlying.legalAdapterVersion == 0
        ) revert InvalidLegalShareAmount();
        if (delta == 0) {
            if (legalSharesWad != 0) revert InvalidLegalShareAmount();
            return;
        }
        if (legalSharesWad == 0) revert InvalidLegalShareAmount();
        uint256 raw = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        _consume(securityId, day, legalSharesWad);
        emit SwapAccounted(
            poolId, securityId, currency, delta < 0, day, raw, legalSharesWad, underlying.legalAdapterVersion
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

### src/v1/governance/TSVGoverned.sol

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

### src/v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {V4Router, IPoolManager, Currency, PoolKey} from "../../V4Router.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @title Abstract base for routers that support permissioned V4 pools
/// @notice Provides _pay and _mapSettleAmount overrides for wrapping/unwrapping permissioned tokens.
///         Concrete routers (e.g., UniversalRouter's V4SwapRouter) inherit this contract.
abstract contract PermissionedV4Router is V4Router {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    error Unauthorized();
    error SwappingDisabled();
    error HookNotAllowed();

    constructor(IPoolManager poolManager_, IPermissionsAdapterFactory permissionsAdapterFactory)
        V4Router(poolManager_)
    {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
    }

    /// @inheritdoc V4Router
    /// @dev Permission enforcement for a permissioned pool lives in its hook, so a pool holding a
    ///      verified adapter must not be swapped through unless the adapter's owner has allow-listed
    ///      that hook. Rejecting only `address(0)` is insufficient — a no-op hook, or an address mined
    ///      without `BEFORE_SWAP_FLAG`, would otherwise pass.
    function _validatePoolKey(PoolKey memory poolKey) internal view virtual override {
        if (address(PERMISSIONS_ADAPTER_FACTORY) == address(0)) return;
        _validateHook(poolKey.currency0, poolKey.hooks);
        _validateHook(poolKey.currency1, poolKey.hooks);
    }

    /// @notice Reverts if `currency` is a verified permissions adapter that has not allow-listed `hooks`
    function _validateHook(Currency currency, IHooks hooks) internal view {
        if (PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return;
        if (!IPermissionsAdapter(Currency.unwrap(currency)).allowedHooks(hooks)) revert HookNotAllowed();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));

        // If the token is permissioned, validate swapping is enabled and the sender is swap-allowed
        if (permissionedToken != address(0)) {
            IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
            if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
        }

        super._take(currency, recipient, amount);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            _payStandard(currency, payer, amount);
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            _payPermissionedFromPayer(payer, permissionsAdapter, permissionedToken, amount);
        }
    }

    /// @notice Hook for concrete routers to implement standard (non-permissioned) payment
    function _payStandard(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice Hook for concrete routers to implement payer-to-adapter transfer (e.g., via Permit2)
    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal virtual;

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual override returns (uint256) {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        // use the default implementation unless the currency is a permissioned token with a balance on the router
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }
}

```

### src/v1/vendor/v4-router/V4Router.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

import {PathKey} from "./libraries/PathKey.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap v4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, BaseActionsRouter, DeltaResolver {
    using SafeCast for *;
    using CalldataDecoder for bytes;
    using BipsLibrary for uint256;

    uint256 private constant PRECISION = 1e36;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP_EXACT_IN) {
                IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                _swapExactInput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT) {
                IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                _swapExactOutput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
                return;
            }
        } else {
            if (action == Actions.SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullDebt(currency);
                if (amount > maxAmount) revert V4TooMuchRequested(maxAmount, amount);
                _settle(currency, msgSender(), amount);
                return;
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, uint256 minAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullCredit(currency);
                if (amount < minAmount) revert V4TooLittleReceived(minAmount, amount);
                _take(currency, msgSender(), amount);
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullCredit(currency).calculatePortion(bips));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params) private {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut = _swapOutput(
            _swap(params.poolKey, params.zeroForOne, -int256(uint256(amountIn)), params.hookData), params.zeroForOne
        );
        if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOut) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooLittleReceivedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactInput(IV4Router.ExactInputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // The output delta will always be positive, except for when interacting with certain hook pools
                amountOut =
                    _swapOutput(_swap(poolKey, zeroForOne, -int256(uint256(amountIn)), pathKey.hookData), zeroForOne);

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = amountOut * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i];
                    if (priceX36 < minPrice) revert V4TooLittleReceivedPerHop(i, minPrice, priceX36);
                }

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams calldata params) private {
        uint128 amountOut = params.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut =
                _getFullDebt(params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0).toUint128();
        }
        BalanceDelta delta = _swap(params.poolKey, params.zeroForOne, int256(uint256(amountOut)), params.hookData);
        // exact output is all-or-nothing: a pool can deliver less than requested if it runs out of
        // liquidity before the price limit. Reverting on a shortfall keeps "exact output" exact;
        // over-delivery (possible only via hook pools) is allowed.
        uint128 amountOutActual = _swapOutput(delta, params.zeroForOne);
        if (amountOutActual < amountOut) revert V4ExactOutputUnfilled(amountOut, amountOutActual);
        uint128 amountIn = _swapInput(delta, params.zeroForOne);
        if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOutActual) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooMuchRequestedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactOutput(IV4Router.ExactOutputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            if (amountOut == ActionConstants.OPEN_DELTA) {
                amountOut = _getFullDebt(currencyOut).toUint128();
            }

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // The output delta will always be positive, except for when interacting with certain hook pools
                BalanceDelta delta = _swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);
                uint128 amountOutActual = _swapOutput(delta, !oneForZero);
                // Every hop must fill. PoolManager nets one delta per currency across the whole unlock,
                // so an intermediate shortfall can be absorbed by same-currency credit and settle
                // silently rather than reverting.
                if (amountOutActual < amountOut) {
                    revert V4ExactOutputUnfilled(amountOut, amountOutActual);
                }
                amountIn = _swapInput(delta, !oneForZero);

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = uint256(amountOutActual) * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i - 1];
                    if (priceX36 < minPrice) revert V4TooMuchRequestedPerHop(i - 1, minPrice, priceX36);
                }
                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        }
    }

    /// @notice Validates a pool before swapping through it
    /// @dev No-op by default. Called once per swap, i.e. for every hop of a multi-hop route.
    ///      Inheriting routers override this to reject pools they must not trade in.
    function _validatePoolKey(PoolKey memory poolKey) internal view virtual {}

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (BalanceDelta delta)
    {
        _validatePoolKey(poolKey);

        // for protection of exactOut swaps, sqrtPriceLimit is not exposed as a feature in this contract
        delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hookData
        );
    }

    /// @notice The positive input amount a swap consumed, derived from its balance delta.
    /// @dev The spent currency's delta is negative (owed to the pool), so negate it to a positive amount.
    function _swapInput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()))).toUint128();
    }

    /// @notice The positive output amount a swap produced, derived from its balance delta. For an
    ///         exact-output swap this is the REALIZED output, which can be less than the requested
    ///         amount when the pool lacks the liquidity to fill it before the price limit.
    function _swapOutput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (zeroForOne ? delta.amount1() : delta.amount0()).toUint128();
    }
}

```

### src/v1/vendor/v4-router/base/BaseActionsRouter.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @notice Abstract contract for performing a combination of actions on Uniswap v4.
/// @dev Suggested uint256 action values are defined in Actions.sol, however any definition can be used
abstract contract BaseActionsRouter is IMsgSender, SafeCallback {
    using CalldataDecoder for bytes;

    /// @notice emitted when different numbers of parameters and actions are provided
    error InputLengthMismatch();

    /// @notice emitted when an inheriting contract does not support an action
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice internal function that triggers the execution of a set of actions on v4
    /// @dev inheriting contracts should call this function to trigger execution
    function _executeActions(bytes calldata unlockData) internal {
        poolManager.unlock(unlockData);
    }

    /// @notice function that is called by the PoolManager through the SafeCallback.unlockCallback
    /// @param data Abi encoding of (bytes actions, bytes[] params)
    /// where params[i] is the encoded parameters for actions[i]
    function _unlockCallback(bytes calldata data) internal virtual override returns (bytes memory) {
        // abi.decode(data, (bytes, bytes[]));
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutUnlock(actions, params);
        return "";
    }

    function _executeActionsWithoutUnlock(bytes calldata actions, bytes[] calldata params) internal {
        uint256 numActions = actions.length;
        if (numActions != params.length) revert InputLengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            _handleAction(action, params[actionIndex]);
        }
    }

    /// @notice function to handle the parsing and execution of an action and its parameters
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice function that returns address considered executor of the actions
    /// @dev The other context functions, _msgData and _msgValue, are not supported by this contract
    /// In many contracts this will be the address that calls the initial entry point that calls `_executeActions`
    /// `msg.sender` shouldn't be used, as this will be the v4 pool manager contract that calls `unlockCallback`
    /// If using ReentrancyLock.sol, this function can return _getLocker()
    function msgSender() public view virtual returns (address);

    /// @notice Calculates the address for a action
    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }

    /// @notice Calculates the payer for an action
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msgSender() : address(this);
    }
}

```

### src/v1/vendor/v4-router/base/DeltaResolver.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @notice Abstract contract used to sync, send, and settle funds to the pool manager
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
abstract contract DeltaResolver is ImmutableState {
    using TransientStateLibrary for IPoolManager;

    /// @notice Emitted when unexpected negative delta is found.
    error DeltaNotPositive(Currency currency);
    /// @notice Emitted when unexpected positive delta is found.
    error DeltaNotNegative(Currency currency);
    /// @notice Emitted when the contract does not have enough balance to wrap or unwrap.
    error InsufficientBalance();

    /// @notice Take an amount of currency out of the PoolManager
    /// @param currency Currency to take
    /// @param recipient Address to receive the currency
    /// @param amount Amount to take
    /// @dev Returns early if the amount is 0
    function _take(Currency currency, address recipient, uint256 amount) internal virtual {
        if (amount == 0) return;
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Pay and settle a currency to the PoolManager
    /// @dev The implementing contract must ensure that the `payer` is a secure address
    /// @param currency Currency to settle
    /// @param payer Address of the payer
    /// @param amount Amount to send
    /// @dev Returns early if the amount is 0
    function _settle(Currency currency, address payer, uint256 amount) internal virtual {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice Abstract function for contracts to implement paying tokens to the poolManager
    /// @dev The recipient of the payment should be the poolManager
    /// @param token The token to settle. This is known not to be the native currency
    /// @param payer The address who should pay tokens
    /// @param amount The number of tokens to send
    function _pay(Currency token, address payer, uint256 amount) internal virtual;

    /// @notice Obtain the full amount owed by this contract (negative delta)
    /// @param currency Currency to get the delta for
    /// @return amount The amount owed by this contract as a uint256
    function _getFullDebt(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is positive, it should be taken not settled.
        if (_amount > 0) revert DeltaNotNegative(currency);
        // Casting is safe due to limits on the total supply of a pool
        amount = uint256(-_amount);
    }

    /// @notice Obtain the full credit owed to this contract (positive delta)
    /// @param currency Currency to get the delta for
    /// @return amount The amount owed to this contract as a uint256
    function _getFullCredit(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is negative, it should be settled not taken.
        if (_amount < 0) revert DeltaNotPositive(currency);
        amount = uint256(_amount);
    }

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            return currency.balanceOfSelf();
        } else if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullDebt(currency);
        } else {
            return amount;
        }
    }

    /// @notice Calculates the amount for a take action
    function _mapTakeAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullCredit(currency);
        } else {
            return amount;
        }
    }

    /// @notice Calculates the sanitized amount before wrapping/unwrapping.
    /// @param inputCurrency The currency, either native or wrapped native, that this contract holds
    /// @param amount The amount to wrap or unwrap. Can be CONTRACT_BALANCE, OPEN_DELTA or a specific amount
    /// @param outputCurrency The currency after the wrap/unwrap that the user may owe a balance in on the poolManager
    function _mapWrapUnwrapAmount(Currency inputCurrency, uint256 amount, Currency outputCurrency)
        internal
        view
        returns (uint256)
    {
        // if wrapping, the balance in this contract is in ETH
        // if unwrapping, the balance in this contract is in WETH
        uint256 balance = inputCurrency.balanceOf(address(this));
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            // return early to avoid unnecessary balance check
            return balance;
        }
        if (amount == ActionConstants.OPEN_DELTA) {
            // if wrapping, the open currency on the PoolManager is WETH.
            // if unwrapping, the open currency on the PoolManager is ETH.
            // note that we use the DEBT amount. Positive deltas can be taken and then wrapped.
            amount = _getFullDebt(outputCurrency);
        }
        if (amount > balance) revert InsufficientBalance();
        return amount;
    }
}

```

### src/v1/vendor/v4-router/base/ImmutableState.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title Immutable State
/// @notice A collection of immutable state variables, commonly used across multiple contracts
contract ImmutableState is IImmutableState {
    /// @inheritdoc IImmutableState
    IPoolManager public immutable poolManager;

    /// @notice Thrown when the caller is not PoolManager
    error NotPoolManager();

    /// @notice Only allow calls from the PoolManager contract
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}

```

### src/v1/vendor/v4-router/base/SafeCallback.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title Safe Callback
/// @notice A contract that only allows the Uniswap v4 PoolManager to call the unlockCallback
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @inheritdoc IUnlockCallback
    /// @dev We force the onlyPoolManager modifier by exposing a virtual function after the onlyPoolManager check.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev to be implemented by the child contract, to safely guarantee the logic is only executed by the PoolManager
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}

```

### src/v1/vendor/v4-router/libraries/CalldataDecoder.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "v4-core/types/Currency.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title Library for abi decoding in calldata
library CalldataDecoder {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice mask used for offsets and lengths to ensure no overflow
    /// @dev no sane abi encoding will pass in an offset or length greater than type(uint32).max
    ///      (note that this does deviate from standard solidity behavior and offsets/lengths will
    ///      be interpreted as mod type(uint32).max which will only impact malicious/buggy callers)
    uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
    uint256 constant OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN = 0xffffffe0;

    /// @notice equivalent to SliceOutOfBounds.selector, stored in least-significant bits
    uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @dev equivalent to: abi.decode(params, (bytes, bytes[])) in calldata (requires strict abi encoding)
    function decodeActionsRouterParams(bytes calldata _bytes)
        internal
        pure
        returns (bytes calldata actions, bytes[] calldata params)
    {
        assembly ("memory-safe") {
            // Strict encoding requires that the data begin with:
            // 0x00: 0x40 (offset to `actions.length`)
            // 0x20: 0x60 + actions.length (offset to `params.length`)
            // 0x40: `actions.length`
            // 0x60: beginning of actions

            // Verify actions offset matches strict encoding
            let invalidData := xor(calldataload(_bytes.offset), 0x40)
            actions.offset := add(_bytes.offset, 0x60)
            actions.length := and(calldataload(add(_bytes.offset, 0x40)), OFFSET_OR_LENGTH_MASK)

            // Round actions length up to be word-aligned, and add 0x60 (for the first 3 words of encoding)
            let paramsLengthOffset := add(and(add(actions.length, 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x60)
            // Verify params offset matches strict encoding
            invalidData := or(invalidData, xor(calldataload(add(_bytes.offset, 0x20)), paramsLengthOffset))
            let paramsLengthPointer := add(_bytes.offset, paramsLengthOffset)
            params.length := and(calldataload(paramsLengthPointer), OFFSET_OR_LENGTH_MASK)
            params.offset := add(paramsLengthPointer, 0x20)

            // Expected offset for `params[0]` is params.length * 32
            // As the first `params.length` slots are pointers to each of the array element lengths
            let tailOffset := shl(5, params.length)
            let expectedOffset := tailOffset

            for { let offset := 0 } lt(offset, tailOffset) { offset := add(offset, 32) } {
                let itemLengthOffset := calldataload(add(params.offset, offset))
                // Verify that the offset matches the expected offset from strict encoding
                invalidData := or(invalidData, xor(itemLengthOffset, expectedOffset))
                let itemLengthPointer := add(params.offset, itemLengthOffset)
                let length :=
                    add(and(add(calldataload(itemLengthPointer), 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x20)
                expectedOffset := add(expectedOffset, length)
            }

            // if the data encoding was invalid, or the provided bytes string isnt as long as the encoding says, revert
            if or(invalidData, lt(add(_bytes.length, _bytes.offset), add(params.offset, expectedOffset))) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }

    /// @dev equivalent to: abi.decode(params, (uint256, uint256, uint128, uint128, bytes)) in calldata
    function decodeModifyLiquidityParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes calldata hookData)
    {
        // no length check performed, as there is a length check in `toBytes`
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            liquidity := calldataload(add(params.offset, 0x20))
            amount0 := calldataload(add(params.offset, 0x40))
            amount1 := calldataload(add(params.offset, 0x60))
        }

        hookData = params.toBytes(4);
    }

    /// @dev equivalent to: abi.decode(params, (uint256, uint128, uint128, bytes)) in calldata
    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
    {
        // no length check performed, as there is a length check in `toBytes`
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Max := calldataload(add(params.offset, 0x20))
            amount1Max := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev equivalent to: abi.decode(params, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes)) in calldata
    function decodeMintParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // no length check performed, as there is a length check in `toBytes`
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            liquidity := calldataload(add(params.offset, 0xe0))
            amount0Max := calldataload(add(params.offset, 0x100))
            amount1Max := calldataload(add(params.offset, 0x120))
            owner := calldataload(add(params.offset, 0x140))
        }
        hookData = params.toBytes(11);
    }

    /// @dev equivalent to: abi.decode(params, (PoolKey, int24, int24, uint128, uint128, address, bytes)) in calldata
    function decodeMintFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // no length check performed, as there is a length check in `toBytes`
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            amount0Max := calldataload(add(params.offset, 0xe0))
            amount1Max := calldataload(add(params.offset, 0x100))
            owner := calldataload(add(params.offset, 0x120))
        }

        hookData = params.toBytes(10);
    }

    /// @dev equivalent to: abi.decode(params, (uint256, uint128, uint128, bytes)) in calldata
    function decodeBurnParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
    {
        // no length check performed, as there is a length check in `toBytes`
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Min := calldataload(add(params.offset, 0x20))
            amount1Min := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.ExactInputParams))
    function decodeSwapExactInParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputParams calldata swapParams)
    {
        // ExactInputParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            // only safety checks for the minimum length, where path and minHopPriceX36 are empty
            // 0xe0 = 7 * 0x20 -> 3 elements, path offset, minHopPriceX36 offset, path length 0, and minHopPriceX36 length 0
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.ExactInputSingleParams))
    function decodeSwapExactInSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputSingleParams calldata swapParams)
    {
        // ExactInputSingleParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            // only safety checks for the minimum length, where hookData is empty
            // 0x160 = 11 * 0x20 -> 9 elements, bytes offset, and bytes length 0
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.ExactOutputParams))
    function decodeSwapExactOutParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputParams calldata swapParams)
    {
        // ExactOutputParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            // only safety checks for the minimum length, where path and minHopPriceX36 are empty
            // 0xe0 = 7 * 0x20 -> 3 elements, path offset, minHopPriceX36 offset, path length 0, and minHopPriceX36 length 0
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.ExactOutputSingleParams))
    function decodeSwapExactOutSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputSingleParams calldata swapParams)
    {
        // ExactOutputSingleParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            // only safety checks for the minimum length, where hookData is empty
            // 0x160 = 11 * 0x20 -> 9 elements, bytes offset, and bytes length 0
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency)) in calldata
    function decodeCurrency(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, Currency)) in calldata
    function decodeCurrencyPair(bytes calldata params) internal pure returns (Currency currency0, Currency currency1) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, Currency, address)) in calldata
    function decodeCurrencyPairAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency0, Currency currency1, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
            _address := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, address)) in calldata
    function decodeCurrencyAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, address, uint256)) in calldata
    function decodeCurrencyAddressAndUint256(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address, uint256 amount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
            amount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, uint256)) in calldata
    function decodeCurrencyAndUint256(bytes calldata params) internal pure returns (Currency currency, uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev equivalent to: abi.decode(params, (uint256)) in calldata
    function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            amount := calldataload(params.offset)
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, uint256, bool)) in calldata
    function decodeCurrencyUint256AndBool(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, bool boolean)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
            boolean := calldataload(add(params.offset, 0x40))
        }
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as `bytes`
    /// @param _bytes The input bytes string to extract a bytes string from
    /// @param _arg The index of the argument to extract
    function toBytes(bytes calldata _bytes, uint256 _arg) internal pure returns (bytes calldata res) {
        uint256 length;
        assembly ("memory-safe") {
            // The offset of the `_arg`-th element is `32 * arg`, which stores the offset of the length pointer.
            // shl(5, x) is equivalent to mul(32, x)
            let lengthPtr :=
                add(_bytes.offset, and(calldataload(add(_bytes.offset, shl(5, _arg))), OFFSET_OR_LENGTH_MASK))
            // the number of bytes in the bytes string
            length := and(calldataload(lengthPtr), OFFSET_OR_LENGTH_MASK)
            // the offset where the bytes string begins
            let offset := add(lengthPtr, 0x20)
            // assign the return parameters
            res.length := length
            res.offset := offset

            // if the provided bytes string isnt as long as the encoding says, revert
            if lt(add(_bytes.length, _bytes.offset), add(length, offset)) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }
}

```

### src/v1/vendor/v4-router/libraries/Actions.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Library to define different pool actions.
/// @dev These are suggested common commands, however additional commands should be defined as required
/// Some of these actions are not supported in the Router contracts or Position Manager contracts, but are left as they may be helpful commands for other peripheral contracts.
library Actions {
    // pool actions
    // liquidity actions
    uint256 internal constant INCREASE_LIQUIDITY = 0x00;
    uint256 internal constant DECREASE_LIQUIDITY = 0x01;
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant BURN_POSITION = 0x03;

    /// @notice DEPRECATED: Vulnerable to sandwich attacks - do not use.
    /// @dev The delta-based approach lacks minimum liquidity slippage protection, allowing
    /// attackers to manipulate the price and reduce the liquidity received.
    /// Use INCREASE_LIQUIDITY instead.
    uint256 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;

    /// @notice DEPRECATED: Vulnerable to sandwich attacks - do not use.
    /// @dev The delta-based approach lacks minimum liquidity slippage protection, allowing
    /// attackers to manipulate the price and reduce the liquidity received.
    /// Use MINT_POSITION instead.
    uint256 internal constant MINT_POSITION_FROM_DELTAS = 0x05;

    // swapping
    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_IN = 0x07;
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SWAP_EXACT_OUT = 0x09;

    // donate
    // note this is not supported in the position manager or router
    uint256 internal constant DONATE = 0x0a;

    // closing deltas on the pool manager
    // settling
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    // taking
    uint256 internal constant TAKE = 0x0e;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant TAKE_PORTION = 0x10;
    uint256 internal constant TAKE_PAIR = 0x11;

    uint256 internal constant CLOSE_CURRENCY = 0x12;
    uint256 internal constant CLEAR_OR_TAKE = 0x13;
    uint256 internal constant SWEEP = 0x14;

    uint256 internal constant WRAP = 0x15;
    uint256 internal constant UNWRAP = 0x16;

    // minting/burning 6909s to close deltas
    // note this is not supported in the position manager or router
    uint256 internal constant MINT_6909 = 0x17;
    uint256 internal constant BURN_6909 = 0x18;

    // permissioned-pools specific actions
    // burns this contract's 6909 claim for a currency and takes the underlying to a recipient
    uint256 internal constant UNWIND_WITH_FALLBACK = 0x19;
}

```

### src/v1/vendor/v4-router/libraries/ActionConstants.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Action Constants
/// @notice Common constants used in actions
/// @dev Constants are gas efficient alternatives to their literal values
library ActionConstants {
    /// @notice used to signal that an action should use the input value of the open delta on the pool manager
    /// or of the balance that the contract holds
    uint128 internal constant OPEN_DELTA = 0;
    /// @notice used to signal that an action should use the contract's entire balance of a currency
    /// This value is equivalent to 1<<255, i.e. a singular 1 in the most significant bit.
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice used to signal that the recipient of an action should be the msgSender
    address internal constant MSG_SENDER = address(1);

    /// @notice used to signal that the recipient of an action should be the address(this)
    address internal constant ADDRESS_THIS = address(2);
}

```

### src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol

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

### src/v1/adapters/ERC8056DirectLegalShareAdapter.sol

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

### script/DeployCoreV1.s.sol

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
    /// @dev Reverts when the chain, external contracts, or governance links are invalid.
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
        /// @dev Fixed governance root storing identities and the global upgrade switch.
        TSVGovernanceAnchor anchor;
        /// @dev Participant SBT used by the Registry for credential checks.
        address sbt;
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
        d.implementations.router = address(new TSVSwapRouterV1(input.poolManager, address(d.registry)));
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
        console2.log("PermissionedValidationLibrary", d.registry.permissionedValidationLibrary());
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
            "Governance must bind Anchor proxies, Registry/Ledger, then bindPermissionedComponents(realFactory, router), configure SBT and grant roles. Production swapping requires reviewed W/U/Q permissions and external Wrapped liquidity readiness."
        );
    }

    /// @dev Loads addresses, SBT identity and trade-day offset from environment variables.
    /// @return input Deployment configuration read from the environment.
    function _loadInput() internal view returns (Input memory input) {
        input.poolManager = _envAddress("TSV_POOL_MANAGER");
        input.anchor = TSVGovernanceAnchor(_envAddress("TSV_GOVERNANCE_ANCHOR"));
        input.sbt = _envAddress("TSV_SBT");
        input.sbtTokenId = _envUint("TSV_SBT_TOKEN_ID");
        uint256 offset = _envUint("TSV_DAY_START_OFFSET_SECONDS");
        if (offset >= 86_400) revert InvalidDeploymentInput();
        input.dayStartOffset = uint32(offset);
    }

    /// @dev Verifies chain, external contract code and the pre-bound governance relationships before broadcasting.
    /// @param input Deployment configuration to validate.
    function _checkInput(Input memory input) internal view {
        if (
            block.chainid != _envUint("TSV_CHAIN_ID") || input.poolManager.code.length == 0
                || input.sbt.code.length == 0 || address(input.anchor).code.length == 0 || input.anchor.proxiesBound()
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

### script/VerifyDeploymentV1.s.sol

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
    /// @dev Reverts when a deployment address or governance link does not match the manifest.
    error VerificationFailed();

    /// @notice Verifies governance bindings, proxy links and implementation addresses.
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
        console2.log("TSV governance, six proxy links and implementation addresses verified.");
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

    /// @dev Checks cross-contract links, external contract code, SBT configuration and Hook permission bits.
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
        address factory = _envAddress("TSV_PERMISSIONS_ADAPTER_FACTORY");
        address validationLibrary = _envAddress("TSV_PERMISSIONED_VALIDATION_LIBRARY");
        if (
            poolManager.code.length == 0 || sbt.code.length == 0 || factory.code.length == 0
                || validationLibrary.code.length == 0 || registry.permissionedValidationLibrary() != validationLibrary
                || router.permissionedValidationLibrary() != validationLibrary
                || registry.permissionsAdapterFactory() != factory || registry.POOL_MANAGER() != poolManager
                || registry.permissionedPoolManager() != poolManager || registry.permissionedRouter() != a[4]
                || registry.permissionedAllowlistChecker() != a[0]
                || address(router.PERMISSIONS_ADAPTER_FACTORY()) != a[0] || address(registry.participantSbt()) != sbt
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

    /// @dev Compares each proxy's implementation address with the deployment manifest.
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
            if (expected[i].code.length == 0 || TSVERC1967Proxy(payable(a[i])).tsvImplementation() != expected[i]) {
                revert VerificationFailed();
            }
        }
    }
}

```
