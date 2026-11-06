// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SecurityPauseMode} from "tsv-v1/types/TSVTypes.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Exercises real Hook conversion and Ledger accounting with injected PM deltas, not funded swaps.
contract TSVPermissionedConsumersTest is FoundationFixture {
    function testActualStockOutputDeltaIsChargedForBuyDirection() public {
        _callback(2e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 2e18);
    }

    function testSwapSnapshotsAreMandatoryAndStaleValuesRejectBeforeAccounting() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(true, -1, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(TSVHookV1.InvalidMultiplierSnapshot.selector);
        consumerHook.afterSwap(address(permissionedRouterFixture), key, params, toBalanceDelta(-1, 1), "");
        vm.expectRevert(TSVHookV1.InvalidMultiplierSnapshot.selector);
        consumerHook.afterSwap(address(permissionedRouterFixture), key, params, toBalanceDelta(-1, 1), hex"01");
        vm.expectRevert(TSVHookV1.MultiplierChanged.selector);
        consumerHook.afterSwap(
            address(permissionedRouterFixture), key, params, toBalanceDelta(-1, 1), abi.encode(uint256(2e18))
        );
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        consumerHook.afterSwap(address(this), key, params, toBalanceDelta(-1, 1), abi.encode(uint256(1e18)));
        vm.stopPrank();
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

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
        _submitQuota(1000e18);
    }

    function recordSwap(bytes32 id, int128 d0, int128 d1, uint256 s0, uint256 s1) external {
        require(msg.sender == address(consumerHook), "unexpected accounting caller");
        ledger.recordSwap(id, d0, d1, s0, s1);
    }

    function _callback(int128 stockDelta) private {
        this.executeCallback(stockDelta);
    }

    function executeCallback(int128 stockDelta) external {
        require(msg.sender == address(this));
        bool stock0 = Currency.unwrap(key.currency0) == address(stock);
        int128 quoteDelta = stockDelta < 0 ? int128(1e6) : int128(-1e6);
        BalanceDelta delta = toBalanceDelta(stock0 ? stockDelta : quoteDelta, stock0 ? quoteDelta : stockDelta);
        bytes memory snapshot = abi.encode(stockUnderlying.multiplier());
        vm.prank(address(manager));
        consumerHook.afterSwap(
            address(permissionedRouterFixture), key, IPoolManager.SwapParams(stock0, -1, 0), delta, snapshot
        );
    }

    function testHookUsesUnderlyingConversionAndLedgerConsumesSecurityQuota() public {
        stockUnderlying.setMultiplier(0.9e18, 1);
        vm.expectCall(
            address(stockAdapter), abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18))
        );
        _callback(-1e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 0.9e18);
    }

    function testHookUsesReplacementAdapterAndLedgerAccountsOnce() public {
        _setSecurityMode(SecurityPauseMode.ALL, true);
        ERC8056DirectLegalShareAdapter next = new ERC8056DirectLegalShareAdapter(address(stockToken));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(next), bytes32("TEST"));
        _setSecurityMode(SecurityPauseMode.ALL, false);
        vm.expectCall(
            address(next), abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18))
        );
        vm.recordLogs();
        _callback(-1e18);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(ledger)
                    && entries[i].topics[0] == keccak256("VolumeUsed(bytes32,bytes32,uint256,uint256)")
            ) {
                assertEq(entries[i].topics[1], SECURITY);
                assertEq(entries[i].topics[2], poolId);
                assertEq(uint256(entries[i].topics[3]), DAY);
                assertEq(abi.decode(entries[i].data, (uint256)), 1e18);
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
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testDisabledQuotePoolRegisterDoesNotBreakExistingPoolAccounting() public {
        registry.disableQuoteTokenPoolRegister(address(quote), bytes32("TEST"));
        _callback(-1e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 1e18);
    }

    function testHookRejectsTwoStockLegsBeforeAccounting() public {
        vm.mockCall(
            address(registry),
            abi.encodeCall(TSVRegistryV1.getCurrencyUnderlying, (address(quote))),
            abi.encode(address(stockToken))
        );
        vm.expectRevert(TSVHookV1.InvalidPool.selector);
        _callback(-1e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testAfterSwapStillRequiresPoolManager() public {
        vm.expectRevert(TSVHookV1.UnauthorizedCallback.selector);
        consumerHook.afterSwap(
            address(permissionedRouterFixture), key, IPoolManager.SwapParams(true, -1, 0), toBalanceDelta(-1, 1), ""
        );
    }

    function testLedgerRejectsZeroStockDeltaFromHook() public {
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        _callback(0);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testLedgerRejectsZeroSharesReturnedByAdapter() public {
        vm.mockCall(
            address(stockAdapter),
            abi.encodeCall(IDirectLegalShareAdapter.toLegalShares, (address(stockToken), 1e18)),
            abi.encode(uint256(0))
        );
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        _callback(-1e18);
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }

    function testLedgerRejectsUnknownPoolAndRollsBackCharge() public {
        bool stock0 = Currency.unwrap(key.currency0) == address(stock);
        vm.expectRevert(TSVVolumeLedgerV1.InvalidInput.selector);
        ledger.recordSwap(
            keccak256("unknown-pool"),
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? 1e18 : 0,
            stock0 ? 0 : 1e18
        );
        assertEq(ledger.usedWad(SECURITY, DAY), 0);
    }
}
