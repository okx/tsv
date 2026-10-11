// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PermissionedAdmission,
    UnderlyingRecord,
    MarketStatus,
    MarketAction,
    PauseScope,
    PauseMode,
    PoolLifecycle
} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";

/// @dev TSVPausesTest scenarios; inherited fixtures contain no test functions.
contract TSVPausesTest is FoundationFixture {
    function testMarketReportRejectsOutOfRangeActionBeforeStateChanges() public {
        vm.prank(address(inbox));
        (bool ok,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.applyMarketStatus.selector, SECURITY, uint8(2), PauseMode.ALL, uint64(1), bytes32(0)
                )
            );
        assertFalse(ok);
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(PauseMode.NONE));
        assertEq(registry.marketSequence(SECURITY), 0);
        _assertOperationGates(true, true);
    }

    function testRelistingRetainsMarketPauseAndReportSequence() public {
        _submitMarketMode(MarketAction.HALT, PauseMode.ALL, 1);
        _delistPrimarySecurity();
        _assertOperationGates(false, false);
        PermissionedAdmission memory another = _newStockConfig(SECURITY);
        vm.expectRevert(TSVRegistryV1.InvalidPermissionedConfig.selector);
        registry.registerPermissionedCurrency(another, 1);
        registry.relistSecurity(SECURITY);
        registry.updatePoolLifeCycle(poolId, PoolLifecycle.LIST);
        assertEq(uint8(registry.marketStatus(SECURITY)), uint8(MarketStatus.HALTED));
        assertEq(uint8(registry.marketPauseMode(SECURITY)), uint8(PauseMode.ALL));
        assertEq(registry.marketSequence(SECURITY), 1);
        assertEq(inbox.lastSequence(0, SECURITY), 1);
        _assertOperationGates(false, false);
        _submitMarketMode(MarketAction.RESUME, PauseMode.ALL, 2);
        _assertOperationGates(true, true);
    }

    /// @dev Verifies legal-share adapter replacement requires a security-wide pause.
    function testLegalAdapterReplacementRequiresSecurityPause() public {
        ERC8056DirectLegalShareAdapter replacement =
            new ERC8056DirectLegalShareAdapter(address(stockToken));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        registry.grantRole(registry.EMERGENCY_PAUSER_ROLE(), address(this));
        uint256 pauseId = registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.ALL, keccak256("replace"));
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        UnderlyingRecord memory config = registry.getUnderlying(address(stockToken));
        assertEq(config.legalShareAdapter, address(replacement));

        registry.grantRole(registry.EMERGENCY_RESUMER_ROLE(), address(this));
        registry.clearEmergencyPause(pauseId, keccak256("done"));
    }

    function testEmergencyPauseModesAcrossAllScopes() public {
        _grantPauseRoles();
        for (uint8 scope = 0; scope < 4; scope++) {
            bytes32 target = _pauseTarget(PauseScope(scope));
            for (uint8 mode = 1; mode <= 3; mode++) {
                uint256 id = registry.addEmergencyPause(PauseScope(scope), target, PauseMode(mode), keccak256("pause"));
                assertEq(registry.activePauseCount(scope, target, mode), 1);
                (PauseScope savedScope, bytes32 savedTarget, PauseMode savedMode,,,, bool active) =
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

    function testPauseCounterKeySeparatesSameTargetAcrossScopes() public {
        _grantPauseRoles();
        bytes32 sharedTarget = SECURITY;
        uint256 securityPause = registry.addEmergencyPause(
            PauseScope.SECURITY, sharedTarget, PauseMode.TRADE, keccak256("security-pause")
        );
        uint256 poolPause =
            registry.addEmergencyPause(PauseScope.POOL, sharedTarget, PauseMode.LP, keccak256("pool-pause"));

        assertEq(registry.activePauseCount(uint8(PauseScope.SECURITY), sharedTarget, uint8(PauseMode.TRADE)), 1);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), sharedTarget, uint8(PauseMode.TRADE)), 0);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), sharedTarget, uint8(PauseMode.LP)), 1);
        _assertOperationGates(false, true);

        registry.clearEmergencyPause(securityPause, keccak256("resume-security"));
        assertEq(registry.activePauseCount(uint8(PauseScope.SECURITY), sharedTarget, uint8(PauseMode.TRADE)), 0);
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), sharedTarget, uint8(PauseMode.LP)), 1);
        _assertOperationGates(true, true);

        registry.clearEmergencyPause(poolPause, keccak256("resume-pool"));
        assertEq(registry.activePauseCount(uint8(PauseScope.POOL), sharedTarget, uint8(PauseMode.LP)), 0);
    }

    function testEmergencyPauseRejectsNoneInvalidEnumsAndUnauthorizedCallers() public {
        _grantPauseRoles();
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.NONE, keccak256("pause"));
        (bool success,) = address(registry)
            .call(
                abi.encodeWithSelector(
                    TSVRegistryV1.addEmergencyPause.selector,
                    uint8(PauseScope.GLOBAL),
                    bytes32(0),
                    uint8(4),
                    keccak256("pause")
                )
            );
        assertFalse(success);
        assertEq(registry.nextPauseId(), 1);
        address stranger = makeAddr("pause-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.addEmergencyPause(PauseScope.GLOBAL, 0, PauseMode.ALL, keccak256("pause"));
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

    function testPoolPauseRecoveryPreservesOtherOperationPauses() public {
        _grantPauseRoles();
        for (uint8 mode = 1; mode <= 3; mode++) {
            uint256 globalPause = _pause(PauseScope.GLOBAL, 0, PauseMode(mode));
            uint256 poolPause = _pause(PauseScope.POOL, poolId, PauseMode.ALL);
            registry.clearEmergencyPause(poolPause, keccak256("resume-pool"));
            _assertOperationGates(mode == uint8(PauseMode.LP), mode == uint8(PauseMode.TRADE));
            registry.clearEmergencyPause(globalPause, keccak256("resume-global"));
            _assertOperationGates(true, true);
        }
    }

    function testAdapterReplacementRejectsSingleModePauseAndAllowsCombinedCoverage() public {
        _grantPauseRoles();
        uint256 trade = _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        ERC8056DirectLegalShareAdapter replacement =
            new ERC8056DirectLegalShareAdapter(address(stockToken));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        registry.clearEmergencyPause(trade, keccak256("resume"));
        _pause(PauseScope.TOKEN, _pauseTarget(PauseScope.TOKEN), PauseMode.LP);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        _pause(PauseScope.GLOBAL, 0, PauseMode.TRADE);
        _pause(PauseScope.SECURITY, SECURITY, PauseMode.LP);
        registry.replaceUnderlyingLegalShareAdapter(address(stockToken), address(replacement));
        assertEq(registry.getUnderlying(address(stockToken)).legalShareAdapter, address(replacement));
    }
}
