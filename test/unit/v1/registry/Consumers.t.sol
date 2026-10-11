// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {
    UnderlyingRecord,
    QuoteTokenRecord,
    SecurityOperationType,
    SecurityPauseMode
} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Exercises real Hook conversion and Ledger accounting with injected PM deltas, not funded swaps.
contract TSVPermissionedConsumersTest is FoundationFixture {
    TSVHookV1 private consumerHook;

    function setUp() public override {
        super.setUp();
        address at = address(uint160(0x3FFF));
        vm.etch(at, type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            at,
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        consumerHook = TSVHookV1(at);
        // The test is the authorized Ledger writer and relays Hook accounting without mocking its result.
        consumerHook.initialize(
            address(manager), address(registry), address(this), address(permissionedRouterFixture), address(this)
        );
        _submitAdtv(1000e18);
    }

    function recordSwap(bytes32 id, int128 d0, int128 d1, uint256 s0, uint256 s1) external {
        require(msg.sender == address(consumerHook), "unexpected accounting caller");
        ledger.recordSwap(id, d0, d1, s0, s1);
    }

    function _callback(int128 stockDelta) private {
        bool stock0 = Currency.unwrap(key.currency0) == address(stock);
        BalanceDelta delta = toBalanceDelta(stock0 ? stockDelta : int128(1e6), stock0 ? int128(1e6) : stockDelta);
        vm.prank(address(manager));
        consumerHook.afterSwap(
            address(permissionedRouterFixture), key, IPoolManager.SwapParams(stock0, -1, 0), delta, bytes("")
        );
    }

    function testHookUsesUnderlyingConversionAndLedgerConsumesSecurityQuota() public {
        stockUnderlying.setMultiplier(0.9e18, 1);
        vm.expectCall(
            address(stockAdapter), abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18))
        );
        _callback(-1e18);
        assertEq(ledger.used(SECURITY, DAY), 0.9e18);
    }

    function testHookUsesReplacementAdapterAndLedgerAccountsOnce() public {
        _submitMarketMode(SecurityOperationType.HALT, SecurityPauseMode.ALL, 1);
        ERC8056DirectLegalShareAdapter next =
            new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(next));
        _submitMarketMode(SecurityOperationType.RESUME, SecurityPauseMode.ALL, 2);
        vm.expectCall(
            address(next), abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18))
        );
        vm.recordLogs();
        _callback(-1e18);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 accounted = keccak256("SwapAccounted(bytes32,bytes32,address,address,bool,uint32,uint256,uint256)");
        uint256 count;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == accounted) {
                assertEq(entries[i].emitter, address(ledger));
                assertEq(address(uint160(uint256(entries[i].topics[3]))), address(stock));
                (address recordedUnderlying,, uint32 day, uint256 raw, uint256 shares) =
                    abi.decode(entries[i].data, (address, bool, uint32, uint256, uint256));
                assertEq(recordedUnderlying, address(stockToken));
                assertEq(day, DAY);
                assertEq(raw, 1e18);
                assertEq(shares, 1e18);
                ++count;
            }
        }
        assertEq(count, 1);
    }

    function testInt128MinIsConvertedAfterWideningThenQuotaReverts() public {
        uint256 raw = uint256(1) << 127;
        vm.expectCall(
            address(stockAdapter), abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), raw))
        );
        vm.expectRevert(abi.encodeWithSelector(TSVVolumeLedgerV1.QuotaExceeded.selector, SECURITY, DAY));
        _callback(type(int128).min);
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function testLedgerRejectsUnknownAndWrongTypeQuoteFromHookAndRollsBackCharge() public {
        address q = address(quote);
        vm.mockCall(
            address(registry), abi.encodeCall(TSVRegistryV1.getQuoteToken, (q)), abi.encode(QuoteTokenRecord(6, false))
        );
        vm.expectRevert(TSVVolumeLedgerV1.InvalidLegalShareAmount.selector);
        _callback(-1e18);
        assertEq(ledger.used(SECURITY, DAY), 0);
        vm.clearMockedCalls();
        vm.mockCall(
            address(registry), abi.encodeCall(TSVRegistryV1.getCurrencyUnderlying, (q)), abi.encode(address(stockToken))
        );
        vm.expectRevert(TSVVolumeLedgerV1.InvalidLegalShareAmount.selector);
        _callback(-1e18);
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function testAfterSwapStillRequiresPoolManager() public {
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        consumerHook.afterSwap(
            address(permissionedRouterFixture), key, IPoolManager.SwapParams(true, -1, 0), toBalanceDelta(-1, 1), ""
        );
    }

    function testLedgerRejectsZeroStockDeltaFromHook() public {
        vm.expectRevert(TSVVolumeLedgerV1.ZeroSwapAmount.selector);
        _callback(0);
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function testLedgerRejectsWrongStockSecurityFromHook() public {
        UnderlyingRecord memory config = registry.getUnderlying(address(stockToken));
        config.securityId = keccak256("another-security");
        vm.mockCall(
            address(registry), abi.encodeCall(TSVRegistryV1.getUnderlying, (address(stockToken))), abi.encode(config)
        );
        vm.expectRevert(TSVVolumeLedgerV1.InvalidLegalShareAmount.selector);
        _callback(-1e18);
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function testLedgerRejectsZeroSharesReturnedByAdapter() public {
        vm.mockCall(
            address(stockAdapter),
            abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18)),
            abi.encode(uint256(0))
        );
        vm.expectRevert(TSVVolumeLedgerV1.InvalidLegalShareAmount.selector);
        _callback(-1e18);
        assertEq(ledger.used(SECURITY, DAY), 0);
    }

    function testLedgerRejectsUnregisteredQuoteIndependentlyAndRollsBackCharge() public {
        vm.mockCall(
            address(registry),
            abi.encodeCall(TSVRegistryV1.getQuoteToken, (address(quote))),
            abi.encode(QuoteTokenRecord(6, false))
        );
        bool stock0 = Currency.unwrap(key.currency0) == address(stock);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidLegalShareAmount.selector);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? 1e18 : 0,
            stock0 ? 0 : 1e18
        );
        assertEq(ledger.used(SECURITY, DAY), 0);
    }
}
