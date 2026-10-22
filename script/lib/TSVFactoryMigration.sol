// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionsAdapter} from "tsv-v1/vendor/permissionedPools/PermissionsAdapter.sol";
import {IERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";

/// @notice New factory that preserves the original factory's adapter provenance.
/// @dev The fallback is live, not a snapshot. The original factory must remain available.
contract TSVCompatiblePermissionsAdapterFactory is IPermissionsAdapterFactory {
    IPermissionsAdapterFactory public immutable LEGACY_FACTORY;
    address public immutable POOL_MANAGER;
    mapping(address => address) private localAdapters;
    mapping(address => address) private localVerified;

    constructor(address legacy) {
        require(legacy.code.length != 0, "legacy factory has no code");
        LEGACY_FACTORY = IPermissionsAdapterFactory(legacy);
        POOL_MANAGER = LEGACY_FACTORY.POOL_MANAGER();
        require(POOL_MANAGER.code.length != 0, "PoolManager has no code");
    }

    function permissionsAdapterOf(address adapter) public view returns (address) {
        address underlying = localAdapters[adapter];
        return underlying == address(0) ? LEGACY_FACTORY.permissionsAdapterOf(adapter) : underlying;
    }

    function verifiedPermissionsAdapterOf(address adapter) public view returns (address) {
        if (localAdapters[adapter] != address(0)) return localVerified[adapter];
        return LEGACY_FACTORY.verifiedPermissionsAdapterOf(adapter);
    }

    function createPermissionsAdapter(IERC20 token, address owner, IAllowlistChecker checker)
        external
        returns (address adapter)
    {
        require(address(token).code.length != 0, "token has no code");
        adapter = address(new PermissionsAdapter(token, POOL_MANAGER, owner, checker));
        localAdapters[adapter] = address(token);
        emit PermissionsAdapterCreated(adapter, address(token));
    }

    function verifyPermissionsAdapter(address adapter) external {
        address underlying = localAdapters[adapter];
        if (underlying == address(0)) {
            // The legacy contract emits its own event; do not duplicate it here.
            LEGACY_FACTORY.verifyPermissionsAdapter(adapter);
            return;
        }
        if (localVerified[adapter] != address(0)) revert PermissionsAdapterAlreadyVerified(adapter);
        if (IERC20(underlying).balanceOf(adapter) == 0) revert PermissionsAdapterNotVerified(adapter);
        localVerified[adapter] = underlying;
        emit PermissionsAdapterVerified(adapter, underlying);
    }
}

/// @notice Registry implementation with a fixed, one-way factory migration; no new storage slots.
contract TSVRegistryFactoryMigration is TSVRegistryV1 {
    address public immutable EXPECTED_FACTORY;
    address public immutable NEXT_FACTORY;
    event PermissionsFactoryMigrated(address indexed previous, address indexed current);

    constructor(address previous, address next) {
        require(previous != next, "same factory");
        require(address(TSVCompatiblePermissionsAdapterFactory(next).LEGACY_FACTORY()) == previous, "wrong legacy");
        EXPECTED_FACTORY = previous;
        NEXT_FACTORY = next;
    }

    function migratePermissionsFactory() external onlyProxy onlyRole(UPGRADE_ADMIN_ROLE) {
        require(!this.isPaused(), "Registry paused");
        require(permissionsAdapterFactory == EXPECTED_FACTORY, "factory changed/already migrated");
        require(IPermissionsAdapterFactory(NEXT_FACTORY).POOL_MANAGER() == permissionedPoolManager, "wrong PoolManager");
        permissionsAdapterFactory = NEXT_FACTORY;
        emit PermissionsFactoryMigrated(EXPECTED_FACTORY, NEXT_FACTORY);
    }
}

/// @notice Temporary router implementation accepted by the old immutable-dependency guard.
/// @dev Installed and removed inside one coordinator transaction; adds no storage variables.
contract TSVRouterFactoryBridge is TSVSwapRouterV1 {
    address public immutable TARGET_IMPLEMENTATION;
    address public immutable EXPECTED_REGISTRY;
    bytes32 public immutable TARGET_CODE_HASH;

    constructor(address pm, address previousFactory, address target, address registry_)
        TSVSwapRouterV1(pm, previousFactory)
    {
        require(target.code.length != 0, "target has no code");
        require(address(TSVSwapRouterV1(target).poolManager()) == pm, "wrong PoolManager");
        address next = address(TSVSwapRouterV1(target).PERMISSIONS_ADAPTER_FACTORY());
        require(
            address(TSVCompatiblePermissionsAdapterFactory(next).LEGACY_FACTORY()) == previousFactory, "wrong legacy"
        );
        TARGET_IMPLEMENTATION = target;
        EXPECTED_REGISTRY = registry_;
        TARGET_CODE_HASH = target.codehash;
    }

    function completeFactoryMigration() external onlyProxy {
        require(address(registry) == EXPECTED_REGISTRY, "wrong Registry");
        require(!registry.isPaused(), "Registry paused");
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
        if (_getLocker() != address(0)) revert ContractLocked();
        require(TARGET_IMPLEMENTATION.codehash == TARGET_CODE_HASH, "target code changed");
        require(
            registry.permissionsAdapterFactory()
                == address(TSVSwapRouterV1(TARGET_IMPLEMENTATION).PERMISSIONS_ADAPTER_FACTORY()),
            "Registry not migrated"
        );
        // This deliberately bypasses the old equality guard, for this fixed target only.
        // The final standard router restores its immutable-dependency equality guard.
        ERC1967Utils.upgradeToAndCall(TARGET_IMPLEMENTATION, "");
    }
}

interface IFactoryMigrationUUPS {
    function upgradeToAndCall(address next, bytes calldata data) external payable;
}

/// @notice All five proxy upgrades are atomic. This contract has no arbitrary-call interface.
contract TSVFactoryMigrationCoordinator {
    // Component order everywhere: Registry, Ledger, Router, LP Manager, Hook.
    struct Plan {
        uint256 chainId;
        uint256 deadline;
        address operator;
        address poolManager;
        address oldFactory;
        address newFactory;
        address bridge;
        address[5] proxies;
        address[5] beforeImpl;
        address[5] afterImpl;
        bytes32[5] beforeCodeHash;
    }

    Plan private plan;
    bytes32[5] private afterCodeHash;
    bytes32 private immutable bridgeCodeHash;
    bytes32 private immutable factoryCodeHash;
    address private immutable originalSbt;
    bool public executed;
    bytes32 public immutable PLAN_HASH;
    event FactoryMigrationCompleted(bytes32 indexed planHash, address indexed oldFactory, address indexed newFactory);

    constructor(Plan memory p) {
        require(p.operator != address(0) && p.chainId == block.chainid, "invalid operator/chain");
        require(p.deadline > block.timestamp, "expired plan");
        plan = p;
        PLAN_HASH = keccak256(abi.encode(p));
        originalSbt = TSVRegistryV1(p.proxies[0]).participantSbt();
        for (uint256 i; i < 5; ++i) {
            require(
                p.afterImpl[i].code.length != 0 && p.afterImpl[i].code.length <= 24_576, "invalid implementation size"
            );
            afterCodeHash[i] = p.afterImpl[i].codehash;
        }
        require(p.bridge.code.length != 0 && p.bridge.code.length <= 24_576, "invalid bridge size");
        bridgeCodeHash = p.bridge.codehash;
        factoryCodeHash = p.newFactory.codehash;
        verifyPrepared();
    }

    function getPlan() external view returns (Plan memory) {
        return plan;
    }

    function verifyPrepared() public view {
        Plan memory p = plan;
        require(!executed && block.chainid == p.chainId, "executed/wrong chain");
        require(block.timestamp <= p.deadline, "expired plan");
        _verifyImplementations(false);
        _verifyBindings(p.oldFactory);
        _verifyTargets();
        TSVLPManagerV1 oldLP = TSVLPManagerV1(payable(p.proxies[3]));
        TSVLPManagerV1 nextLP = TSVLPManagerV1(payable(p.afterImpl[3]));
        require(
            address(oldLP.permit2()) == address(nextLP.permit2())
                && oldLP.unsubscribeGasLimit() == nextLP.unsubscribeGasLimit()
                && address(oldLP.tokenDescriptor()) == address(nextLP.tokenDescriptor())
                && address(oldLP.WETH9()) == address(nextLP.WETH9())
                && oldLP.DELIVERY_GAS_LIMIT() == nextLP.DELIVERY_GAS_LIMIT(),
            "LP immutable drift"
        );
    }

    function execute() external {
        require(msg.sender == plan.operator, "only operator");
        verifyPrepared();
        Plan memory p = plan;
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(this)), "coordinator lacks upgrade role");
        executed = true;
        IFactoryMigrationUUPS(p.proxies[0])
            .upgradeToAndCall(p.afterImpl[0], abi.encodeCall(TSVRegistryFactoryMigration.migratePermissionsFactory, ()));
        IFactoryMigrationUUPS(p.proxies[2]).upgradeToAndCall(p.bridge, "");
        TSVRouterFactoryBridge(p.proxies[2]).completeFactoryMigration();
        IFactoryMigrationUUPS(p.proxies[3]).upgradeToAndCall(p.afterImpl[3], "");
        IFactoryMigrationUUPS(p.proxies[1]).upgradeToAndCall(p.afterImpl[1], "");
        IFactoryMigrationUUPS(p.proxies[4]).upgradeToAndCall(p.afterImpl[4], "");
        r.renounceRole(r.UPGRADE_ADMIN_ROLE(), address(this));
        verifyCompleted();
        emit FactoryMigrationCompleted(PLAN_HASH, p.oldFactory, p.newFactory);
    }

    function verifyCompleted() public view {
        require(executed && block.chainid == plan.chainId, "not executed/wrong chain");
        _verifyTargets();
        _verifyImplementations(true);
        _verifyBindings(plan.newFactory);
        TSVRegistryV1 r = TSVRegistryV1(plan.proxies[0]);
        require(!r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(this)), "upgrade role remains");
    }

    function _verifyImplementations(bool after_) private view {
        for (uint256 i; i < 5; ++i) {
            address expected = after_ ? plan.afterImpl[i] : plan.beforeImpl[i];
            require(TSVERC1967Proxy(payable(plan.proxies[i])).tsvImplementation() == expected, "implementation drift");
            require(
                expected.codehash == (after_ ? afterCodeHash[i] : plan.beforeCodeHash[i]), "implementation code drift"
            );
        }
    }

    function _verifyTargets() private view {
        Plan memory p = plan;
        require(p.newFactory.codehash == factoryCodeHash && p.bridge.codehash == bridgeCodeHash, "migration code drift");
        for (uint256 i; i < 5; ++i) {
            require(p.afterImpl[i].codehash == afterCodeHash[i], "target code drift");
        }
        require(
            address(TSVCompatiblePermissionsAdapterFactory(p.newFactory).LEGACY_FACTORY()) == p.oldFactory,
            "wrong legacy"
        );
        require(IPermissionsAdapterFactory(p.newFactory).POOL_MANAGER() == p.poolManager, "wrong new PoolManager");
        TSVRegistryFactoryMigration nextR = TSVRegistryFactoryMigration(p.afterImpl[0]);
        require(
            nextR.EXPECTED_FACTORY() == p.oldFactory && nextR.NEXT_FACTORY() == p.newFactory, "wrong Registry migration"
        );
        TSVRouterFactoryBridge bridge = TSVRouterFactoryBridge(p.bridge);
        require(
            bridge.TARGET_IMPLEMENTATION() == p.afterImpl[2] && bridge.EXPECTED_REGISTRY() == p.proxies[0],
            "wrong bridge"
        );
        _verifyPeriphery(p.bridge, p.afterImpl[3], p.oldFactory, p.newFactory);
        _verifyPeriphery(p.afterImpl[2], p.afterImpl[3], p.newFactory, p.newFactory);
    }

    function _verifyPeriphery(address router_, address lp_, address routerFactory, address lpFactory) private view {
        TSVSwapRouterV1 router = TSVSwapRouterV1(router_);
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(lp_));
        require(
            address(router.poolManager()) == plan.poolManager && address(lp.poolManager()) == plan.poolManager,
            "PoolManager drift"
        );
        require(address(router.PERMISSIONS_ADAPTER_FACTORY()) == routerFactory, "Router factory drift");
        require(address(lp.PERMISSIONS_ADAPTER_FACTORY()) == lpFactory, "LP factory drift");
        require(address(lp.registry()) == plan.proxies[0], "LP Registry drift");
    }

    function _verifyBindings(address factory) private view {
        Plan memory p = plan;
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        TSVHookV1 h = TSVHookV1(p.proxies[4]);
        require(!r.isPaused(), "Registry paused");
        require(
            r.permissionsAdapterFactory() == factory && r.permissionedPoolManager() == p.poolManager,
            "Registry factory drift"
        );
        require(
            r.hook() == p.proxies[4] && r.lpManager() == p.proxies[3] && r.participantSbt() == originalSbt,
            "Registry binding drift"
        );
        require(
            address(h.registry()) == p.proxies[0] && address(h.poolManager()) == p.poolManager, "Hook binding drift"
        );
        require(
            h.router() == p.proxies[2] && h.lpManager() == p.proxies[3] && address(h.ledger()) == p.proxies[1],
            "Hook components drift"
        );
        require(address(TSVVolumeLedgerV1(p.proxies[1]).registry()) == p.proxies[0], "Ledger Registry drift");
        require(address(TSVSwapRouterV1(p.proxies[2]).registry()) == p.proxies[0], "Router Registry drift");
        _verifyPeriphery(p.proxies[2], p.proxies[3], factory, factory);
    }
}
