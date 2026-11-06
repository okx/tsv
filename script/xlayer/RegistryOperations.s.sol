// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {
    UnderlyingRecord,
    QuoteTokenRecord,
    TierPolicyRecord,
    SecurityRecord,
    PoolRecord,
    SecurityPauseMode,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlag} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @notice Runs one explicitly selected Registry or Router administrative operation.
/// @dev Each reason-coded action has its own environment variable; calls are simulated unless --broadcast is passed.
contract RegistryOperations is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address operator = vm.addr(privateKey);
        TSVRegistryV1 registry = TSVRegistryV1(vm.envAddress("TSV_REGISTRY"));
        require(address(registry).code.length != 0, "TSV_REGISTRY has no code");

        string memory action = vm.envString("TSV_REGISTRY_ACTION");
        bytes32 actionHash = keccak256(bytes(action));
        console2.log("XLayer chainId:", block.chainid);
        console2.log("Registry:", address(registry));
        console2.log("Action:", action);
        console2.log("Operator:", operator);

        if (actionHash == keccak256("GRANT_SYMBOL_ADMIN_ROLE")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            address account = vm.envAddress("TSV_ROLE_ACCOUNT");
            require(!registry.hasRole(registry.SYMBOL_ADMIN_ROLE(), account), "account already has SYMBOL_ADMIN_ROLE");
            console2.log("Grant SYMBOL_ADMIN_ROLE to:", account);
            vm.startBroadcast(privateKey);
            registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), account);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("GRANT_POOL_CREATOR_ROLE")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            address account = vm.envAddress("TSV_ROLE_ACCOUNT");
            require(!registry.hasRole(registry.POOL_CREATOR_ROLE(), account), "account already has POOL_CREATOR_ROLE");
            console2.log("Grant POOL_CREATOR_ROLE to:", account);
            vm.startBroadcast(privateKey);
            registry.grantRole(registry.POOL_CREATOR_ROLE(), account);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("REVOKE_POOL_CREATOR_ROLE")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            address account = vm.envAddress("TSV_ROLE_ACCOUNT");
            require(registry.hasRole(registry.POOL_CREATOR_ROLE(), account), "account lacks POOL_CREATOR_ROLE");
            console2.log("Revoke POOL_CREATOR_ROLE from:", account);
            vm.startBroadcast(privateKey);
            registry.revokeRole(registry.POOL_CREATOR_ROLE(), account);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("GRANT_VOLUME_ORACLE_ROLE")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            address account = vm.envAddress("TSV_ROLE_ACCOUNT");
            require(!registry.hasRole(registry.VOLUME_ORACLE_ROLE(), account), "account already has VOLUME_ORACLE_ROLE");
            console2.log("Grant VOLUME_ORACLE_ROLE to:", account);
            vm.startBroadcast(privateKey);
            registry.grantRole(registry.VOLUME_ORACLE_ROLE(), account);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("REVOKE_VOLUME_ORACLE_ROLE")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            address account = vm.envAddress("TSV_ROLE_ACCOUNT");
            require(registry.hasRole(registry.VOLUME_ORACLE_ROLE(), account), "account lacks VOLUME_ORACLE_ROLE");
            console2.log("Revoke VOLUME_ORACLE_ROLE from:", account);
            vm.startBroadcast(privateKey);
            registry.revokeRole(registry.VOLUME_ORACLE_ROLE(), account);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("DISABLE_QUOTE")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            address quote = vm.envAddress("TSV_DISABLE_QUOTE_TOKEN");
            bytes32 reason = _reason("TSV_DISABLE_QUOTE_REASON_CODE");
            require(registry.getQuoteToken(quote).registered, "quote is not enabled");
            vm.startBroadcast(privateKey);
            registry.disableQuoteTokenPoolRegister(quote, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("DISABLE_UNDERLYING")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            address underlying = vm.envAddress("TSV_DISABLE_UNDERLYING_TOKEN");
            bytes32 reason = _reason("TSV_DISABLE_UNDERLYING_REASON_CODE");
            require(registry.getUnderlying(underlying).registered, "underlying is not enabled");
            vm.startBroadcast(privateKey);
            registry.disableUnderlyingPoolRegister(underlying, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("REPLACE_LEGAL_ADAPTER")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            address underlying = vm.envAddress("TSV_REPLACE_ADAPTER_UNDERLYING");
            address adapter = vm.envAddress("TSV_REPLACE_LEGAL_ADAPTER");
            bytes32 reason = _reason("TSV_REPLACE_ADAPTER_REASON_CODE");
            require(adapter.code.length != 0, "new legal-share adapter has no code");
            UnderlyingRecord memory record = registry.getUnderlying(underlying);
            require(record.securityId != bytes32(0), "underlying is not registered");
            require(adapter != record.legalShareAdapter, "adapter is already current");
            IDirectLegalShareAdapter converter = IDirectLegalShareAdapter(adapter);
            require(converter.poolCurrency() == underlying, "new adapter is bound to another U");
            require(converter.currentMultiplier(underlying) != 0, "new adapter multiplier is zero");
            vm.startBroadcast(privateKey);
            registry.replaceUnderlyingLegalShareAdapter(underlying, adapter, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("SET_TIER_POLICY")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            uint256 tierRaw = vm.envUint("TSV_TIER_ID");
            uint256 maxListedRaw = vm.envUint("TSV_TIER_MAX_LISTED");
            bytes32 reason = _reason("TSV_TIER_POLICY_REASON_CODE");
            require(tierRaw > 0 && tierRaw <= type(uint8).max, "tier ID must be 1..255");
            require(maxListedRaw <= type(uint32).max, "tier capacity exceeds uint32");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tierId = uint8(tierRaw);
            TierPolicyRecord memory current = registry.getTierPolicy(tierId);
            require(maxListedRaw >= current.listedCount, "tier capacity is below listed count");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 maxListed = uint32(maxListedRaw);
            vm.startBroadcast(privateKey);
            registry.setTierPolicy(tierId, maxListed, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("SET_SBT_CONFIG")) {
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            uint256 tokenId = vm.envUint("TSV_SBT_TOKEN_ID");
            uint256 permissionsRaw = vm.envUint("TSV_SBT_PERMISSIONS");
            bytes32 reason = _reason("TSV_SBT_CONFIG_REASON_CODE");
            require(permissionsRaw <= 3, "permissions must be NONE, SWAP, LP, or SWAP|LP (0..3)");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 permissionBits = uint16(permissionsRaw);
            vm.startBroadcast(privateKey);
            registry.setSbtConfig(tokenId, PermissionFlag.wrap(bytes2(permissionBits)), reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("RELIST_SECURITY")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            bytes32 securityId = vm.envBytes32("TSV_SECURITY_ID");
            bytes32 reason = _reason("TSV_RELIST_SECURITY_REASON_CODE");
            SecurityRecord memory security = registry.getSecurity(securityId);
            require(security.securityId != bytes32(0) && !security.listed, "security is not delisted");
            vm.startBroadcast(privateKey);
            registry.relistSecurity(securityId, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("SET_SECURITY_TIER")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            bytes32 securityId = vm.envBytes32("TSV_SECURITY_ID");
            uint256 tierRaw = vm.envUint("TSV_SECURITY_TIER_ID");
            bytes32 reason = _reason("TSV_SECURITY_TIER_REASON_CODE");
            require(tierRaw > 0 && tierRaw <= type(uint8).max, "tier ID must be 1..255");
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tierId = uint8(tierRaw);
            SecurityRecord memory security = registry.getSecurity(securityId);
            require(security.listed && security.tierId != tierId, "security cannot move to requested tier");
            TierPolicyRecord memory tier = registry.getTierPolicy(tierId);
            require(tier.maxListed > tier.listedCount, "target tier has no capacity");
            vm.startBroadcast(privateKey);
            registry.setSecurityTier(securityId, tierId, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("DELIST_SECURITY")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            bytes32 securityId = vm.envBytes32("TSV_SECURITY_ID");
            bytes32 reason = _reason("TSV_DELIST_SECURITY_REASON_CODE");
            SecurityRecord memory security = registry.getSecurity(securityId);
            require(security.listed && security.listedPoolCount == 0, "security must be listed with no active pools");
            vm.startBroadcast(privateKey);
            registry.delistSecurity(securityId, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("SECURITY_STATUS")) {
            _requireRole(registry, registry.HALT_REPORTER_ROLE(), operator);
            bytes32 securityId = vm.envBytes32("TSV_SECURITY_ID");
            uint256 modeRaw = vm.envUint("TSV_SECURITY_PAUSE_MODE");
            bool enable = vm.envBool("TSV_SECURITY_PAUSE_ENABLE");
            bytes32 reason = _reason("TSV_SECURITY_STATUS_REASON_CODE");
            require(modeRaw <= uint256(SecurityPauseMode.ALL), "pause mode must be TRADE=0, LP=1 or ALL=2");
            SecurityRecord memory security = registry.getSecurity(securityId);
            require(security.listed, "security is not listed");
            uint8 currentMode = registry.getSecurityPauseMode(securityId);
            uint8 selectedBits;
            if (modeRaw == uint256(SecurityPauseMode.TRADE)) selectedBits = 1;
            else if (modeRaw == uint256(SecurityPauseMode.LP)) selectedBits = 2;
            else selectedBits = 3;
            uint8 nextMode = enable ? currentMode | selectedBits : currentMode & ~selectedBits;
            require(nextMode != currentMode, "security pause state would not change");
            // forge-lint: disable-next-line(unsafe-typecast)
            SecurityPauseMode mode = SecurityPauseMode(uint8(modeRaw));
            vm.startBroadcast(privateKey);
            registry.applySecurityStatus(securityId, mode, enable, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("POOL_LIFECYCLE")) {
            _requireRole(registry, registry.SYMBOL_ADMIN_ROLE(), operator);
            bytes32 poolId = vm.envBytes32("TSV_POOL_ID");
            uint256 lifecycleRaw = vm.envUint("TSV_POOL_LIFECYCLE");
            bytes32 reason = _reason("TSV_POOL_LIFECYCLE_REASON_CODE");
            require(lifecycleRaw <= uint256(PoolLifecycle.PAUSE), "lifecycle must be DELIST=0, LIST=1 or PAUSE=2");
            require(registry.isKnownPool(poolId), "pool is unknown");
            PoolRecord memory pool = registry.getPool(poolId);
            if (lifecycleRaw == uint256(PoolLifecycle.DELIST)) {
                require(pool.tickCount == 0, "pool still has active positions");
            } else {
                require(registry.getSecurity(pool.securityId).listed, "pool security is delisted");
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            PoolLifecycle lifecycle = PoolLifecycle(uint8(lifecycleRaw));
            require(registry.getPoolLifeCycle(poolId) != lifecycle, "pool already has requested lifecycle");
            vm.startBroadcast(privateKey);
            registry.updatePoolLifeCycle(poolId, lifecycle, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("GLOBAL_PAUSE")) {
            bool enabled = vm.envBool("TSV_GLOBAL_PAUSE_ENABLED");
            bytes32 reason = _reason("TSV_GLOBAL_PAUSE_REASON_CODE");
            require(registry.emergencyPauseEnable() != enabled, "global pause state already matches request");
            bytes32 requiredRole = enabled ? registry.EMERGENCY_PAUSER_ROLE() : registry.EMERGENCY_RESUMER_ROLE();
            _requireRole(registry, requiredRole, operator);
            vm.startBroadcast(privateKey);
            registry.setEmergencyPauseEnable(enabled, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("ROUTER_ADAPTER")) {
            address routerAddress = vm.envAddress("TSV_ROUTER");
            address adapter = vm.envAddress("TSV_ROUTER_ADAPTER");
            bool allowed = vm.envBool("TSV_ROUTER_ADAPTER_ALLOWED");
            _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
            TSVSwapRouterV1 router = TSVSwapRouterV1(routerAddress);
            require(address(router).code.length != 0, "TSV_ROUTER has no code");
            require(address(router.registry()) == address(registry), "Router is bound to another Registry");
            require(adapter != address(0), "adapter is zero");
            require(router.isAdapterAllowed(adapter) != allowed, "adapter authorization already matches request");
            if (allowed) require(adapter.code.length != 0, "adapter has no code");
            vm.startBroadcast(privateKey);
            router.setAdapterAllowed(adapter, allowed);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("MIGRATE_PERMISSIONS_ADAPTER_FACTORY")) {
            _migratePermissionsAdapterFactory(registry, privateKey, operator);
        } else {
            revert("unknown TSV_REGISTRY_ACTION");
        }
    }

    function _migratePermissionsAdapterFactory(TSVRegistryV1 registry, uint256 privateKey, address operator) private {
        _requireRole(registry, registry.DEFAULT_ADMIN_ROLE(), operator);
        _requireRole(registry, registry.UPGRADE_ADMIN_ROLE(), operator);
        require(!registry.emergencyPauseEnable(), "Registry must start unpaused");

        address newFactory = vm.envAddress("TSV_NEW_PERMISSIONS_ADAPTER_FACTORY");
        address previousFactory = registry.permissionsAdapterFactory();
        require(newFactory != previousFactory && newFactory.code.length != 0, "invalid replacement Factory");
        IPermissionsAdapterFactory replacementFactory = IPermissionsAdapterFactory(newFactory);
        address poolManager = registry.permissionedPoolManager();
        require(replacementFactory.POOL_MANAGER() == poolManager, "new Factory PoolManager mismatch");

        address lpManagerAddress = registry.lpManager();
        address hookAddress = registry.hook();
        require(lpManagerAddress == vm.envAddress("TSV_LP_MANAGER"), "LP Manager config drift");
        require(hookAddress == vm.envAddress("TSV_HOOK"), "Hook config drift");
        require(lpManagerAddress.code.length != 0 && hookAddress.code.length != 0, "component has no code");

        IFactoryReplacementHook hookComponent = IFactoryReplacementHook(hookAddress);
        address routerAddress = hookComponent.router();
        require(routerAddress == vm.envAddress("TSV_ROUTER"), "Router config drift");
        require(routerAddress.code.length != 0, "Router has no code");
        require(
            hookComponent.registry() == address(registry) && hookComponent.poolManager() == poolManager
                && hookComponent.lpManager() == lpManagerAddress,
            "Hook component bindings mismatch"
        );

        TSVLPManagerV1 lpManager = TSVLPManagerV1(payable(lpManagerAddress));
        TSVSwapRouterV1 router = TSVSwapRouterV1(routerAddress);
        require(address(lpManager.registry()) == address(registry), "LP Manager Registry mismatch");
        require(address(router.registry()) == address(registry), "Router Registry mismatch");
        require(address(lpManager.poolManager()) == poolManager, "LP Manager PoolManager mismatch");
        require(address(router.poolManager()) == poolManager, "Router PoolManager mismatch");
        require(
            address(lpManager.PERMISSIONS_ADAPTER_FACTORY()) == previousFactory
                && address(router.PERMISSIONS_ADAPTER_FACTORY()) == previousFactory,
            "component Factory drift"
        );

        uint256 securityCount = vm.envUint("TSV_INSPECT_SECURITY_COUNT");
        require(securityCount != 0, "security inventory is empty");
        for (uint256 i; i < securityCount; ++i) {
            bytes32 securityId = vm.envBytes32(string.concat("TSV_INSPECT_SECURITY_", vm.toString(i)));
            SecurityRecord memory security = registry.getSecurity(securityId);
            require(security.securityId == securityId, "security inventory mismatch");
            require(security.listedPoolCount == 0, "all old Factory pools must be delisted first");
        }

        bytes32 pauseReason = _migrationReason("TSV_FACTORY_REPLACE_PAUSE_REASON_CODE");
        bytes32 replaceReason = _migrationReason("TSV_FACTORY_REPLACE_REASON_CODE");
        bytes32 resumeReason = _migrationReason("TSV_FACTORY_REPLACE_RESUME_REASON_CODE");
        require(
            pauseReason != replaceReason && pauseReason != resumeReason && replaceReason != resumeReason,
            "use a different reasonCode for each migration operation"
        );

        uint256 wrappedCount = vm.envUint("TSV_INSPECT_W_COUNT");
        for (uint256 i; i < wrappedCount; ++i) {
            address wrapped = vm.envAddress(string.concat("TSV_INSPECT_W_", vm.toString(i)));
            address oldUnderlying = IPermissionsAdapterFactory(previousFactory).permissionsAdapterOf(wrapped);
            address newUnderlying = replacementFactory.permissionsAdapterOf(wrapped);
            if (oldUnderlying != newUnderlying) {
                console2.log("Factory mapping changes for W:", wrapped);
                console2.log("Previous U:", oldUnderlying);
                console2.log("Replacement U:", newUnderlying);
            }
        }

        console2.log("Replacing PermissionsAdapterFactory:", previousFactory, newFactory);
        console2.log("PoolManager:", poolManager);
        console2.log("LP Manager and Router upgrades run while Registry is unpaused.");
        console2.log("The current signer keeps EMERGENCY_PAUSER_ROLE and EMERGENCY_RESUMER_ROLE.");

        vm.startBroadcast(privateKey);
        if (!registry.hasRole(registry.EMERGENCY_PAUSER_ROLE(), operator)) {
            registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), operator);
        }
        if (!registry.hasRole(registry.EMERGENCY_RESUMER_ROLE(), operator)) {
            registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), operator);
        }

        TSVLPManagerV1 nextLpManager = new TSVLPManagerV1(
            IPoolManager(poolManager),
            IAllowanceTransfer(address(lpManager.permit2())),
            lpManager.unsubscribeGasLimit(),
            IPositionDescriptor(address(lpManager.tokenDescriptor())),
            IWETH9(address(lpManager.WETH9())),
            replacementFactory,
            lpManager.DELIVERY_GAS_LIMIT()
        );
        console2.log("LP Manager implementation:", address(nextLpManager));
        lpManager.upgradeToAndCall(address(nextLpManager), bytes(""));
        require(address(lpManager.PERMISSIONS_ADAPTER_FACTORY()) == newFactory, "LP Manager upgrade failed");

        TSVSwapRouterV1 bridgeRouter = new TSVSwapRouterV1(poolManager, previousFactory);
        console2.log("Router bridge implementation:", address(bridgeRouter));
        router.upgradeToAndCall(address(bridgeRouter), bytes(""));
        require(address(router.PERMISSIONS_ADAPTER_FACTORY()) == previousFactory, "Router bridge upgrade failed");

        TSVSwapRouterV1 nextRouter = new TSVSwapRouterV1(poolManager, newFactory);
        console2.log("Router target implementation:", address(nextRouter));
        router.upgradeToAndCall(address(nextRouter), bytes(""));
        require(address(router.PERMISSIONS_ADAPTER_FACTORY()) == newFactory, "Router Factory upgrade failed");

        registry.setEmergencyPauseEnable(true, pauseReason);
        TSVRegistryV1 nextRegistry = new TSVRegistryV1();
        console2.log("Registry implementation:", address(nextRegistry));
        registry.upgradeToAndCall(address(nextRegistry), bytes(""));
        registry.replacePermissionsAdapterFactory(newFactory, replaceReason);
        require(registry.permissionsAdapterFactory() == newFactory, "Registry Factory replacement failed");
        registry.setEmergencyPauseEnable(false, resumeReason);
        require(!registry.emergencyPauseEnable(), "Registry remains paused");
        vm.stopBroadcast();

        console2.log("PermissionsAdapterFactory migration completed; pause roles remain assigned.");
    }

    function _migrationReason(string memory variableName) private view returns (bytes32 reason) {
        reason = vm.envBytes32(variableName);
        require(reason != bytes32(0), "migration reasonCode must be nonzero");
        console2.log(variableName);
        console2.logBytes32(reason);
    }

    function _reason(string memory variableName) private view returns (bytes32 reason) {
        reason = vm.envBytes32(variableName);
        require(reason != bytes32(0), "operation reason code must be nonzero");
        console2.log("Operation reason:");
        console2.logBytes32(reason);
    }

    function _requireRole(TSVRegistryV1 registry, bytes32 role, address account) private view {
        require(registry.hasRole(role, account), "operator lacks required Registry role");
    }
}

interface IFactoryReplacementHook {
    function registry() external view returns (address);
    function poolManager() external view returns (address);
    function router() external view returns (address);
    function lpManager() external view returns (address);
}
