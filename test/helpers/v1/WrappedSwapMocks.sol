// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPHookContext, LPOperationMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";

/// @dev Behavior fixture for issuer U and quote Q; never deployed as a production asset.
contract V1SwapToken is ERC20 {
    address public immutable asset;
    uint8 private precision;
    uint8 public metadataMode;
    uint8 public transferMode;
    address public blockedRecipient;
    address public feeSender;
    uint16 public senderFeeBps;
    address public callbackTarget;
    bytes public callbackData;
    bool private inCallback;

    constructor(string memory name_, uint8 precision_, address asset_) ERC20(name_, name_) {
        precision = precision_;
        asset = asset_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDecimals(uint8 value) external {
        precision = value;
    }

    function setMetadataMode(uint8 mode) external {
        metadataMode = mode;
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setSenderFee(address sender, uint16 bps) external {
        feeSender = sender;
        senderFeeBps = bps;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function decimals() public view override returns (uint8) {
        if (metadataMode == 1) revert("metadata read failed");
        if (metadataMode == 2) assembly ("memory-safe") { return(0, 1) }
        return precision;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly ("memory-safe") { return(0, 0) }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly ("memory-safe") { return(0, 0) }
        return true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to == address(0) || to != blockedRecipient, "issuer refused recipient");
        super._update(from, to, amount);
        if (from == address(0) || to == address(0)) return;
        if (transferMode == 1) super._update(to, address(0), amount / 100);
        if (from == feeSender && senderFeeBps != 0) super._update(from, address(this), amount * senderFeeBps / 10_000);
        if (callbackTarget != address(0) && !inCallback) {
            inCallback = true;
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            inCallback = false;
        }
    }
}

/// @dev Test-only seed component. Exercises actual Hook admission/context and real W/PM settlement.
///      Its W wrapper authorization and liquidity entry are not production LP deliverables.
contract V1WrappedLiquiditySeed {
    using PoolIdLibrary for PoolKey;
    IPoolManager public immutable poolManager;
    TSVRegistryV1 public immutable registry;
    address public immutable admin;
    LPHookContext private context;

    constructor(IPoolManager pm, TSVRegistryV1 r) {
        poolManager = pm;
        registry = r;
        admin = msg.sender;
    }

    function initializePool(PoolKey calldata key, uint160 price) external {
        require(msg.sender == admin);
        registry.registerPool(key);
        poolManager.initialize(key, price);
    }

    function seed(PoolKey calldata key, int24 lower, int24 upper, uint128 liquidity) external {
        require(msg.sender == admin);
        context = LPHookContext(
            PoolId.unwrap(key.toId()),
            lower,
            upper,
            LPOperationMode.OPEN,
            bytes32(uint256(1)),
            int256(uint256(liquidity))
        );
        poolManager.unlock(abi.encode(key));
        delete context;
    }

    function activeLPContext() external view returns (LPHookContext memory) {
        return context;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager) && context.poolId != 0);
        PoolKey memory key = abi.decode(data, (PoolKey));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                context.tickLower, context.tickUpper, context.liquidityDelta, context.salt
            ),
            bytes("")
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return bytes("");
    }

    function _settle(Currency c, int128 delta) private {
        require(delta < 0);
        uint256 amount = uint256(-int256(delta));
        poolManager.sync(c);
        address u = registry.getCurrencyUnderlying(Currency.unwrap(c));
        if (u == address(0)) {
            TSVPermissionedSettlementLib.transferExact(Currency.unwrap(c), admin, address(poolManager), amount);
        } else {
            TSVPermissionedSettlementLib.payStock(Currency.unwrap(c), u, admin, amount);
        }
        require(poolManager.settle() == amount);
    }
}
