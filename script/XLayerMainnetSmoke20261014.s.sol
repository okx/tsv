// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC8056TestToken} from "../lib/TestToken/erc8056/ERC8056TestToken.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {PermissionedRegisterParam} from "tsv-v1/types/TSVTypes.sol";
import {PermissionFlag} from "tsv-v1/vendor/permissionedPools/libraries/PermissionFlags.sol";
import {IPermissionsAdapterFactory} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC20 as VendorIERC20} from "tsv-v1/vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "tsv-v1/vendor/permissionedPools/interfaces/IAllowlistChecker.sol";
import {
    PoolKey,
    Currency,
    IHooks,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "tsv-v1/vendor/permissionedPools/PermissionedPositionManager.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";

interface ISmokePermissionsAdapter {
    function owner() external view returns (address);
    function updateAllowedWrapper(address wrapper, bool allowed) external;
    function updateAllowedHook(address hook, bool allowed) external;
    function updateSwappingEnabled(bool enabled) external;
}

/// @dev Test-only credential bound to the deploying account. No mutable issuer controls.
contract XLayerMainnetSmokeSbt {
    address public immutable holder;

    constructor(address holder_) {
        holder = holder_;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function verify(address account, uint256 tokenId) external view returns (bool) {
        return account == holder && tokenId == 1;
    }
}

/// @dev Fresh TSV proxy topology for a mock ERC-8056 / real X Layer USDT smoke pool.
///      Run without --verify; do not publish contract source or broadcast metadata.
contract XLayerMainnetSmoke20261014 is Script {
    address private constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address private constant FACTORY = 0x038B77f3355AFE8AEA10C6C2B7be9312d8148e3f;
    address private constant HOOK_FACTORY = 0x3c3e76F4beB314713901183ED6E511928e1d2A99;
    address private constant ALLOW_ALL_CHECKER = 0xb4110157542283aECAcB7483b7029D2216507525;
    address private constant USDT = 0x1E4a5963aBFD975d8c9021ce480b42188849D41d;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant DESCRIPTOR = 0x9e9FBbEf0e1Bd752E83De5aCff3D0c936A9E5A4b;
    address private constant WETH9 = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    bytes32 private constant SECURITY_ID = keccak256("TSV_XLAYER_MOCK8056_SMOKE_20261014");
    bytes32 private constant REASON = bytes32("XLAYER_SMOKE_20261014");

    function run() external {
        uint256 key = vm.envUint("PK");
        address deployer = vm.addr(key);
        require(block.chainid == 196, "wrong chain");
        require(deployer.balance >= 0.01 ether, "insufficient OKB");
        require(IERC20Metadata(USDT).decimals() == 6, "wrong USDT decimals");
        require(keccak256(bytes(IERC20Metadata(USDT).symbol())) == keccak256("USDT"), "wrong quote");
        require(IPermissionsAdapterFactory(FACTORY).POOL_MANAGER() == POOL_MANAGER, "wrong factory");
        require(HOOK_FACTORY.code.length != 0 && ALLOW_ALL_CHECKER.code.length != 0, "missing dependency");

        vm.startBroadcast(key);

        ERC8056TestToken underlying = ERC8056TestToken(vm.envAddress("MOCK_8056_TOKEN"));
        require(address(underlying).code.length != 0, "missing mock 8056 token");
        require(underlying.owner() == deployer, "mock 8056 owner mismatch");
        require(underlying.balanceOf(deployer) >= 1 ether, "mock 8056 balance too low");
        ERC8056DirectLegalShareAdapter legalAdapter = new ERC8056DirectLegalShareAdapter(address(underlying));
        address wrapped = IPermissionsAdapterFactory(FACTORY)
            .createPermissionsAdapter(VendorIERC20(address(underlying)), deployer, IAllowlistChecker(ALLOW_ALL_CHECKER));
        require(underlying.transfer(wrapped, 1), "verification deposit");
        IPermissionsAdapterFactory(FACTORY).verifyPermissionsAdapter(wrapped);
        require(
            IPermissionsAdapterFactory(FACTORY).verifiedPermissionsAdapterOf(wrapped) == address(underlying),
            "unverified wrapped token"
        );

        TSVRegistryV1 registryImpl = new TSVRegistryV1();
        TSVRegistryV1 registry = TSVRegistryV1(
            address(new TSVERC1967Proxy(address(registryImpl), abi.encodeCall(TSVRegistryV1.initialize, (deployer))))
        );
        TSVVolumeLedgerV1 ledgerImpl = new TSVVolumeLedgerV1();
        TSVVolumeLedgerV1 ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    address(ledgerImpl), abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry)))
                )
            )
        );
        TSVSwapRouterV1 routerImpl = new TSVSwapRouterV1(POOL_MANAGER, FACTORY);
        TSVSwapRouterV1 router = TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    address(routerImpl), abi.encodeCall(TSVSwapRouterV1.initialize, (POOL_MANAGER, address(registry)))
                )
            )
        );
        TSVLPManagerV1 lpImpl = new TSVLPManagerV1(
            IPoolManager(POOL_MANAGER),
            IAllowanceTransfer(PERMIT2),
            200_000,
            IPositionDescriptor(DESCRIPTOR),
            IWETH9(WETH9),
            IPermissionsAdapterFactory(FACTORY),
            500_000
        );
        TSVLPManagerV1 lp = TSVLPManagerV1(
            payable(address(
                    new TSVERC1967Proxy(
                        address(lpImpl),
                        abi.encodeCall(TSVLPManagerV1.initialize, (ITSVPermissionedRegistry(address(registry))))
                    )
                ))
        );

        TSVHookV1 hookImpl = new TSVHookV1();
        bytes memory hookInit = abi.encodeCall(
            TSVHookV1.initialize, (POOL_MANAGER, address(registry), address(ledger), address(router), address(lp))
        );
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(TSVERC1967Proxy).creationCode, abi.encode(address(hookImpl), hookInit)));
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), HOOK_FACTORY, salt, initCodeHash)))));
            if ((uint160(predicted) & 0x3fff) == 0x3fff) break;
        }
        require((uint160(predicted) & 0x3fff) == 0x3fff, "hook salt not found");
        address hook = TSVHookProxyFactoryV1(HOOK_FACTORY).deploy(address(hookImpl), hookInit, salt);
        require(hook == predicted, "hook prediction mismatch");

        XLayerMainnetSmokeSbt sbt = new XLayerMainnetSmokeSbt(deployer);
        registry.bindComponents(hook, address(lp), FACTORY, address(sbt));
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), deployer);
        registry.grantRole(registry.POOL_CREATOR_ROLE(), deployer);
        registry.grantRole(registry.VOLUME_ORACLE_ROLE(), deployer);
        registry.setSbtConfig(1, PermissionFlag.wrap(0x0003), REASON);
        registry.setTierPolicy(1, 1, REASON);
        registry.registerPermissionedCurrency(
            PermissionedRegisterParam(wrapped, SECURITY_ID, address(legalAdapter)), 1, REASON
        );
        registry.registerQuoteToken(USDT, REASON);
        ledger.setQuota(SECURITY_ID, 1 ether, REASON);

        ISmokePermissionsAdapter(wrapped).updateAllowedWrapper(address(router), true);
        ISmokePermissionsAdapter(wrapped).updateAllowedWrapper(address(lp), true);
        ISmokePermissionsAdapter(wrapped).updateAllowedHook(hook, true);
        ISmokePermissionsAdapter(wrapped).updateSwappingEnabled(true);

        bool stockIsCurrency0 = wrapped < USDT;
        PoolKey memory pool = PoolKey(
            Currency.wrap(stockIsCurrency0 ? wrapped : USDT),
            Currency.wrap(stockIsCurrency0 ? USDT : wrapped),
            3000,
            60,
            IHooks(hook)
        );
        uint160 sqrtPriceX96 = stockIsCurrency0
            ? uint160(79_228_162_514_264_337_593_543)
            : uint160(79_228_162_514_264_337_593_543_950_336_000_000);
        lp.initializePool(pool, sqrtPriceX96);

        vm.stopBroadcast();
        console2.log("deployer", deployer);
        console2.log("underlying", address(underlying));
        console2.log("wrapped", wrapped);
        console2.log("legal adapter", address(legalAdapter));
        console2.log("registry", address(registry));
        console2.log("ledger", address(ledger));
        console2.log("router", address(router));
        console2.log("lp manager", address(lp));
        console2.log("hook", hook);
        console2.log("sbt", address(sbt));
    }
}
