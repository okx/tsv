// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {
    TSVCompatiblePermissionsAdapterFactory,
    TSVRegistryFactoryMigration,
    TSVRouterFactoryBridge,
    TSVFactoryMigrationCoordinator
} from "./lib/TSVFactoryMigration.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1, IPoolManager, IPermissionsAdapterFactory} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @notice Read docs/TSV_FACTORY_MIGRATION_UPGRADE_GUIDE.md before use.
/// @dev PK is read only by broadcast-capable stages. No stage changes a deployment manifest.
contract UpgradePermissionsFactory is Script {
    /// @notice Capture the selected live topology without deploying or broadcasting anything.
    function snapshot() external {
        require(block.chainid == vm.envUint("TSV_UPGRADE_CHAIN_ID"), "wrong RPC chain");
        string memory path = vm.envString("TSV_UPGRADE_MANIFEST");
        require(!vm.exists(path), "manifest exists; use a fresh path");
        TSVRegistryV1 r = TSVRegistryV1(vm.envAddress("TSV_UPGRADE_REGISTRY"));
        TSVHookV1 h = TSVHookV1(r.hook());
        address[5] memory proxies = [address(r), address(h.ledger()), h.router(), r.lpManager(), address(h)];
        string memory proxyJson;
        string memory implJson;
        string memory hashJson;
        for (uint256 i; i < 5; ++i) {
            address impl = TSVERC1967Proxy(payable(proxies[i])).tsvImplementation();
            require(impl.code.length != 0, "implementation missing");
            proxyJson = vm.serializeAddress("snapshot-proxies", _name(i), proxies[i]);
            implJson = vm.serializeAddress("snapshot-implementations", _name(i), impl);
            hashJson = vm.serializeBytes32("snapshot-hashes", _name(i), impl.codehash);
        }
        string memory result = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"snapshotBlock":',
            vm.toString(block.number),
            ',"deploymentStatus":"confirmed","proxies":',
            proxyJson,
            ',"implementations":',
            implJson,
            ',"implementationCodeHashes":',
            hashJson,
            ',"factories":{"permissionedAdapter":"',
            vm.toString(r.permissionsAdapterFactory()),
            '"},"dependencies":{"poolManager":"',
            vm.toString(r.permissionedPoolManager()),
            '"}}'
        );
        vm.writeJson(result, path);
        console2.log("Read-only chain snapshot written; independently confirm deployed source/storage lineage", path);
    }

    function rehearse() external {
        address operator = vm.envAddress("TSV_UPGRADE_OPERATOR");
        // Deliberately no startBroadcast: even --broadcast cannot publish this rehearsal.
        vm.startPrank(operator);
        TSVFactoryMigrationCoordinator c = _deploy(operator);
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        r.grantRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        c.execute();
        vm.stopPrank();
        c.verifyCompleted();
        console2.log("Full atomic migration rehearsal passed (no broadcast transactions).");
    }

    function prepare() external {
        string memory path = vm.envString("TSV_UPGRADE_PLAN");
        require(!vm.exists(path), "plan file exists; use a fresh path");
        uint256 pk = vm.envUint("PK");
        address operator = vm.envAddress("TSV_UPGRADE_OPERATOR");
        require(vm.addr(pk) == operator, "PK/operator mismatch");
        vm.startBroadcast(pk);
        TSVFactoryMigrationCoordinator c = _deploy(operator);
        vm.stopBroadcast();
        _writePlan(c, path);
        console2.log("Coordinator", address(c));
        console2.log("Plan written; simulated file is NOT evidence of deployment", path);
    }

    function verifyPrepared() external view {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        console2.log("Prepared contracts, old implementations and bindings verified on selected RPC.");
    }

    function authorize() external {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        uint256 pk = vm.envUint("PK");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), vm.addr(pk)), "signer lacks default admin role");
        require(!r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "already authorized; do not resend");
        vm.startBroadcast(pk);
        r.grantRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        vm.stopBroadcast();
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "grant failed");
    }

    function execute() external {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyPrepared();
        uint256 pk = vm.envUint("PK");
        require(vm.addr(pk) == c.getPlan().operator, "signer is not plan operator");
        vm.startBroadcast(pk);
        c.execute();
        vm.stopBroadcast();
        c.verifyCompleted();
    }

    function verifyCompleted() external view {
        TSVFactoryMigrationCoordinator c = _load();
        c.verifyCompleted();
        console2.log("All five implementation slots, new factory bindings and role cleanup verified.");
    }

    function cancelAuthorization() external {
        TSVFactoryMigrationCoordinator c = _load();
        require(!c.executed(), "completed plan already renounced its role");
        TSVRegistryV1 r = TSVRegistryV1(c.getPlan().proxies[0]);
        uint256 pk = vm.envUint("PK");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), vm.addr(pk)), "signer lacks default admin role");
        require(r.hasRole(r.UPGRADE_ADMIN_ROLE(), address(c)), "role absent; nothing to revoke");
        vm.startBroadcast(pk);
        r.revokeRole(r.UPGRADE_ADMIN_ROLE(), address(c));
        vm.stopBroadcast();
    }

    function _deploy(address operator) private returns (TSVFactoryMigrationCoordinator c) {
        string memory j = vm.readFile(vm.envString("TSV_UPGRADE_MANIFEST"));
        TSVFactoryMigrationCoordinator.Plan memory p;
        p.chainId = vm.parseJsonUint(j, ".chainId");
        require(p.chainId == block.chainid, "wrong RPC chain");
        require(
            keccak256(bytes(vm.parseJsonString(j, ".deploymentStatus"))) == keccak256("confirmed"),
            "manifest unconfirmed"
        );
        p.deadline = vm.envUint("TSV_UPGRADE_DEADLINE");
        p.operator = operator;
        p.poolManager = vm.parseJsonAddress(j, ".dependencies.poolManager");
        p.oldFactory = vm.parseJsonAddress(j, ".factories.permissionedAdapter");
        for (uint256 i; i < 5; ++i) {
            string memory component = _name(i);
            p.proxies[i] = vm.parseJsonAddress(j, string.concat(".proxies.", component));
            p.beforeImpl[i] = vm.parseJsonAddress(j, string.concat(".implementations.", component));
            require(
                TSVERC1967Proxy(payable(p.proxies[i])).tsvImplementation() == p.beforeImpl[i],
                "manifest implementation drift"
            );
            p.beforeCodeHash[i] = p.beforeImpl[i].codehash;
            string memory hashPath = string.concat(".implementationCodeHashes.", component);
            if (vm.keyExistsJson(j, hashPath)) {
                require(vm.parseJsonBytes32(j, hashPath) == p.beforeCodeHash[i], "manifest code hash drift");
            }
        }
        TSVRegistryV1 r = TSVRegistryV1(p.proxies[0]);
        require(!r.isPaused(), "Registry paused: cannot migrate");
        require(r.hasRole(r.DEFAULT_ADMIN_ROLE(), operator), "operator lacks default admin role");
        require(r.permissionsAdapterFactory() == p.oldFactory, "manifest factory drift");
        p.newFactory = address(new TSVCompatiblePermissionsAdapterFactory(p.oldFactory));
        p.afterImpl[0] = address(new TSVRegistryFactoryMigration(p.oldFactory, p.newFactory));
        p.afterImpl[1] = address(new TSVVolumeLedgerV1());
        p.afterImpl[2] = address(new TSVSwapRouterV1(p.poolManager, p.newFactory));
        TSVLPManagerV1 oldLP = TSVLPManagerV1(payable(p.proxies[3]));
        p.afterImpl[3] = address(
            new TSVLPManagerV1(
                IPoolManager(p.poolManager),
                oldLP.permit2(),
                oldLP.unsubscribeGasLimit(),
                oldLP.tokenDescriptor(),
                oldLP.WETH9(),
                IPermissionsAdapterFactory(p.newFactory),
                oldLP.DELIVERY_GAS_LIMIT()
            )
        );
        p.afterImpl[4] = address(new TSVHookV1());
        p.bridge = address(new TSVRouterFactoryBridge(p.poolManager, p.oldFactory, p.afterImpl[2], p.proxies[0]));
        c = new TSVFactoryMigrationCoordinator(p);
    }

    function _load() private view returns (TSVFactoryMigrationCoordinator c) {
        string memory j = vm.readFile(vm.envString("TSV_UPGRADE_PLAN"));
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "wrong plan chain");
        address a = vm.parseJsonAddress(j, ".coordinator");
        require(
            a.code.length != 0 && a.codehash == vm.parseJsonBytes32(j, ".coordinatorCodeHash"),
            "coordinator missing/code drift"
        );
        c = TSVFactoryMigrationCoordinator(a);
        require(c.PLAN_HASH() == vm.parseJsonBytes32(j, ".planHash"), "wrong plan hash");
    }

    function _writePlan(TSVFactoryMigrationCoordinator c, string memory path) private {
        TSVFactoryMigrationCoordinator.Plan memory p = c.getPlan();
        string memory key = "factory-migration-plan";
        vm.serializeUint(key, "chainId", p.chainId);
        vm.serializeUint(key, "deadline", p.deadline);
        vm.serializeString(key, "sourceManifest", vm.envString("TSV_UPGRADE_MANIFEST"));
        vm.serializeAddress(key, "operator", p.operator);
        vm.serializeAddress(key, "coordinator", address(c));
        vm.serializeBytes32(key, "coordinatorCodeHash", address(c).codehash);
        vm.serializeBytes32(key, "planHash", c.PLAN_HASH());
        vm.serializeAddress(key, "oldFactory", p.oldFactory);
        vm.serializeAddress(key, "newFactory", p.newFactory);
        vm.serializeAddress(key, "bridge", p.bridge);
        vm.serializeAddress(key, "poolManager", p.poolManager);
        for (uint256 i; i < 5; ++i) {
            vm.serializeAddress(key, string.concat(_name(i), "Proxy"), p.proxies[i]);
            vm.serializeAddress(key, string.concat(_name(i), "Before"), p.beforeImpl[i]);
            vm.serializeAddress(key, string.concat(_name(i), "After"), p.afterImpl[i]);
            vm.serializeBytes32(key, string.concat(_name(i), "BeforeCodeHash"), p.beforeCodeHash[i]);
        }
        string memory result = vm.serializeString(key, "status", "unverified-until-readback");
        vm.writeJson(result, path);
    }

    function _name(uint256 i) private pure returns (string memory) {
        if (i == 0) return "registry";
        if (i == 1) return "ledger";
        if (i == 2) return "router";
        if (i == 3) return "lpManager";
        return "hook";
    }
}
