// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig} from "tsv-v1/types/TSVTypes.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {FoundationFixture} from "../../../helpers/v1/FoundationFixture.sol";
import {V1MockToken} from "../../../helpers/v1/FoundationMocks.sol";
import {OperationsSbt, OperationsPausedOnlySbt, OperationsVerifyOnlySbt} from "../../../helpers/v1/OperationsMocks.sol";

contract TSVOperationsConfigurationTest is FoundationFixture {
    function testTierPolicyBoundsCapacityAndEvents() public {
        bytes32 beforeState = keccak256(abi.encode(registry.tierPolicy(1)));
        uint16[3] memory badBps = [uint16(0), 10001, type(uint16).max];
        for (uint256 i; i < badBps.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.setTierPolicy(1, badBps[i], 10, keccak256("invalid-bps"));
            assertEq(keccak256(abi.encode(registry.tierPolicy(1))), beforeState);
        }
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(0, 25, 10, keccak256("zero-tier"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 25, 0, keccak256("below-count"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setTierPolicy(1, 25, 10, 0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit TSVRegistryV1.TierPolicyChanged(1, 1, 1, keccak256("minimum"));
        registry.setTierPolicy(1, 1, 1, keccak256("minimum"));
        registry.setTierPolicy(1, 10000, 1, keccak256("maximum"));
        assertEq(registry.tierPolicy(1).listedCount, 1);
        assertEq(registry.tierPolicy(1).tierBps, 10000);
        registry.setTierPolicy(2, 25, 0, keccak256("closed-empty-tier"));
        assertEq(registry.tierPolicy(2).maxListed, 0);
    }

    function testSbtMustBeConfiguredAndCredentialIsSeparateFromEligibility() public {
        address owner = makeAddr("credential-owner");
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        registry.hasCredential(owner);
        vm.expectRevert(TSVRegistryV1.SbtNotConfigured.selector);
        registry.isEligible(owner);
        OperationsSbt credential = new OperationsSbt();
        credential.setCredential(owner, 7, true);
        registry.setSbtConfig(address(credential), 7, keccak256("credential"));
        assertTrue(registry.hasCredential(owner));
        assertTrue(registry.isEligible(owner));
        assertFalse(registry.hasCredential(makeAddr("nonholder")));
        credential.setPaused(true);
        assertTrue(registry.hasCredential(owner));
        assertFalse(registry.isEligible(owner));
        credential.setPaused(false);
        registry.setSbtConfig(address(credential), 8, keccak256("new-id"));
        assertFalse(registry.hasCredential(owner));
        credential.setCredential(owner, 8, true);
        assertTrue(registry.isEligible(owner));
    }

    function testEveryInvalidSbtConfigurationPreservesPreviousConfiguration() public {
        OperationsSbt good = new OperationsSbt();
        registry.setSbtConfig(address(good), 7, keccak256("good"));
        address[5] memory bad = [
            address(0),
            makeAddr("no-code-sbt"),
            address(quote),
            address(new OperationsPausedOnlySbt()),
            address(new OperationsVerifyOnlySbt())
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.setSbtConfig(bad[i], 8, keccak256("bad"));
            assertEq(address(registry.participantSbt()), address(good));
            assertEq(registry.sbtTokenId(), 7);
        }
        OperationsSbt fails = new OperationsSbt();
        fails.setFailVerify(true);
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(fails), 8, keccak256("reverting-verify"));
        vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
        registry.setSbtConfig(address(good), 8, 0);
        assertEq(address(registry.participantSbt()), address(good));
        assertEq(registry.sbtTokenId(), 7);
    }

    function testSbtReplacementEventAndMalformedReadsAreAtomic() public {
        OperationsSbt old = new OperationsSbt();
        OperationsSbt next = new OperationsSbt();
        registry.setSbtConfig(address(old), 7, keccak256("old"));
        bytes4[2] memory selectors = [ISmartWalletSbtV1.paused.selector, ISmartWalletSbtV1.verify.selector];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(address(next), abi.encodeWithSelector(selectors[i]), hex"01");
            vm.expectRevert();
            registry.setSbtConfig(address(next), 8, keccak256("malformed"));
            assertEq(address(registry.participantSbt()), address(old));
            assertEq(registry.sbtTokenId(), 7);
            vm.clearMockedCalls();
        }
        vm.expectEmit(true, true, false, true, address(registry));
        emit TSVRegistryV1.SbtConfigChanged(address(old), address(next), 7, 8, keccak256("replacement"));
        registry.setSbtConfig(address(next), 8, keccak256("replacement"));
        assertEq(address(registry.participantSbt()), address(next));
        assertEq(registry.sbtTokenId(), 8);
    }

    function testQuoteCannotCarryStockMetadataAndBadDecimalsRemainAbsent() public {
        V1MockToken token = new V1MockToken("new-quote", 6);
        TokenConfig memory good = _config(address(token), 0, address(0));
        for (uint8 fault; fault < 8; ++fault) {
            TokenConfig memory bad = abi.decode(abi.encode(good), (TokenConfig));
            if (fault == 0) bad.legalShareAdapter = address(stockAdapter);
            else if (fault == 1) bad.legalAdapterCodeHash = keccak256("adapter-code");
            else if (fault == 2) bad.legalAdapterVersion = 1;
            else if (fault == 3) bad.legalSharePolicyHash = keccak256("policy");
            else if (fault == 4) bad.poolDecimals = 18;
            else if (fault == 5) bad.poolDecimals = 19;
            else if (fault == 6) bad.poolRuntimeCodeHash = keccak256("code");
            else bad.poolCurrency = makeAddr("no-code-currency");
            vm.expectRevert(TSVRegistryV1.InvalidConfig.selector);
            registry.registerToken(bad, keccak256("invalid-quote"));
            assertEq(registry.getToken(address(token)).poolCurrency, address(0));
        }
        vm.mockCallRevert(address(token), abi.encodeWithSelector(V1MockToken.decimals.selector), "metadata unavailable");
        vm.expectRevert();
        registry.registerToken(good, keccak256("bad-decimals-read"));
        assertEq(registry.getToken(address(token)).poolCurrency, address(0));
        vm.clearMockedCalls();
        registry.registerToken(good, keccak256("retry"));
    }
}
