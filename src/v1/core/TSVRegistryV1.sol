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

interface IERC20DecimalsV1 {
    function decimals() external view returns (uint8);
}

interface ISmartWalletSbtV1 {
    function verify(address user, uint256 tokenId) external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice Single TSV venue asset, security, pool and pause registry.
contract TSVRegistryV1 is TSVGoverned {
    using PoolIdLibrary for PoolKey;

    error InvalidConfig();
    error InvalidStatus();
    error InvalidPool();
    error SbtNotConfigured();
    error Paused(uint8 scope, bytes32 target);

    struct TierPolicy {
        uint16 tierBps;
        uint32 maxListed;
        uint32 listedCount;
    }

    struct EmergencyPause {
        PauseScope scope;
        bytes32 target;
        bytes32 reasonCode;
        bytes32 sourceHash;
        address openedBy;
        uint64 openedAt;
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

    event ComponentsBound(address indexed hook, address indexed lpManager, address indexed dataInbox);
    event SecurityListed(bytes32 indexed securityId, bytes32 symbolHash, uint8 tierId, bytes32 evidenceHash);
    event SecurityDelisted(bytes32 indexed securityId, bytes32 evidenceHash);
    event SecurityTierChanged(bytes32 indexed securityId, uint8 oldTierId, uint8 newTierId, bytes32 evidenceHash);
    event TierPolicyChanged(uint8 indexed tierId, uint16 tierBps, uint32 maxListed, bytes32 evidenceHash);
    event TokenRegistered(address indexed poolCurrency, bytes32 indexed securityId, bytes32 evidenceHash);
    event TokenStatusChanged(address indexed poolCurrency, uint8 oldStatus, uint8 newStatus, bytes32 evidenceHash);
    event LegalShareAdapterChanged(
        address indexed poolCurrency,
        address oldAdapter,
        address newAdapter,
        uint32 legalAdapterVersion,
        bytes32 evidenceHash
    );
    event PoolInitialized(
        bytes32 indexed poolId, uint160 sqrtPriceX96, address indexed creator, bytes32 priceBasisHash
    );
    event PoolStatusChanged(bytes32 indexed poolId, uint8 oldStatus, uint8 newStatus, bytes32 evidenceHash);
    event MarketStatusChanged(
        bytes32 indexed securityId, uint8 oldStatus, uint8 newStatus, uint64 sequence, bytes32 indexed reportId
    );
    event EmergencyPauseOpened(uint256 indexed recordId, uint8 scope, bytes32 indexed target, bytes32 reasonCode);
    event EmergencyPauseClosed(uint256 indexed recordId, bytes32 reasonCode);
    event SbtConfigChanged(
        address indexed oldSbt, address indexed newSbt, uint256 oldTokenId, uint256 newTokenId, bytes32 evidenceHash
    );

    function initialize(address authority, address timelock, address controller) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        nextPauseId = 1;
    }

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

    function setTierPolicy(uint8 tierId, uint16 tierBps, uint32 maxListed, bytes32 evidenceHash) external onlyGovernor {
        TierPolicy storage tier = tiers[tierId];
        if (tierId == 0 || tierBps == 0 || tierBps > 10_000 || maxListed < tier.listedCount || evidenceHash == 0) {
            revert InvalidConfig();
        }
        tier.tierBps = tierBps;
        tier.maxListed = maxListed;
        emit TierPolicyChanged(tierId, tierBps, maxListed, evidenceHash);
    }

    function tierPolicy(uint8 tierId) external view returns (TierPolicy memory) {
        return tiers[tierId];
    }

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

    function hasCredential(address owner) public view returns (bool) {
        if (address(participantSbt) == address(0)) revert SbtNotConfigured();
        return participantSbt.verify(owner, sbtTokenId);
    }

    function isEligible(address owner) external view returns (bool) {
        if (address(participantSbt) == address(0)) revert SbtNotConfigured();
        return !participantSbt.paused() && hasCredential(owner);
    }

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

    function relistSecurity(bytes32 securityId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (config.securityId == 0 || config.listed || evidenceHash == 0) revert InvalidStatus();
        _takeTierSlot(config.tierId);
        config.listed = true;
        config.version++;
        emit SecurityListed(securityId, config.symbolHash, config.tierId, evidenceHash);
    }

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

    function delistSecurity(bytes32 securityId, bytes32 evidenceHash) external onlyRole(SYMBOL_ADMIN_ROLE) {
        SecurityConfig storage config = securities[securityId];
        if (!config.listed || config.activePoolCount != 0 || evidenceHash == 0) revert InvalidStatus();
        config.listed = false;
        config.version++;
        tiers[config.tierId].listedCount--;
        emit SecurityDelisted(securityId, evidenceHash);
    }

    function getSecurity(bytes32 securityId) external view returns (SecurityConfig memory) {
        return securities[securityId];
    }

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

    function getToken(address currency) external view returns (TokenConfig memory) {
        return tokens[currency];
    }

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

    function getPool(bytes32 poolId) external view returns (PoolConfig memory) {
        return pools[poolId];
    }

    function isKnownPool(bytes32 poolId) external view returns (bool) {
        return pools[poolId].status != PoolStatus.ABSENT;
    }

    function marketStatus(bytes32 securityId) external view returns (MarketStatus) {
        return marketStatuses[securityId];
    }

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

    function clearEmergencyPause(uint256 recordId, bytes32 reasonCode) external onlyRole(EMERGENCY_RESUMER_ROLE) {
        EmergencyPause storage record = emergencyPauses[recordId];
        if (!record.active || reasonCode == 0) revert InvalidStatus();
        record.active = false;
        activePauseCount[uint8(record.scope)][record.target]--;
        emit EmergencyPauseClosed(recordId, reasonCode);
    }

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

    function _takeTierSlot(uint8 tierId) private {
        TierPolicy storage tier = tiers[tierId];
        if (tierId == 0 || tier.tierBps == 0 || tier.listedCount >= tier.maxListed) revert InvalidConfig();
        tier.listedCount++;
    }

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

    function _assetPausedForReplacement(address currency) private view returns (bool) {
        return activePoolCountByCurrency[currency] == 0 || _isPaused(PauseScope.GLOBAL, 0)
            || _isPaused(PauseScope.TOKEN, _addressKey(currency));
    }

    function _isPaused(PauseScope scope, bytes32 target) private view returns (bool) {
        return activePauseCount[uint8(scope)][target] != 0;
    }

    function _addressKey(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
