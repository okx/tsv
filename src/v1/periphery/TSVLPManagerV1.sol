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
import {
    TokenConfig,
    AssetBounds,
    SettlementMode,
    LPBounds,
    LPContext,
    LPOperationMode
} from "tsv-v1/types/TSVTypes.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";

/// @notice The sole V4 position owner for TSV LPs; each position has a unique V4 salt.
contract TSVLPManagerV1 is TSVGoverned, ERC721Upgradeable {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error Unauthorized();
    error InvalidPosition();
    error InvalidPool();
    error Expired();
    error NoFees();
    error SlippageExceeded();
    error SettlementMismatch();
    error Reentrancy();
    error NonTransferable();

    struct Position {
        address owner;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint128 liquidity;
        bool active;
    }

    struct ModifyRequest {
        bytes32 operationId;
        uint256 positionId;
        LPOperationMode mode;
        int256 liquidityDelta;
        LPBounds bounds;
    }

    IPoolManager public poolManager;
    TSVRegistryV1 public registry;
    uint256 public nextPositionId;
    uint256 public nextOperationNonce;
    mapping(uint256 => Position) private positions;
    LPContext private activeContext;
    bytes32 private activeOperationId;
    bytes32 private activeRequestHash;
    bool private entered;

    event PositionOpened(uint256 indexed positionId, address indexed owner, bytes32 indexed poolId, uint128 liquidity);
    event PositionChanged(uint256 indexed positionId, uint128 oldLiquidity, uint128 newLiquidity);
    event FeesCollected(uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event PositionClosed(uint256 indexed positionId, address indexed owner, bool forced, bytes32 reasonCode);

    function initialize(
        address authority,
        address timelock,
        address controller,
        address poolManager_,
        address registry_
    ) external initializer {
        __TSVGoverned_init(authority, timelock, controller);
        __ERC721_init("TSV LP Receipt", "TSVLP");
        if (poolManager_.code.length == 0 || registry_.code.length == 0) revert InvalidPool();
        poolManager = IPoolManager(poolManager_);
        registry = TSVRegistryV1(registry_);
        nextPositionId = 1;
        nextOperationNonce = 1;
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

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

    function openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        LPBounds calldata bounds
    ) external nonReentrant returns (uint256 positionId) {
        _requireUserPool(PoolId.unwrap(key.toId()), bounds.deadline);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidPosition();
        _validateTicks(key, tickLower, tickUpper);
        positionId = nextPositionId++;
        positions[positionId] = Position(
            msg.sender,
            key,
            tickLower,
            tickUpper,
            keccak256(abi.encode(block.chainid, address(this), positionId)),
            0,
            true
        );
        _modify(positionId, LPOperationMode.OPEN, int256(uint256(liquidity)), bounds);
        positions[positionId].liquidity = liquidity;
        _mint(msg.sender, positionId);
        emit PositionOpened(positionId, msg.sender, PoolId.unwrap(key.toId()), liquidity);
    }

    function increaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external nonReentrant {
        Position storage p = _requireOwner(positionId, bounds.deadline);
        if (
            liquidity == 0 || liquidity > uint128(type(int128).max)
                || uint256(p.liquidity) + liquidity > uint256(uint128(type(int128).max))
        ) {
            revert InvalidPosition();
        }
        uint128 old = p.liquidity;
        _modify(positionId, LPOperationMode.INCREASE, int256(uint256(liquidity)), bounds);
        p.liquidity = old + liquidity;
        emit PositionChanged(positionId, old, p.liquidity);
    }

    function decreaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external nonReentrant {
        Position storage p = _requireOwner(positionId, bounds.deadline);
        if (liquidity == 0 || liquidity >= p.liquidity) revert InvalidPosition();
        uint128 old = p.liquidity;
        _modify(positionId, LPOperationMode.DECREASE, -int256(uint256(liquidity)), bounds);
        p.liquidity = old - liquidity;
        emit PositionChanged(positionId, old, p.liquidity);
    }

    function collectFees(uint256 positionId, LPBounds calldata bounds) external nonReentrant {
        Position storage p = _requireOwner(positionId, bounds.deadline);
        if (p.liquidity == 0) revert InvalidPosition();
        BalanceDelta delta = _modify(positionId, LPOperationMode.COLLECT, 0, bounds);
        if (delta.amount0() <= 0 && delta.amount1() <= 0) revert NoFees();
        emit FeesCollected(positionId, _positive(delta.amount0()), _positive(delta.amount1()));
    }

    function closePosition(uint256 positionId, LPBounds calldata bounds) external nonReentrant {
        Position storage p = _requireOwner(positionId, bounds.deadline);
        _modify(positionId, LPOperationMode.CLOSE, -int256(uint256(p.liquidity)), bounds);
        _close(positionId, p, false, 0);
    }

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
        BalanceDelta delta = _modify(positionId, LPOperationMode.FORCE_EXIT, -int256(uint256(p.liquidity)), bounds);
        if (delta.amount0() < 0 || delta.amount1() < 0) revert SettlementMismatch();
        _close(positionId, p, true, reasonCode);
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function activeLPContext(bytes32 operationId) external view returns (LPContext memory) {
        if (operationId != activeOperationId || operationId == 0) revert InvalidPosition();
        return activeContext;
    }

    function activeAssetOperation(bytes32 operationId, address currency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit_)
    {
        if (operationId != activeOperationId || operationId == 0) return (0, address(0), address(0), false);
        Position storage p = positions[activeContext.positionId];
        if (currency != Currency.unwrap(p.key.currency0) && currency != Currency.unwrap(p.key.currency1)) {
            return (0, address(0), address(0), false);
        }
        return (activeContext.poolId, p.owner, p.owner, activeContext.mode == LPOperationMode.FORCE_EXIT);
    }

    function approve(address, uint256) public pure override {
        revert NonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override {
        revert NonTransferable();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert NonTransferable();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || activeOperationId == 0 || keccak256(data) != activeRequestHash) {
            revert Unauthorized();
        }
        ModifyRequest memory request = abi.decode(data, (ModifyRequest));
        if (request.operationId != activeOperationId || block.timestamp > request.bounds.deadline) {
            revert InvalidPosition();
        }
        Position storage p = positions[request.positionId];
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(p.tickLower, p.tickUpper, request.liquidityDelta, p.salt);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(p.key, params, abi.encode(activeOperationId));
        _settle(
            p.key.currency0,
            delta.amount0(),
            request.bounds.maxPoolIn0,
            request.bounds.minPoolOut0,
            request.bounds.bounds0,
            p.owner,
            request.mode
        );
        _settle(
            p.key.currency1,
            delta.amount1(),
            request.bounds.maxPoolIn1,
            request.bounds.minPoolOut1,
            request.bounds.bounds1,
            p.owner,
            request.mode
        );
        return abi.encode(delta);
    }

    function _modify(uint256 positionId, LPOperationMode mode, int256 liquidityDelta, LPBounds memory bounds)
        private
        returns (BalanceDelta delta)
    {
        Position storage p = positions[positionId];
        bytes32 operationId =
            keccak256(abi.encode(block.chainid, address(this), nextOperationNonce++, positionId, mode));
        bytes32 poolId = PoolId.unwrap(p.key.toId());
        activeContext = LPContext(poolId, positionId, p.tickLower, p.tickUpper, p.salt, mode, p.owner, liquidityDelta);
        activeOperationId = operationId;
        ModifyRequest memory request = ModifyRequest(operationId, positionId, mode, liquidityDelta, bounds);
        activeRequestHash = keccak256(abi.encode(request));
        bytes memory result = poolManager.unlock(abi.encode(request));
        delta = abi.decode(result, (BalanceDelta));
        delete activeContext;
        delete activeOperationId;
        delete activeRequestHash;
    }

    function _settle(
        Currency currency,
        int128 delta,
        uint256 maxIn,
        uint256 minOut,
        AssetBounds memory bounds,
        address owner,
        LPOperationMode mode
    ) private {
        address token = Currency.unwrap(currency);
        TokenConfig memory config = registry.getToken(token);
        if (config.settlementMode != SettlementMode.DIRECT_ERC20 || config.userToken != token) revert InvalidPool();
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(int256(delta));
        if (delta < 0 && (mode == LPOperationMode.FORCE_EXIT || amount > maxIn)) revert SlippageExceeded();
        if ((delta > 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
        if (
            bounds.maxSharesIn != 0 || bounds.minSharesOut != 0 || bounds.maxDisplayedDebit != 0
                || bounds.minDisplayedCredit != 0
        ) revert SlippageExceeded();
        if (delta < 0) {
            TSVDirectSettlementLib.settleFrom(poolManager, currency, token, owner, amount);
        } else if (delta > 0) {
            TSVDirectSettlementLib.takeTo(poolManager, currency, token, owner, amount);
        }
    }

    function _requireUserPool(bytes32 poolId, uint64 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!registry.isEligible(msg.sender) || !registry.isTradable(poolId)) revert Unauthorized();
    }

    function _requireOwner(uint256 positionId, uint64 deadline) private view returns (Position storage p) {
        p = positions[positionId];
        if (!p.active || p.liquidity == 0 || p.owner != msg.sender || ownerOf(positionId) != p.owner) {
            revert InvalidPosition();
        }
        _requireUserPool(PoolId.unwrap(p.key.toId()), deadline);
    }

    function _validateTicks(PoolKey calldata key, int24 lower, int24 upper) private pure {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % key.tickSpacing != 0
                || upper % key.tickSpacing != 0
        ) revert InvalidPosition();
    }

    function _close(uint256 positionId, Position storage p, bool forced, bytes32 reasonCode) private {
        address owner = p.owner;
        p.liquidity = 0;
        p.active = false;
        _burn(positionId);
        emit PositionClosed(positionId, owner, forced, reasonCode);
    }

    function _positive(int128 value) private pure returns (uint256) {
        return value > 0 ? uint256(int256(value)) : 0;
    }
}
