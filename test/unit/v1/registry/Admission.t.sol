// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TokenConfig, TokenStatus, MarketStatus, MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {V1MockIssuerShares, V1MockIssuerWrapped} from "../../../helpers/v1/MockIssuerTokens.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken, V1SnapshotOnlyAdapterMock} from "../../../helpers/v1/FoundationMocks.sol";

/// @dev TSVAdmissionTest scenarios; inherited fixtures contain no test functions.
contract TSVAdmissionTest is FoundationFixture {
    /// @dev Verifies the Registry rejects the same security on both pool legs.
    function testRegistryRejectsSameSecurityBothSides() public {
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped secondStock = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(secondStock), 1);
        registry.registerToken(_config(address(secondStock), SECURITY, address(secondAdapter)), keccak256("second"));
        address a = address(stock) < address(secondStock) ? address(stock) : address(secondStock);
        address b = address(stock) < address(secondStock) ? address(secondStock) : address(stock);
        PoolKey memory bad = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(bad);
    }

    /// @dev Verifies the Registry accepts a direct adapter and stores its policy metadata.
    function testRegistryAcceptsDirectAdapterAndStoresPolicyMetadata() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(otherUnderlying), address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        registry.registerToken(config, keccak256("wrong-ratio"));
        TokenConfig memory stored = registry.getToken(address(other));
        assertEq(stored.securityId, SECURITY);
        assertEq(stored.legalShareAdapter, address(adapter));
        assertEq(stored.legalSharePolicyHash, config.legalSharePolicyHash);
        TokenConfig memory quoteConfig = registry.getToken(address(quote));
        assertEq(quoteConfig.securityId, bytes32(0));
        assertEq(quoteConfig.legalShareAdapter, address(0));
        assertEq(uint8(stored.status), uint8(TokenStatus.APPROVED));
        assertEq(registry.tierPolicy(1).listedCount, 1);
    }

    function testAdmissionAtomicallyListsApprovesAndDefaultsToOpen() public {
        bytes32 securityId = keccak256("new-security");
        bytes32 symbolHash = keccak256("new-symbol");
        bytes32 evidenceHash = keccak256("admission-evidence");
        TokenConfig memory config = _newStockConfig(securityId);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.SecurityListed(securityId, symbolHash, 1, evidenceHash);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.TokenRegistered(config.poolCurrency, securityId, evidenceHash);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.TokenStatusChanged(
            config.poolCurrency, uint8(TokenStatus.ABSENT), uint8(TokenStatus.APPROVED), evidenceHash
        );
        registry.admitSecurity(securityId, symbolHash, 1, config, evidenceHash);
        assertEq(keccak256(abi.encode(registry.getToken(config.poolCurrency))), keccak256(abi.encode(config)));
        assertTrue(registry.getSecurity(securityId).listed);
        assertEq(registry.getSecurity(securityId).symbolHash, symbolHash);
        assertEq(registry.getSecurity(securityId).version, 1);
        assertEq(registry.getSecurity(securityId).activePoolCount, 0);
        assertEq(registry.tierPolicy(1).listedCount, 2);
        assertEq(uint8(registry.marketStatus(securityId)), uint8(MarketStatus.OPEN));
        assertEq(uint8(registry.marketPauseMode(securityId)), uint8(PauseMode.NONE));
        assertEq(registry.marketSequence(securityId), 0);
        _assertOperationGates(true, true);
    }

    /// @dev Rejected admissions must release the symbol, Tier slot, and all partial records.
    function testFuzzAdmissionValidationFailureRollsBackAllRecords(uint8 scenario) public {
        scenario = uint8(bound(scenario, 0, 15));
        bytes32 securityId = keccak256("failed-security");
        bytes32 symbolHash = keccak256("failed-symbol");
        bytes32 evidenceHash = keccak256("evidence");
        uint8 tierId = 1;
        TokenConfig memory good = _newStockConfig(securityId);
        TokenConfig memory config = abi.decode(abi.encode(good), (TokenConfig));
        if (scenario == 0) {
            config.status = TokenStatus.ABSENT;
        } else if (scenario == 1) {
            config.status = TokenStatus.DISABLED;
        } else if (scenario == 2) {
            config.reviewHash = 0;
        } else if (scenario == 3) {
            config.legalSharePolicyHash = 0;
        } else if (scenario == 4) {
            config.poolRuntimeCodeHash = keccak256("wrong-code");
        } else if (scenario == 5) {
            config.poolDecimals = 6;
        } else if (scenario == 6) {
            config.legalAdapterVersion = 2;
        } else if (scenario == 7) {
            config.legalShareAdapter = address(stockAdapter);
            config.legalAdapterCodeHash = address(stockAdapter).codehash;
        } else if (scenario == 8) {
            config.legalShareAdapter = address(0);
        } else if (scenario == 9) {
            config.legalAdapterCodeHash = keccak256("wrong-adapter-code");
        } else if (scenario == 10) {
            config.securityId = SECURITY;
        } else if (scenario == 11) {
            config.poolCurrency = address(stock);
        } else if (scenario == 12) {
            tierId = 2;
        } else if (scenario == 13) {
            evidenceHash = 0;
        } else if (scenario == 14) {
            config.poolCurrency = address(0);
        } else {
            config.poolDecimals = 19;
        }
        bytes32 tokenBefore = keccak256(abi.encode(registry.getToken(config.poolCurrency)));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(securityId, symbolHash, tierId, config, evidenceHash);
        assertEq(registry.getSecurity(securityId).securityId, bytes32(0));
        assertEq(keccak256(abi.encode(registry.getToken(config.poolCurrency))), tokenBefore);
        assertEq(uint8(registry.getToken(good.poolCurrency).status), uint8(TokenStatus.ABSENT));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.marketSequence(securityId), 0);
        // The same symbol and security can be admitted after correcting the rejected input.
        registry.admitSecurity(securityId, symbolHash, 1, good, keccak256("corrected-evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 2);
    }

    function testAdmissionRejectsDuplicateSecurityAndSymbolAndFullTier() public {
        bytes32 newSecurity = keccak256("duplicate-test");
        TokenConfig memory config = _newStockConfig(newSecurity);
        config.securityId = SECURITY;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(SECURITY, keccak256("unused"), 1, config, keccak256("evidence"));
        config.securityId = newSecurity;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(newSecurity, keccak256("STDx"), 1, config, keccak256("evidence"));
        registry.setTierPolicy(1, 25, 1, keccak256("capacity"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.admitSecurity(newSecurity, keccak256("unused"), 1, config, keccak256("evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(newSecurity).securityId, bytes32(0));
        assertEq(uint8(registry.getToken(config.poolCurrency).status), uint8(TokenStatus.ABSENT));
        registry.setTierPolicy(1, 25, 10, keccak256("capacity-restored"));
        registry.admitSecurity(newSecurity, keccak256("unused"), 1, config, keccak256("evidence"));
    }

    function testAdmissionAndRegistrationRequireSymbolAdmin() public {
        bytes32 securityId = keccak256("unauthorized-security");
        TokenConfig memory config = _newStockConfig(securityId);
        address stranger = makeAddr("admission-stranger");
        vm.expectRevert();
        vm.prank(stranger);
        registry.admitSecurity(securityId, keccak256("symbol"), 1, config, keccak256("evidence"));
        V1MockToken otherQuote = new V1MockToken("OTHER_QUOTE", 6);
        config = _config(address(otherQuote), 0, address(0));
        vm.expectRevert();
        vm.prank(stranger);
        registry.registerToken(config, keccak256("evidence"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.getSecurity(securityId).securityId, bytes32(0));
    }

    function testQuoteRegistrationApprovesOnceAndRequiresReview() public {
        V1MockToken otherQuote = new V1MockToken("OTHER_QUOTE", 6);
        TokenConfig memory config = _config(address(otherQuote), 0, address(0));
        config.reviewHash = 0;
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("evidence"));
        config.reviewHash = keccak256("quote-review");
        registry.registerToken(config, keccak256("evidence"));
        assertEq(uint8(registry.getToken(address(otherQuote)).status), uint8(TokenStatus.APPROVED));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("duplicate"));
    }

    function testUnknownAssetsStayAbsentAndCannotCreatePools() public {
        V1MockToken unknown = new V1MockToken("UNKNOWN", 6);
        assertEq(uint8(registry.getToken(address(unknown)).status), uint8(TokenStatus.ABSENT));
        address a = address(unknown) < address(quote) ? address(unknown) : address(quote);
        address b = address(unknown) < address(quote) ? address(quote) : address(unknown);
        PoolKey memory unknownKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(unknownKey);
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(unknown), TokenStatus.APPROVED, keccak256("evidence"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.marketStatus(keccak256("unknown-security"));
        TokenConfig memory config = _newStockConfig(keccak256("unknown-security"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("evidence"));
    }

    function testTokenDisableAndReenablePreserveApprovalChecks() public {
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("noop"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.setTokenStatus(address(stock), TokenStatus.ABSENT, keccak256("absent"));
        registry.setTokenStatus(address(stock), TokenStatus.DISABLED, keccak256("disable"));
        _assertOperationGates(false, false);
        bytes memory code = address(stock).code;
        vm.etch(address(stock), hex"00");
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("changed-code"));
        assertEq(uint8(registry.getToken(address(stock)).status), uint8(TokenStatus.DISABLED));
        vm.etch(address(stock), code);
        registry.setTokenStatus(address(stock), TokenStatus.APPROVED, keccak256("reenable"));
        _assertOperationGates(true, true);
    }

    /// @dev Verifies the Registry rejects an adapter without the direct-conversion interface.
    function testRegistryRejectsAdapterWithoutDirectInterface() public {
        V1MockToken other = new V1MockToken("Other", 18);
        V1SnapshotOnlyAdapterMock adapter = new V1SnapshotOnlyAdapterMock(address(other), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("adapter-rate"));
    }

    /// @dev Verifies the Registry rejects a direct adapter bound to another Currency.
    function testRegistryRejectsDirectAdapterBoundToDifferentCurrency() public {
        V1MockIssuerShares otherUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped other = new V1MockIssuerWrapped(otherUnderlying);
        BackedAutoFeeLegalShareAdapter adapter =
            new BackedAutoFeeLegalShareAdapter(address(stockUnderlying), address(stock), 1);
        TokenConfig memory config = _config(address(other), SECURITY, address(adapter));

        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.registerToken(config, keccak256("wrong-currency"));
    }

    /// @dev Verifies a disabled pool is re-enabled only after market and asset checks pass.
    function testDisabledPoolOnlyReenablesAfterMarketAndAssetChecks() public {
        registry.disablePool(poolId, keccak256("disable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 0);
        _submitMarket(MarketAction.HALT, 1, keccak256("halt"));
        vm.expectRevert(TSVRegistryV1.InvalidStatus.selector);
        registry.enablePool(poolId, keccak256("enable"));
        _submitMarket(MarketAction.RESUME, 2, keccak256("resume"));
        registry.enablePool(poolId, keccak256("enable"));
        assertEq(registry.activePoolCountByCurrency(address(stock)), 1);
        assertTrue(registry.isTradable(poolId));
    }

    /// @dev Verifies the Registry rejects different stock securities in the same pool.
    function testRegistryRejectsDifferentSecurityStocksInSamePool() public {
        bytes32 secondSecurity = keccak256("SEC_B");
        V1MockIssuerShares secondUnderlying = new V1MockIssuerShares();
        V1MockIssuerWrapped second = new V1MockIssuerWrapped(secondUnderlying);
        BackedAutoFeeLegalShareAdapter secondAdapter =
            new BackedAutoFeeLegalShareAdapter(address(secondUnderlying), address(second), 1);
        registry.admitSecurity(
            secondSecurity,
            keccak256("STDy"),
            1,
            _config(address(second), secondSecurity, address(secondAdapter)),
            keccak256("register-b")
        );
        address a = address(stock) < address(second) ? address(stock) : address(second);
        address b = address(stock) < address(second) ? address(second) : address(stock);
        PoolKey memory twoStocks = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(this)));
        vm.expectRevert(TSVRegistryV1.InvalidPool.selector);
        registry.registerPendingPool(twoStocks);
    }
}
