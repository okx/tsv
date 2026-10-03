// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseScope, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVPausesTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesTest is FoundationFixture {
    function testRelistingRetainsMarketPauseAndReportSequence() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        registry.disablePool(poolId, keccak256("disable"));
        registry.delistSecurity(SECURITY, keccak256("delist"));
        _assertOperationGates(false, false);
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable-token"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("delisted-token"));
        TokenConfig memory another = _newStockConfig(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(another, keccak256("delisted-security"));
        registry.relistSecurity(SECURITY, keccak256("relist"));
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("reenable-token"));
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.HALTED));
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(PauseMode.ALL));
        assertEq(registry.marketSequence(SECURITY), 1);
        assertEq(inbox.lastSequence(0, SECURITY), 1);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("still-halted"));
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 2);
        registry.enablePool(poolId, keccak256("enable"));
        _assertOperationGates(true, true);
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        assertEq(registry.getSecurity(SECURITY).activePoolCount, 1);
    }

    /// @dev Verifies legal-share adapter replacement requires a pause and the next version.
    function testLegalAdapterReplacementRequiresPauseAndNextVersion() public {
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        uint256 pauseId = registry.addEmergencyPause(
            PauseScope.TOKEN,
            bytes32(uint256(uint160(address(stock)))),
            PauseMode.ALL,
            keccak256("replace"),
            keccak256("source")
        );
        BackedAutoFeeLegalShareAdapter wrongVersion =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 3);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(wrongVersion), keccak256("review"));
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        TokenConfig memory config = registry.getToken(address(stock));
        assertEq(config.legalShareAdapter, address(replacement));
        assertEq(config.legalAdapterVersion, 2);
        assertEq(config.legalAdapterCodeHash, address(replacement).codehash);
        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.clearEmergencyPause(pauseId, keccak256("done"));
    }

    function testEmergencyPauseModesAcrossAllScopes() public {
        _grantPauseRoles();
        for (uint8 scope = 0; scope < 4; scope++) {
            bytes32 target = _pauseTarget(PauseScope(scope));
            for (uint8 mode = 1; mode <= 3; mode++) {
                uint256 id = registry.addEmergencyPause(
                    PauseScope(scope), target, PauseMode(mode), keccak256("pause"), keccak256("source")
                );
                assertEq(registry.activePauseCount(scope, target, mode), 1);
                (PauseScope savedScope, bytes32 savedTarget, PauseMode savedMode,,,,, bool active) =
                    registry.emergencyPauses(id);
                assertEq(uint8(savedScope), scope);
                assertEq(savedTarget, target);
                assertEq(uint8(savedMode), mode);
                assertTrue(active);
                _assertOperationGates(mode == uint8(PauseMode.LP), mode == uint8(PauseMode.TRADE));
                registry.clearEmergencyPause(id, keccak256("resume"));
                assertEq(registry.activePauseCount(scope, target, mode), 0);
                _assertOperationGates(true, true);
            }
        }
    }

    function testPauseEventsExposeEmergencyModeAndMarketMaskChanges() public {
        _grantPauseRoles();
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.EmergencyPauseOpened(
            1, uint8(PauseScope.POOL), poolId, uint8(PauseMode.LP), keccak256("pause")
        );
        _pause(PauseScope.POOL, poolId, PauseMode.LP);
        bytes32 reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.TRADE, uint64(2)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.OPEN),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.NONE),
            uint8(PauseMode.TRADE),
            2,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 2);
        reportId = keccak256(abi.encode("market-mode", MarketAction.HALT, PauseMode.LP, uint64(3)));
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.MarketStatusChanged(
            SECURITY,
            uint8(MarketStatus.HALTED),
            uint8(MarketStatus.HALTED),
            uint8(PauseMode.TRADE),
            uint8(PauseMode.ALL),
            3,
            reportId
        );
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 3);
    }

    function testEmergencyPauseRecordsStackAndClearIndependently() public {
        _grantPauseRoles();
        uint256 trade1 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 trade2 = _pause(PauseScope.POOL, poolId, PauseMode.TRADE);
        uint256 lp = _pause(PauseScope.GLOBAL, 0, PauseMode.LP);
        uint256 all = _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.ALL);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 2);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(all, keccak256("resume"));
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(lp, keccak256("resume"));
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(trade1, keccak256("resume"));
        _assertOperationGates(false, true);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.clearEmergencyPause(trade1, keccak256("again"));
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), poolId, uint8(PauseMode.TRADE)), 1);
        registry.clearEmergencyPause(trade2, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testEmergencyPauseRejectsNoneInvalidEnumsAndUnauthorizedCallers() public {
        _grantPauseRoles();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.NONE, keccak256("pause"), keccak256("source"));
        (bool success,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(PauseScope.GLOBAL),
                    bytes32(0),
                    uint8(4),
                    keccak256("pause"),
                    keccak256("source")
                )
            );
        assertFalse(success);
        assertEq(registry.nextPauseId(), 1);
        address stranger = makeAddr("pause-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("pause"), keccak256("source"));
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.ALL);
        vm.expectRevert();
        vm.prank(stranger);
        registry.clearEmergencyPause(id, keccak256("resume"));
        assertEq(registry.activePauseCount(uint8(PauseScope.GLOBAL), 0, uint8(PauseMode.ALL)), 1);
    }

    function testEmergencyPauseDoesNotAffectUnrelatedTargetsAndChecksBothCurrencies() public {
        _grantPauseRoles();
        _pause(PauseScope.POOL, keccak256("other-pool"), PauseMode.ALL);
        _pause(PauseScope.SECURITY, keccak256("other-security"), PauseMode.ALL);
        _pause(PauseScope.TOKEN, bytes32(uint256(uint160(makeAddr("other-token")))), PauseMode.ALL);
        _assertOperationGates(true, true);
        uint256 id = _pause(PauseScope.TOKEN, bytes32(uint256(uint160(address(quote)))), PauseMode.LP);
        _assertOperationGates(true, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
        assertFalse(registry.isTradable(keccak256("absent-pool")));
        assertFalse(registry.isLPAllowed(keccak256("absent-pool")));
    }

    function testMarketPauseModesAccumulateAndResumeIndependently() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 1);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 2);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 3);
        _assertMarketPause(PauseMode.LP, true, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 4);
        _assertMarketPause(PauseMode.NONE, true, true);
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 5);
        _submitMarketMode(MarketAction.HALT, PauseMode.TRADE, 6);
        _assertMarketPause(PauseMode.ALL, false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 7);
        _assertMarketPause(PauseMode.TRADE, false, true);
        _submitMarketMode(MarketAction.RESUME, PauseMode.TRADE, 8);
        _assertMarketPause(PauseMode.NONE, true, true);
    }

    function testMarketFirstLPPauseAllowsTrading() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 1);
        _assertMarketPause(PauseMode.LP, true, false);
    }

    function testMarketFirstAllPauseBlocksBoth() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        _assertMarketPause(PauseMode.ALL, false, false);
    }

    function testEmergencyAndMarketPauseRecoveriesAreIndependent() public {
        _grantPauseRoles();
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _assertOperationGates(false, false);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, false);
        id = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        _assertOperationGates(false, true);
        registry.clearEmergencyPause(id, keccak256("resume"));
        _assertOperationGates(true, true);
    }

    function testPoolEnableRequiresBothOperationTypesToBeUnpaused() public {
        _grantPauseRoles();
        for (uint8 mode = 1; mode <= 3; mode++) {
            uint256 id = _pause(PauseScope.GLOBAL, 0, PauseMode(mode));
            registry.disablePool(poolId, keccak256("disable"));
            uint32 version = registry.getPool(poolId).version;
            vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
            registry.enablePool(poolId, keccak256("enable"));
            assertEq(registry.getPool(poolId).version, version);
            assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
            registry.clearEmergencyPause(id, keccak256("resume"));
            registry.enablePool(poolId, keccak256("enable"));
            _assertOperationGates(true, true);
        }
        registry.disablePool(poolId, keccak256("disable"));
        _submitMarketMode(MarketAction.HALT, PauseMode.LP, 2);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarketMode(MarketAction.RESUME, PauseMode.LP, 3);
        registry.enablePool(poolId, keccak256("enable"));
    }

    function testAdapterReplacementRejectsSingleModePauseAndAllowsCombinedCoverage() public {
        _grantPauseRoles();
        uint256 trade = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        BackedAutoFeeLegalShareAdapter replacement =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 2);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        registry.clearEmergencyPause(trade, keccak256("resume"));
        _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.LP);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        registry.replaceLegalShareAdapter(address(stock), address(replacement), keccak256("review"));
        assertEq(registry.getToken(address(stock)).legalAdapterVersion, 2);
    }
}
