// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PermissionedRegisterParam, SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {AdtvReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {PermissionsAdapter} from "v4-periphery/hooks/permissionedPools/PermissionsAdapter.sol";
import {PermissionsAdapterFactory} from "v4-periphery/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {IERC20 as PermissionedIERC20} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {V1MockIssuerShares} from "./MockIssuerTokens.sol";
import {V1LocalSBT, V1TestExternalAdapter} from "./LocalMocks.sol";
import {V1ConfigReceiver, V1IssuerAllowlistChecker} from "./PermissionedMocks.sol";
import {V1SwapToken, V1WrappedLiquiditySeed} from "./WrappedSwapMocks.sol";

/// @dev No inherited test functions. Uses real PM, original Factory/W, TSV proxies and a test-only seed.
abstract contract WrappedSwapFixture is Test {
    using PoolIdLibrary for PoolKey;
    bytes32 internal constant SECURITY = keccak256("WRAPPED_STOCK");
    uint32 internal constant DAY = 20261001;
    PoolManager internal manager;
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    V1TestExternalAdapter internal swapAdapter;
    V1WrappedLiquiditySeed internal seed;
    PermissionsAdapterFactory internal factory;
    V1MockIssuerShares internal issuer;
    V1SwapToken internal underlying;
    V1SwapToken internal quote;
    PermissionsAdapter internal stock;
    ERC8056DirectLegalShareAdapter internal legalAdapter;
    V1ConfigReceiver internal exitReceiver;
    V1IssuerAllowlistChecker internal issuerChecker;
    V1LocalSBT internal sbt;
    PoolKey internal key;
    address internal alice;

    function setUp() public virtual {
        vm.warp(1_790_827_201);
        alice = makeAddr("wrapped-trader");
        manager = new PoolManager(address(this));
        registry = TSVRegistryV1(
            _proxy(address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this))))
        );
        ledger = TSVVolumeLedgerV1(
            _proxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry), uint32(14_400)))
            )
        );
        inbox = TSVDataInboxV1(
            _proxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(TSVDataInboxV1.initialize, (address(registry), address(ledger)))
            )
        );
        factory = new PermissionsAdapterFactory(address(manager));
        router = TSVSwapRouterV1(
            _proxy(
                address(new TSVSwapRouterV1(address(manager), address(factory))),
                abi.encodeCall(TSVSwapRouterV1.initialize, (address(manager), address(registry)))
            )
        );
        swapAdapter = new V1TestExternalAdapter();
        router.setAdapterAllowed(address(swapAdapter), true);
        seed = new V1WrappedLiquiditySeed(manager, registry);
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook.initialize(address(manager), address(registry), address(ledger), address(router), address(seed));
        sbt = new V1LocalSBT();
        registry.bindComponents(address(hook), address(seed), address(inbox), address(factory), address(sbt));
        ledger.bindWriters(address(hook), address(inbox));
        sbt.setHolder(alice, 1, true);
        registry.setSbtConfig(1, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
        registry.setSbtConfig(2, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
        registry.grantRole(registry.SYMBOL_ADMIN_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.setTierPolicy(1, 10_000, 10);
        registry.grantRole(inbox.VOLUME_ORACLE_ROLE(), address(this));
        registry.grantRole(inbox.HALT_REPORTER_ROLE(), address(this));
        issuer = new V1MockIssuerShares();
        underlying = new V1SwapToken("STOCK_U", 18, address(issuer));
        quote = new V1SwapToken("QUOTE_Q", _quoteDecimals(), address(0));
        legalAdapter = new ERC8056DirectLegalShareAdapter(address(underlying));
        exitReceiver = new V1ConfigReceiver();
        issuerChecker = new V1IssuerAllowlistChecker();
        stock = _newWrapper();
        registry.registerPermissionedCurrency(PermissionedRegisterParam(address(stock), SECURITY, address(legalAdapter)), 1);
        registry.registerQuoteToken(address(quote));
        underlying.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        underlying.approve(address(seed), type(uint256).max);
        quote.approve(address(seed), type(uint256).max);
        key = _seedPool(stock, 3000);
        underlying.mint(alice, 1e24);
        quote.mint(alice, 1e24);
        vm.startPrank(alice);
        underlying.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        vm.stopPrank();
        inbox.submitAdtv(
            AdtvReport(
                SECURITY,
                202609,
                1000e18,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 100),
                1,
                keccak256("wrapped-adtv")
            )
        );
        stock.updateSwappingEnabled(true);
    }

    function _quoteDecimals() internal pure virtual returns (uint8) {
        return 18;
    }

    function _initialPrice(PoolKey memory) internal view virtual returns (uint160) {
        return uint160(1 << 96);
    }

    function _seedRange(PoolKey memory) internal view virtual returns (int24, int24) {
        return (-600, 600);
    }

    function _newWrapper() internal returns (PermissionsAdapter w) {
        w = PermissionsAdapter(
            factory.createPermissionsAdapter(
                PermissionedIERC20(address(underlying)), address(this), IAllowlistChecker(address(issuerChecker))
            )
        );
        w.updateAllowedWrapper(address(router), true);
        w.updateAllowedWrapper(address(seed), true); // Explicitly test-only.
        w.updateAllowedHook(IHooks(address(hook)), true);
        underlying.mint(address(w), 17); // Verification dust must survive all swaps.
        factory.verifyPermissionsAdapter(address(w));
    }

    function _seedPool(PermissionsAdapter w, uint24 fee) internal returns (PoolKey memory result) {
        address a = address(w) < address(quote) ? address(w) : address(quote);
        address b = address(w) < address(quote) ? address(quote) : address(w);
        result = PoolKey(Currency.wrap(a), Currency.wrap(b), fee, 60, IHooks(address(hook)));
        seed.initializePool(result, _initialPrice(result));
        (int24 lower, int24 upper) = _seedRange(result);
        seed.seed(result, lower, upper, 1e20);
    }

    function _request(bool stockInput, uint128 amount) internal view returns (SwapRequest memory) {
        return SwapRequest(
            key,
            stockInput == (Currency.unwrap(key.currency0) == address(stock)),
            amount,
            1,
            uint64(block.timestamp + 100),
            issuer.multiplier()
        );
    }

    function _swap(bool stockInput, uint128 amount) internal returns (uint256, uint256) {
        // Keep request view calls inside the transaction observed by expectRevert.
        return this.executeSwap(stockInput, amount);
    }

    function executeSwap(bool stockInput, uint128 amount) external returns (uint256, uint256) {
        require(msg.sender == address(this));
        return _submitSwap(_request(stockInput, amount));
    }

    function _submitSwap(SwapRequest memory request) internal returns (uint256, uint256) {
        return swapAdapter.swapExactInputDirect(router, request, alice, alice);
    }

    function _inventory() internal view returns (uint256) {
        return underlying.balanceOf(address(stock)) - stock.totalSupply();
    }

    function _digest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolDigest(),
                stock.totalSupply(),
                stock.balanceOf(address(manager)),
                underlying.balanceOf(address(stock)),
                underlying.balanceOf(alice),
                quote.balanceOf(alice),
                underlying.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                underlying.balanceOf(address(router)),
                quote.balanceOf(address(router)),
                ledger.used(SECURITY, DAY)
            )
        );
    }

    function _poolDigest() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthGlobals(manager, key.toId());
        return keccak256(
            abi.encode(
                price, tick, protocolFee, lpFee, growth0, growth1, StateLibrary.getLiquidity(manager, key.toId())
            )
        );
    }

    function _proxy(address implementation, bytes memory init) internal returns (address) {
        return address(new TSVERC1967Proxy(implementation, init));
    }
}
