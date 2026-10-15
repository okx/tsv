// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager as CorePoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey as CorePoolKey} from "v4-core/types/PoolKey.sol";
import {Currency as CoreCurrency} from "v4-core/types/Currency.sol";
import {IHooks as CoreHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey, Currency, IHooks, Actions, TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "tsv-v1/vendor/permissionedPools/PermissionedPositionManager.sol";
import {PermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/PermissionsAdapterFactory.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC20 as VendorERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {SwapRequest, PermissionedRegisterParam} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistrySbtMigration} from "./lib/TSVRegistrySbtMigration.sol";
import {ERC8056TestToken} from "../lib/TestToken/erc8056/ERC8056TestToken.sol";
import {TSVAA, AACall, AAOwner, IAAFactory, IAAWallet} from "./lib/TSVAA.sol";

interface IProtocolSbt {
    function paused() external view returns (bool);
    function verify(address account, uint256 tokenId) external view returns (bool);
    function issuerRole(uint256 tokenId) external pure returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function issue(address[] calldata accounts, uint256 tokenId) external;
}

interface IProtocolAdapter {
    function updateAllowedWrapper(address wrapper, bool allowed) external;
    function updateAllowedHook(address hook, bool allowed) external;
    function updateSwappingEnabled(bool enabled) external;
}

interface IUUPSProtocol {
    function upgradeToAndCall(address implementation, bytes calldata data) external payable;
}

/// @notice X Layer TSV deployment, upgrades, SBT enrollment and ERC-4337 trading/LP operations.
/// @dev Use script/tsv-protocol.py: it manages pending manifests and checks mined receipts.
contract TSVProtocol is TSVAA {
    using PoolIdLibrary for CorePoolKey;
    string public constant DEPLOYMENT_FILE = "./dployment/XLAYER_MAINNET_SMOKE_20261014.json";
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant REASON = bytes32("TSV_PROTOCOL_SCRIPT");

    struct Addresses {
        address registry;
        address ledger;
        address router;
        address lp;
        address hook;
        address factory;
        address hookFactory;
        address underlying;
        address wrapped;
        address legal;
        address quote;
        address poolManager;
        address sbt;
    }

    function _json() internal view returns (string memory data) {
        data = vm.readFile(DEPLOYMENT_FILE);
        require(vm.parseJsonUint(data, ".chainId") == block.chainid && block.chainid == 196, "wrong chain");
    }

    function _address(string memory data, string memory path) internal pure returns (address) {
        return vm.parseAddress(vm.parseJsonString(data, path));
    }

    function _load(bool confirmed) internal view returns (Addresses memory a) {
        string memory j = _json();
        if (confirmed) {
            require(
                keccak256(bytes(vm.parseJsonString(j, ".deploymentStatus"))) == keccak256("confirmed"),
                "manifest pending"
            );
        }
        a.registry = _address(j, ".proxies.registry");
        a.ledger = _address(j, ".proxies.ledger");
        a.router = _address(j, ".proxies.router");
        a.lp = _address(j, ".proxies.lpManager");
        a.hook = _address(j, ".proxies.hook");
        a.factory = _address(j, ".factories.permissionedAdapter");
        a.hookFactory = _address(j, ".factories.hookProxy");
        a.underlying = _address(j, ".assets.mock8056");
        a.wrapped = _address(j, ".assets.wrappedMock8056");
        a.legal = _address(j, ".assets.legalShareAdapter");
        a.quote = _address(j, ".assets.usdt0");
        a.poolManager = _address(j, ".dependencies.poolManager");
        a.sbt = _address(j, ".sbt.address");
    }

    function _writeAddress(string memory path, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), DEPLOYMENT_FILE, path);
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _key(Addresses memory a) internal view returns (CorePoolKey memory) {
        string memory j = _json();
        return CorePoolKey(
            CoreCurrency.wrap(a.wrapped < a.quote ? a.wrapped : a.quote),
            CoreCurrency.wrap(a.wrapped < a.quote ? a.quote : a.wrapped),
            uint24(vm.parseJsonUint(j, ".pool.fee")),
            int24(vm.parseJsonInt(j, ".pool.tickSpacing")),
            CoreHooks(a.hook)
        );
    }

    function _lpKey(CorePoolKey memory k) internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(CoreCurrency.unwrap(k.currency0)),
            Currency.wrap(CoreCurrency.unwrap(k.currency1)),
            k.fee,
            k.tickSpacing,
            IHooks(address(k.hooks))
        );
    }

    function _newLP(Addresses memory a) internal returns (address) {
        string memory j = _json();
        return address(
            new TSVLPManagerV1(
                IPoolManager(a.poolManager),
                IAllowanceTransfer(_address(j, ".dependencies.permit2")),
                vm.parseJsonUint(j, ".configuration.unsubscribeGasLimit"),
                IPositionDescriptor(_address(j, ".dependencies.positionDescriptor")),
                IWETH9(_address(j, ".dependencies.wokb")),
                IPermissionsAdapterFactory(a.factory),
                vm.parseJsonUint(j, ".configuration.deliveryGasLimit"),
                ITSVPermissionedRegistry(a.registry)
            )
        );
    }

    function bootstrap() external {
        deployAA();
        issueSbt();
        if (vm.parseJsonBool(_json(), ".configuration.preserveProxies")) {
            migrateSbt();
        } else {
            if (vm.parseJsonBool(_json(), ".configuration.deployMockUnderlying")) deployMock();
            deploy();
        }
    }

    function deployMock() public {
        string memory j = _json();
        uint256 pk = vm.envUint("PK");
        vm.startBroadcast(pk);
        ERC8056TestToken token = new ERC8056TestToken(
            vm.parseJsonString(j, ".mockToken.name"),
            vm.parseJsonString(j, ".mockToken.symbol"),
            uint8(vm.parseJsonUint(j, ".mockToken.decimals")),
            vm.parseJsonUint(j, ".mockToken.initialSupply")
        );
        vm.stopBroadcast();
        _writeAddress(".assets.mock8056", address(token));
        require(ERC8056TestToken(_address(_json(), ".assets.mock8056")).owner() == vm.addr(pk), "mock owner mismatch");
    }

    function smoke() external {
        string memory j = _json();
        uint256 id = TSVLPManagerV1(payable(_load(true).lp)).nextTokenId();
        addLiquidityAuto(
            uint128(vm.parseJsonUint(j, ".smoke.underlyingMax")),
            uint128(vm.parseJsonUint(j, ".smoke.quoteMax")),
            uint128(vm.parseJsonUint(j, ".smoke.minLiquidity"))
        );
        swap(
            true, uint128(vm.parseJsonUint(j, ".smoke.swapInput")), uint128(vm.parseJsonUint(j, ".smoke.swapMinOutput"))
        );
        collect(id);
        removeLiquidity(
            id,
            uint128(vm.parseJsonUint(j, ".smoke.removeAmount0Min")),
            uint128(vm.parseJsonUint(j, ".smoke.removeAmount1Min"))
        );
    }

    /// @dev Both TSV factories are freshly deployed, then every address is saved and read back.
    function deploy() public {
        string memory j = _json();
        Addresses memory a = _load(false);
        require(!vm.parseJsonBool(j, ".configuration.preserveProxies"), "proxy preservation enabled; use upgrade");
        for (uint8 i; i < 5; ++i) {
            require(_component(a, i) == address(0), "deploy requires empty proxy addresses; use upgrade");
        }
        address admin = _address(j, ".configuration.admin");
        uint256 pk = vm.envUint("PK");
        require(admin == vm.addr(pk), "deployment signer must be bootstrap admin");
        require(a.poolManager.code.length != 0 && a.sbt.code.length != 0, "missing PoolManager/SBT");
        address checker = _address(j, ".configuration.allowlistChecker");
        require(checker.code.length != 0 && a.underlying.code.length != 0, "missing checker/underlying");
        require(!IProtocolSbt(a.sbt).paused(), "SBT paused");
        vm.startBroadcast(pk);
        a.factory = address(new PermissionsAdapterFactory(a.poolManager));
        a.hookFactory = address(new TSVHookProxyFactoryV1());
        a.legal = address(new ERC8056DirectLegalShareAdapter(a.underlying));
        a.wrapped = PermissionsAdapterFactory(a.factory)
            .createPermissionsAdapter(VendorERC20(a.underlying), admin, IAllowlistChecker(checker));
        require(IERC20(a.underlying).transfer(a.wrapped, 1), "adapter verification deposit failed");
        PermissionsAdapterFactory(a.factory).verifyPermissionsAdapter(a.wrapped);
        address registryImpl = address(new TSVRegistryV1());
        a.registry = address(new TSVERC1967Proxy(registryImpl, abi.encodeCall(TSVRegistryV1.initialize, (admin))));
        address ledgerImpl = address(new TSVVolumeLedgerV1());
        a.ledger = address(new TSVERC1967Proxy(ledgerImpl, abi.encodeCall(TSVVolumeLedgerV1.initialize, (a.registry))));
        address routerImpl = address(new TSVSwapRouterV1(a.poolManager, a.factory));
        a.router = address(
            new TSVERC1967Proxy(routerImpl, abi.encodeCall(TSVSwapRouterV1.initialize, (a.poolManager, a.registry)))
        );
        address lpImpl = _newLP(a);
        a.lp = address(
            new TSVERC1967Proxy(
                lpImpl, abi.encodeCall(TSVLPManagerV1.initialize, (ITSVPermissionedRegistry(a.registry)))
            )
        );
        address hookImpl = address(new TSVHookV1());
        bytes memory init = abi.encodeCall(TSVHookV1.initialize, (a.poolManager, a.registry, a.ledger, a.router, a.lp));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(TSVERC1967Proxy).creationCode, abi.encode(hookImpl, init)));
        bytes32 salt;
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            if (
                (uint160(
                                address(
                                    uint160(
                                        uint256(
                                            keccak256(abi.encodePacked(bytes1(0xff), a.hookFactory, salt, initCodeHash))
                                        )
                                    )
                                )
                            ) & 0x3fff) == 0x3fff
            ) {
                found = true;
                break;
            }
        }
        require(found, "hook salt search exhausted");
        a.hook = TSVHookProxyFactoryV1(a.hookFactory).deploy(hookImpl, init, salt);
        vm.stopBroadcast();

        // Persist before any component configuration. Subsequent calls use only the reread manifest.
        _writeAddress(".factories.permissionedAdapter", a.factory);
        _writeAddress(".factories.hookProxy", a.hookFactory);
        _writeAddress(".assets.wrappedMock8056", a.wrapped);
        _writeAddress(".assets.legalShareAdapter", a.legal);
        _writeAddress(".proxies.registry", a.registry);
        _writeAddress(".proxies.ledger", a.ledger);
        _writeAddress(".proxies.router", a.router);
        _writeAddress(".proxies.lpManager", a.lp);
        _writeAddress(".proxies.hook", a.hook);
        vm.writeJson(
            vm.toString(
                a.wrapped < a.quote
                    ? vm.parseJsonUint(j, ".pool.underlyingAsCurrency0SqrtPriceX96")
                    : vm.parseJsonUint(j, ".pool.quoteAsCurrency0SqrtPriceX96")
            ),
            DEPLOYMENT_FILE,
            ".pool.initialSqrtPriceX96"
        );
        _writeAddress(".implementations.registry", registryImpl);
        _writeAddress(".implementations.ledger", ledgerImpl);
        _writeAddress(".implementations.router", routerImpl);
        _writeAddress(".implementations.lpManager", lpImpl);
        _writeAddress(".implementations.hook", hookImpl);
        vm.writeJson('"pending"', DEPLOYMENT_FILE, ".deploymentStatus");
        vm.writeJson("false", DEPLOYMENT_FILE, ".sourceVerification");
        a = _load(false);
        vm.startBroadcast(pk);
        TSVRegistryV1 registry = TSVRegistryV1(a.registry);
        registry.bindComponents(a.hook, a.lp, a.factory, a.sbt);
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), admin);
        registry.grantRole(registry.POOL_CREATOR_ROLE(), admin);
        registry.grantRole(registry.VOLUME_ORACLE_ROLE(), admin);
        registry.setSbtConfig(uint256(vm.parseJsonBytes32(j, ".sbt.tokenId")), PermissionFlag.wrap(0x0003), REASON);
        uint8 tier = uint8(vm.parseJsonUint(j, ".configuration.tier"));
        registry.setTierPolicy(tier, 1, REASON);
        bytes32 securityId = vm.parseJsonBytes32(j, ".configuration.securityId");
        registry.registerPermissionedCurrency(PermissionedRegisterParam(a.wrapped, securityId, a.legal), tier, REASON);
        registry.registerQuoteToken(a.quote, REASON);
        TSVVolumeLedgerV1(a.ledger).setQuota(securityId, vm.parseJsonUint(j, ".configuration.quotaWad"), REASON);
        IProtocolAdapter(a.wrapped).updateAllowedWrapper(a.router, true);
        IProtocolAdapter(a.wrapped).updateAllowedWrapper(a.lp, true);
        IProtocolAdapter(a.wrapped).updateAllowedHook(a.hook, true);
        IProtocolAdapter(a.wrapped).updateSwappingEnabled(true);
        TSVLPManagerV1(payable(a.lp))
            .initializePool(_lpKey(_key(a)), uint160(vm.parseJsonUint(_json(), ".pool.initialSqrtPriceX96")));
        vm.stopBroadcast();
        _verifyCore(a);
        console2.log("New Registry", a.registry);
        console2.log("New PermissionsAdapterFactory", a.factory);
        console2.log("New HookProxyFactory", a.hookFactory);
    }

    /// @notice Deploy reference SmartWalletEntry/Factory artifacts and an ECDSA-owned wallet.
    /// @dev Artifacts must be compiled from the referenced chore/scripts repo and copied to dployment/aa.
    function deployAA() public {
        string memory j = _json();
        uint256 pk = vm.envUint("PK");
        address implementation = _address(j, ".aa.implementation");
        address factory = _address(j, ".aa.factory");
        AAOwner[] memory owners = new AAOwner[](1);
        owners[0] = AAOwner(keccak256(abi.encodePacked(vm.addr(pk))), address(1));
        vm.startBroadcast(pk);
        if (implementation == address(0)) {
            implementation = _createArtifact(vm.parseJsonString(j, ".aa.implementationArtifact"), bytes(""));
        }
        require(
            IAAWallet(implementation).entryPoint() == ENTRY_POINT
                && IAAWallet(implementation).IMPLEMENTATION() == implementation,
            "invalid AA implementation"
        );
        if (factory == address(0)) {
            factory = _createArtifact(vm.parseJsonString(j, ".aa.factoryArtifact"), abi.encode(implementation));
        }
        require(IAAFactory(factory).IMPLEMENTATION() == implementation, "AA factory implementation mismatch");
        vm.stopBroadcast();
        _writeAddress(".aa.implementation", implementation);
        _writeAddress(".aa.factory", factory);
        j = _json();
        implementation = _address(j, ".aa.implementation");
        factory = _address(j, ".aa.factory");
        vm.startBroadcast(pk);
        uint256 salt = vm.parseJsonUint(j, ".aa.salt");
        address predicted = IAAFactory(factory).getAddress(owners, salt);
        address wallet = IAAFactory(factory).createAccount(owners, salt);
        require(wallet == predicted, "AA prediction mismatch");
        vm.stopBroadcast();
        _writeAddress(".aa.implementation", implementation);
        _writeAddress(".aa.factory", factory);
        _writeAddress(".aa.wallet", wallet);
        j = _json();
        _checkWallet(_address(j, ".aa.wallet"), vm.addr(pk));
        console2.log("AA Wallet", _address(j, ".aa.wallet"));
    }

    function _createArtifact(string memory path, bytes memory args) internal returns (address deployed) {
        bytes memory creation = vm.parseJsonBytes(vm.readFile(path), ".bytecode.object");
        string memory hashKey = args.length == 0 ? ".aa.implementationArtifactHash" : ".aa.factoryArtifactHash";
        require(keccak256(creation) == vm.parseJsonBytes32(_json(), hashKey), "AA artifact hash mismatch");
        bytes memory code = abi.encodePacked(creation, args);
        require(code.length > args.length, "empty artifact");
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed.code.length != 0, "artifact deployment failed");
    }

    /// @notice Replace the mock SBT behind the existing Registry proxy, retaining every protocol proxy/factory.
    function migrateSbt() public {
        Addresses memory a = _load(true);
        _verifyCore(a);
        TSVRegistryV1 registry = TSVRegistryV1(a.registry);
        if (registry.participantSbt() == a.sbt) return;
        uint256 pk = vm.envUint("PK");
        require(registry.hasRole(registry.UPGRADE_ADMIN_ROLE(), vm.addr(pk)), "signer lacks upgrade role");
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), vm.addr(pk)), "signer lacks SBT config role");
        address beforeImpl = _implementation(a.registry);
        require(beforeImpl == _address(_json(), ".implementations.registry"), "Registry implementation drift");
        address beforeSbt = registry.participantSbt();
        vm.startBroadcast(pk);
        address next = address(new TSVRegistrySbtMigration());
        registry.upgradeToAndCall(next, abi.encodeCall(TSVRegistrySbtMigration.migrateSbt, (a.sbt)));
        registry.setSbtConfig(
            uint256(vm.parseJsonBytes32(_json(), ".sbt.tokenId")), PermissionFlag.wrap(0x0003), REASON
        );
        vm.stopBroadcast();
        require(registry.participantSbt() == a.sbt, "SBT migration readback mismatch");
        _writeAddress(".implementations.registry", next);
        _writeAddress(".boundSbt.previous", beforeSbt);
        _writeAddress(".boundSbt.address", a.sbt);
        _verifyCore(_load(false));
        vm.writeJson('"pending"', DEPLOYMENT_FILE, ".deploymentStatus");
    }

    function issueSbt() public {
        string memory j = _json();
        address sbt = _address(j, ".sbt.address");
        address wallet = _address(j, ".aa.wallet");
        uint256 pk = vm.envUint("PK");
        _checkWallet(wallet, vm.addr(pk));
        uint256 tokenId = uint256(vm.parseJsonBytes32(j, ".sbt.tokenId"));
        IProtocolSbt credential = IProtocolSbt(sbt);
        require(!credential.paused(), "SBT paused");
        require(credential.issuerRole(tokenId) == vm.parseJsonBytes32(j, ".sbt.issuerRole"), "SBT issuer role mismatch");
        if (!credential.verify(wallet, tokenId)) {
            require(
                credential.hasRole(vm.parseJsonBytes32(j, ".sbt.issuerRole"), vm.addr(pk)),
                "signer lacks SBT issuer role"
            );
            address[] memory recipients = new address[](1);
            recipients[0] = wallet;
            vm.startBroadcast(pk);
            credential.issue(recipients, tokenId);
            vm.stopBroadcast();
        }
        require(credential.verify(wallet, tokenId), "SBT issue verification failed");
    }

    /// @notice Explicit bounded funding from the signer to the AA wallet, amounts supplied by caller.
    function fundAA(uint256 underlyingAmount, uint256 quoteAmount) external {
        Addresses memory a = _load(true);
        address wallet = _address(_json(), ".aa.wallet");
        uint256 pk = vm.envUint("PK");
        _checkWallet(wallet, vm.addr(pk));
        vm.startBroadcast(pk);
        if (underlyingAmount != 0) {
            require(IERC20(a.underlying).transfer(wallet, underlyingAmount), "U funding failed");
        }
        if (quoteAmount != 0) require(IERC20(a.quote).transfer(wallet, quoteAmount), "quote funding failed");
        vm.stopBroadcast();
    }

    /// @notice Components 0=Registry, 1=Ledger, 2=Router, 3=LPManager, 4=Hook.
    /// @dev Read expected old implementation from JSON; explicit migration calldata permits layout migrations.
    function upgrade(uint8 component, bytes calldata migration) external {
        require(component < 5, "unknown component");
        Addresses memory a = _load(true);
        _verifyCore(a);
        string memory j = _json();
        string memory name = _componentName(component);
        address proxy = _component(a, component);
        address oldImpl = _address(j, string.concat(".implementations.", name));
        require(_implementation(proxy) == oldImpl, "implementation drift");
        uint256 pk = vm.envUint("PK");
        require(
            TSVRegistryV1(a.registry).hasRole(keccak256("UPGRADE_ADMIN_ROLE"), vm.addr(pk)), "signer not upgrade admin"
        );
        require(!TSVRegistryV1(a.registry).isPaused(), "Registry paused");
        vm.startBroadcast(pk);
        address next;
        if (component == 0) {
            next = address(new TSVRegistryV1());
        } else if (component == 1) {
            next = address(new TSVVolumeLedgerV1());
        } else if (component == 2) {
            next = address(new TSVSwapRouterV1(a.poolManager, a.factory));
        } else if (component == 3) {
            TSVLPManagerV1 oldLP = TSVLPManagerV1(payable(a.lp));
            next = address(
                new TSVLPManagerV1(
                    IPoolManager(a.poolManager),
                    oldLP.permit2(),
                    oldLP.unsubscribeGasLimit(),
                    oldLP.tokenDescriptor(),
                    oldLP.WETH9(),
                    IPermissionsAdapterFactory(a.factory),
                    oldLP.DELIVERY_GAS_LIMIT(),
                    ITSVPermissionedRegistry(a.registry)
                )
            );
        } else {
            next = address(new TSVHookV1());
        }
        IUUPSProtocol(proxy).upgradeToAndCall(next, migration);
        vm.stopBroadcast();
        require(_implementation(proxy) == next, "upgrade slot mismatch");
        _writeAddress(string.concat(".implementations.", name), next);
        _verifyCore(_load(false));
        vm.writeJson('"pending"', DEPLOYMENT_FILE, ".deploymentStatus");
    }

    function _componentName(uint8 i) internal pure returns (string memory) {
        if (i == 0) return "registry";
        if (i == 1) return "ledger";
        if (i == 2) return "router";
        if (i == 3) return "lpManager";
        return "hook";
    }

    function _component(Addresses memory a, uint8 i) internal pure returns (address) {
        if (i == 0) return a.registry;
        if (i == 1) return a.ledger;
        if (i == 2) return a.router;
        if (i == 3) return a.lp;
        return a.hook;
    }

    function _participant(Addresses memory a, bool lpOperation) internal view returns (address wallet) {
        _verifyCore(a);
        string memory j = _json();
        wallet = _address(j, ".aa.wallet");
        _checkWallet(wallet, vm.addr(vm.envUint("PK")));
        require(
            TSVRegistryV1(a.registry).participantSbt() == a.sbt, "Registry uses another SBT; fresh deployment required"
        );
        require(
            IProtocolSbt(a.sbt).verify(wallet, uint256(vm.parseJsonBytes32(j, ".sbt.tokenId"))), "AA wallet lacks SBT"
        );
        require(
            TSVRegistryV1(a.registry)
                .isSbtAllowed(PermissionFlag.wrap(lpOperation ? bytes2(0x0002) : bytes2(0x0001)), wallet),
            "AA SBT operation not allowed"
        );
    }

    function _approval(address token, address spender, uint256 amount) internal pure returns (AACall memory) {
        return AACall(token, 0, abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    function swap(bool quoteToUnderlying, uint128 amountIn, uint128 minOut) public {
        require(amountIn > 0 && minOut > 0, "zero swap bounds");
        Addresses memory a = _load(true);
        address wallet = _participant(a, false);
        CorePoolKey memory k = _key(a);
        address input = quoteToUnderlying ? a.quote : a.underlying;
        require(IERC20(input).balanceOf(wallet) >= amountIn, "AA input balance too low");
        uint256 multiplier = IDirectLegalShareAdapter(a.legal).currentMultiplier(a.underlying);
        SwapRequest memory request = SwapRequest(
            k,
            quoteToUnderlying ? a.quote < a.wrapped : a.wrapped < a.quote,
            amountIn,
            minOut,
            uint64(block.timestamp + 1 hours),
            multiplier
        );
        AACall[] memory calls = new AACall[](3);
        calls[0] = _approval(input, a.router, 0);
        calls[1] = _approval(input, a.router, amountIn);
        calls[2] = AACall(a.router, 0, abi.encodeCall(TSVSwapRouterV1.swapExactInput, (request)));
        uint256 pk = vm.envUint("PK");
        vm.startBroadcast(pk);
        _submitAA(wallet, calls, pk);
        vm.stopBroadcast();
    }

    function addLiquidityAuto(uint128 underlyingMax, uint128 quoteMax, uint128 minLiquidity) public {
        Addresses memory a = _load(true);
        CorePoolKey memory k = _key(a);
        (uint160 price,,,) = StateLibrary.getSlot0(CorePoolManager(a.poolManager), k.toId());
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 aligned = tick - tick % k.tickSpacing;
        if (tick < 0 && tick % k.tickSpacing != 0) aligned -= k.tickSpacing;
        int24 radius = int24(vm.parseJsonInt(_json(), ".pool.rangeSpacings")) * k.tickSpacing;
        require(radius > 0, "invalid LP range radius");
        addLiquidity(underlyingMax, quoteMax, aligned - radius, aligned + radius, minLiquidity);
    }

    function addLiquidity(
        uint128 underlyingMax,
        uint128 quoteMax,
        int24 tickLower,
        int24 tickUpper,
        uint128 minLiquidity
    ) public {
        require(underlyingMax > 0 && quoteMax > 0 && minLiquidity > 0, "zero LP bounds");
        Addresses memory a = _load(true);
        address wallet = _participant(a, true);
        CorePoolKey memory k = _key(a);
        require(
            tickLower < tickUpper && tickLower % k.tickSpacing == 0 && tickUpper % k.tickSpacing == 0, "invalid ticks"
        );
        require(
            IERC20(a.underlying).balanceOf(wallet) >= underlyingMax && IERC20(a.quote).balanceOf(wallet) >= quoteMax,
            "AA LP balance too low"
        );
        (uint160 price,,,) = StateLibrary.getSlot0(CorePoolManager(a.poolManager), k.toId());
        uint128 amount0 = a.wrapped < a.quote ? underlyingMax : quoteMax;
        uint128 amount1 = a.wrapped < a.quote ? quoteMax : underlyingMax;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );
        require(liquidity >= minLiquidity, "LP minimum liquidity not met");
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(a.lp));
        uint256 tokenId = lp.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_lpKey(k), tickLower, tickUpper, uint256(liquidity), amount0, amount1, wallet, bytes(""));
        params[1] = abi.encode(
            Currency.wrap(CoreCurrency.unwrap(k.currency0)), Currency.wrap(CoreCurrency.unwrap(k.currency1))
        );
        AACall[] memory calls = new AACall[](5);
        calls[0] = _approval(a.underlying, a.lp, 0);
        calls[1] = _approval(a.underlying, a.lp, underlyingMax);
        calls[2] = _approval(a.quote, a.lp, 0);
        calls[3] = _approval(a.quote, a.lp, quoteMax);
        calls[4] = AACall(
            a.lp,
            0,
            abi.encodeCall(
                lp.modifyLiquidities,
                (
                    abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
                    block.timestamp + 1 hours
                )
            )
        );
        uint256 pk = vm.envUint("PK");
        vm.startBroadcast(pk);
        _submitAA(wallet, calls, pk);
        vm.stopBroadcast();
        require(
            lp.ownerOf(tokenId) == wallet && lp.getPositionLiquidity(tokenId) == liquidity, "LP mint readback mismatch"
        );
        vm.writeJson(vm.toString(tokenId), DEPLOYMENT_FILE, ".operations.positionId");
        console2.log("AA position id", tokenId);
    }

    function collect(uint256 tokenId) public {
        _remove(tokenId, 0, 0, 0);
    }

    function removeLiquidity(uint256 tokenId, uint128 amount0Min, uint128 amount1Min) public {
        Addresses memory a = _load(true);
        uint128 liquidity = TSVLPManagerV1(payable(a.lp)).getPositionLiquidity(tokenId);
        require(liquidity > 0, "empty LP");
        require(amount0Min > 0 || amount1Min > 0, "remove requires output minimum");
        _remove(tokenId, liquidity, amount0Min, amount1Min);
    }

    function _remove(uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min) internal {
        Addresses memory a = _load(true);
        address wallet = _participant(a, true);
        TSVLPManagerV1 lp = TSVLPManagerV1(payable(a.lp));
        require(lp.ownerOf(tokenId) == wallet, "AA does not own position");
        (PoolKey memory positionKey,) = lp.getPoolAndPositionInfo(tokenId);
        require(keccak256(abi.encode(positionKey)) == keccak256(abi.encode(_lpKey(_key(a)))), "position pool differs");
        uint128 beforeLiquidity = lp.getPositionLiquidity(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(positionKey.currency0, positionKey.currency1, wallet);
        AACall[] memory calls = new AACall[](1);
        calls[0] = AACall(
            a.lp,
            0,
            abi.encodeCall(
                lp.modifyLiquidities,
                (
                    abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
                    block.timestamp + 1 hours
                )
            )
        );
        uint256 pk = vm.envUint("PK");
        vm.startBroadcast(pk);
        _submitAA(wallet, calls, pk);
        vm.stopBroadcast();
        require(lp.getPositionLiquidity(tokenId) == beforeLiquidity - liquidity, "LP removal readback mismatch");
    }

    function verify() external view {
        _verifyCore(_load(false));
    }

    function _verifyCore(Addresses memory a) internal view {
        require(
            TSVRegistryV1(a.registry).hook() == a.hook && TSVRegistryV1(a.registry).lpManager() == a.lp,
            "Registry binding mismatch"
        );
        require(
            TSVRegistryV1(a.registry).permissionsAdapterFactory() == a.factory
                && TSVRegistryV1(a.registry).permissionedPoolManager() == a.poolManager,
            "factory binding mismatch"
        );
        require(address(TSVVolumeLedgerV1(a.ledger).registry()) == a.registry, "Ledger Registry mismatch");
        require(
            address(TSVSwapRouterV1(a.router).registry()) == a.registry
                && address(TSVSwapRouterV1(a.router).poolManager()) == a.poolManager
                && address(TSVSwapRouterV1(a.router).PERMISSIONS_ADAPTER_FACTORY()) == a.factory,
            "Router dependency mismatch"
        );
        require(
            address(TSVLPManagerV1(payable(a.lp)).registry()) == a.registry
                && address(TSVLPManagerV1(payable(a.lp)).poolManager()) == a.poolManager
                && address(TSVLPManagerV1(payable(a.lp)).PERMISSIONS_ADAPTER_FACTORY()) == a.factory,
            "LP dependency mismatch"
        );
        TSVHookV1 hook = TSVHookV1(a.hook);
        require(
            address(hook.registry()) == a.registry && address(hook.ledger()) == a.ledger && hook.router() == a.router
                && hook.lpManager() == a.lp && address(hook.poolManager()) == a.poolManager,
            "Hook dependencies mismatch"
        );
        require((uint160(a.hook) & 0x3fff) == 0x3fff, "Hook flag mismatch");
        require(
            IPermissionsAdapterFactory(a.factory).POOL_MANAGER() == a.poolManager
                && IPermissionsAdapterFactory(a.factory).verifiedPermissionsAdapterOf(a.wrapped) == a.underlying,
            "adapter provenance mismatch"
        );
        string memory j = _json();
        for (uint8 i; i < 5; ++i) {
            require(
                _implementation(_component(a, i)) == _address(j, string.concat(".implementations.", _componentName(i))),
                "implementation manifest mismatch"
            );
        }
    }
}
