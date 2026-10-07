// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {AssetStatus, SwapRequest, PauseScope, PauseMode, MarketAction} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport} from "tsv-v1/types/TSVReports.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {BackedAutoFeeLegalShareAdapter} from "tsv-v1/adapters/BackedAutoFeeLegalShareAdapter.sol";
import {IAllowlistChecker} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {V1ConfigReceiver} from "../../../helpers/v1/PermissionedMocks.sol";
import {V1LocalSBT} from "../../../helpers/v1/LocalMocks.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";

/// @dev Makes the Router's user identity observable during the initial SBT validation as well as payment.
contract V1ContextCredential {
    TSVSwapRouterV1 private immutable router;
    address private immutable user;

    constructor(TSVSwapRouterV1 router_, address user_) {
        router = router_;
        user = user_;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function verify(address account, uint256) external view returns (bool) {
        return account == user && router.msgSender() == account;
    }
}

contract TSVWrappedPolicyTest is WrappedSwapFixture {
    using PoolIdLibrary for PoolKey;
    uint8 private mutation;

    function testUserIdentityIsAvailableFromFirstCredentialRead() public {
        registry.setSbtConfig(address(new V1ContextCredential(router, alice)), 1);
        _swap(true, true, 1e16);
        _swap(false, false, 1e16);
        assertEq(router.msgSender(), address(0));
    }

    function testFuzzPolicyRevocationRejectsBeforeTransfer(uint8 fault) public {
        fault = uint8(bound(fault, 0, 12));
        if (fault == 0) {
            registry.setPermissionedOwnerApproval(address(this), false);
        } else if (fault == 1) {
            V1ConfigReceiver owner = new V1ConfigReceiver();
            stock.transferOwnership(address(owner));
            owner.execute(address(stock), abi.encodeWithSignature("acceptOwnership()"));
        } else if (fault == 2) {
            stock.updateAllowListChecker(IAllowlistChecker(address(new TSVRegistryV1())));
        } else if (fault == 3) {
            stock.updateAllowedWrapper(address(router), false);
        } else if (fault == 4) {
            stock.updateAllowedHook(IHooks(address(hook)), false);
        } else if (fault == 5) {
            stock.updateSwappingEnabled(false);
        } else if (fault == 6) {
            registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
        } else if (fault == 7) {
            registry.setQuoteTokenStatus(address(quote), AssetStatus.DISABLED);
        } else if (fault == 8) {
            registry.disablePool(PoolId.unwrap(key.toId()));
        } else if (fault == 9) {
            registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.TRADE, keccak256("stop"));
        } else if (fault == 10) {
            sbt.setPaused(true);
        } else if (fault == 11) {
            sbt.setFailReads(true, false);
        } else {
            issuer.setMultiplier(0, 1); // Positive raw must not produce zero legal shares.
        }
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
        assertEq(router.msgSender(), address(0));
    }

    function testFuzzPaymentCallbackPolicyChangesRollBackWholeSwap(uint8 fault, bool stockInput) public {
        mutation = uint8(bound(fault, 0, 13));
        if (stockInput) underlying.setCallback(address(this), abi.encodeCall(this.mutatePolicy, ()));
        else quote.setCallback(address(this), abi.encodeCall(this.mutatePolicy, ()));
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(stockInput, true, 1e16);
        assertEq(_digest(), before_);
        assertEq(registry.getCurrency(address(stock)).configVersion, 1);
        assertEq(registry.getQuoteToken(address(quote)).configVersion, 1);
        assertEq(registry.getUnderlying(address(underlying)).legalAdapterVersion, 1);
        assertEq(registry.exitAdminVersion(address(stock)), 1);
        assertEq(router.msgSender(), address(0));
        underlying.setCallback(address(0), bytes(""));
        quote.setCallback(address(0), bytes(""));
        _swap(stockInput, true, 1e16); // Reverted operations leave no lock or consumed-context residue.
    }

    /// @dev A configured issuer callback exercises governance/owner mutations as the fixture Governor.
    function mutatePolicy() external {
        require(msg.sender == address(underlying) || msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        if (mutation == 0) {
            registry.setExitAdmin(address(stock), address(new V1ConfigReceiver()));
        } else if (mutation == 1) {
            registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
            registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.APPROVED);
        } else if (mutation == 2) {
            registry.setQuoteTokenStatus(address(quote), AssetStatus.DISABLED);
            registry.setQuoteTokenStatus(address(quote), AssetStatus.APPROVED);
        } else if (mutation == 3) {
            sbt.setHolder(alice, false);
        } else if (mutation == 4) {
            underlying.setDecimals(17);
        } else if (mutation == 5) {
            quote.setDecimals(17);
        } else if (mutation == 6) {
            registry.setPermissionedOwnerApproval(address(this), false);
        } else if (mutation == 7) {
            stock.updateAllowedWrapper(address(router), false);
        } else if (mutation == 8) {
            stock.updateAllowedHook(IHooks(address(hook)), false);
        } else if (mutation == 9) {
            stock.updateSwappingEnabled(false);
        } else if (mutation == 10) {
            registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.DISABLED);
            V1ConfigReceiver owner = new V1ConfigReceiver();
            registry.setPermissionedOwnerApproval(address(owner), true);
            stock.transferOwnership(address(owner));
            owner.execute(address(stock), abi.encodeWithSignature("acceptOwnership()"));
            registry.updatePermissionedExpectedOwner(address(stock), address(owner));
            registry.setPermissionedCurrencyStatus(address(stock), AssetStatus.APPROVED);
        } else if (mutation == 11) {
            uint256 pause =
                registry.addEmergencyPause(PauseScope.SECURITY, SECURITY, PauseMode.ALL, keccak256("replace"));
            BackedAutoFeeLegalShareAdapter next =
                new BackedAutoFeeLegalShareAdapter(address(issuer), address(underlying), 2);
            registry.replaceUnderlyingLegalShareAdapter(address(underlying), address(next));
            registry.clearEmergencyPause(pause, keccak256("done"));
        } else if (mutation == 12) {
            inbox.submitMarketStatus(
                MarketReport(
                    SECURITY,
                    MarketAction.HALT,
                    PauseMode.TRADE,
                    keccak256("stop"),
                    uint64(block.timestamp),
                    uint64(block.timestamp + 1),
                    1,
                    keccak256("halt")
                )
            );
            inbox.submitMarketStatus(
                MarketReport(
                    SECURITY,
                    MarketAction.RESUME,
                    PauseMode.TRADE,
                    keccak256("resume"),
                    uint64(block.timestamp),
                    uint64(block.timestamp + 1),
                    2,
                    keccak256("resume")
                )
            );
        } else {
            V1LocalSBT next = new V1LocalSBT();
            next.setHolder(alice, true);
            registry.setSbtConfig(address(next), 1);
        }
    }

    function testStockUserMustApproveRouterForUnderlying() public {
        vm.startPrank(alice);
        underlying.approve(address(router), 0);
        underlying.approve(address(stock), type(uint256).max);
        vm.stopPrank();
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(true, true, 1e16);
        assertEq(_digest(), before_);
    }

    function testExitAdminNeverReceivesSwapOutputAndIssuerCanRejectUser() public {
        underlying.setBlockedRecipient(alice);
        bytes32 before_ = _digest();
        vm.expectRevert();
        _swap(false, true, 1e16);
        assertEq(_digest(), before_);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
        underlying.setBlockedRecipient(address(0));
        _swap(false, true, 1e16);
        assertEq(underlying.balanceOf(address(exitReceiver)), 0);
    }

    function testImmutableBindingsCheckedOnInitializeAndUpgrade() public {
        TSVSwapRouterV1 mismatchedPM = new TSVSwapRouterV1(address(this), address(registry));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        _proxy(
            address(mismatchedPM),
            abi.encodeCall(
                TSVSwapRouterV1.initialize, (address(anchor), address(manager), address(registry), address(ledger))
            )
        );
        TSVSwapRouterV1 mismatchedRegistry = new TSVSwapRouterV1(address(manager), address(this));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(mismatchedRegistry), bytes(""));
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        router.upgradeToAndCall(address(mismatchedPM), bytes(""));
        TSVSwapRouterV1 next = new TSVSwapRouterV1(address(manager), address(registry));
        router.upgradeToAndCall(address(next), bytes(""));
        assertEq(address(router.poolManager()), address(manager));
        assertEq(address(router.PERMISSIONS_ADAPTER_FACTORY()), address(registry));
        _swap(true, true, 1e16);
    }
}
