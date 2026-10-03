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
    /// @param authority Business authority used by the governed base contract.
    /// @param timelock Upgrade timelock used by the governed base contract.
    /// @param controller Emergency upgrade controller used by the governed base contract.
    /// @param poolManager_ V4 PoolManager that stores all TSV positions.
    /// @param registry_ Registry used for SBT and pool-status checks.
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
