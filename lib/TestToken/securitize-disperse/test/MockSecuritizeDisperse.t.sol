// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockSecuritizeDisperse} from "../MockSecuritizeDisperse.sol";

contract DisperseTestToken is ERC20 {
    address public blocked;
    bool public chargeFee;

    error BlockedRecipient();

    constructor() ERC20("Test payout", "PAY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account) external {
        blocked = account;
    }

    function setChargeFee(bool enabled) external {
        chargeFee = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (to != address(0) && to == blocked) revert BlockedRecipient();
        if (chargeFee && from != address(0) && to != address(0) && amount > 0) {
            super._update(from, address(0), 1);
            --amount;
        }
        super._update(from, to, amount);
    }
}

contract MockSecuritizeDisperseTest is Test {
    MockSecuritizeDisperse internal disperse;
    DisperseTestToken internal token;
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000);
        disperse = new MockSecuritizeDisperse(address(this));
        token = new DisperseTestToken();
        disperse.addOperator(operator);
        _fundAndApprove(operator);
    }

    function _fundAndApprove(address account) internal {
        token.mint(account, 1_000_000);
        vm.prank(account);
        token.approve(address(disperse), type(uint256).max);
    }

    function _batch() internal view returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](2);
        amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 100;
        amounts[1] = 200;
    }

    function _pay(address[] memory recipients, uint256[] memory amounts) internal {
        vm.prank(operator);
        disperse.disperseToken(address(token), recipients, amounts);
    }

    function testPaysEveryEntryAndEmitsExactDocumentedEvents() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        bytes32 id = keccak256(abi.encode(address(token), recipients, amounts));
        assertEq(disperse.batchHash(address(token), recipients, amounts), id);
        vm.recordLogs();
        _pay(recipients, amounts);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 entry;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(disperse)) continue;
            if (entry < 2) {
                assertEq(logs[i].topics.length, 3);
                assertEq(logs[i].topics[0], keccak256("Paid(address,address,uint256)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(token)))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(recipients[entry]))));
                assertEq(logs[i].data, abi.encode(amounts[entry]));
            } else {
                assertEq(logs[i].topics.length, 4);
                assertEq(logs[i].topics[0], keccak256("Dispersed(address,address,uint256,uint256,bytes32)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(token)))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(operator))));
                assertEq(logs[i].topics[3], id);
                assertEq(logs[i].data, abi.encode(uint256(300), uint256(2)));
            }
            ++entry;
        }
        assertEq(entry, 3);
        assertEq(token.balanceOf(operator), 999_700);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 200);
        assertEq(token.balanceOf(address(disperse)), 0);
        assertEq(disperse.lastDispersedAt(id), 1_000);
    }

    function testRejectsDuplicateUntilExactlyTenMinutesAndResetsWindow() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        bytes32 id = disperse.batchHash(address(token), recipients, amounts);
        assertEq(disperse.DUPLICATE_WINDOW(), 600);
        _pay(recipients, amounts);
        vm.warp(1_599);
        vm.expectRevert(abi.encodeWithSelector(MockSecuritizeDisperse.DuplicateBatch.selector, id, uint256(1_000)));
        _pay(recipients, amounts);
        vm.warp(1_600);
        _pay(recipients, amounts);
        assertEq(disperse.lastDispersedAt(id), 1_600);
        vm.warp(2_199);
        vm.expectRevert(abi.encodeWithSelector(MockSecuritizeDisperse.DuplicateBatch.selector, id, uint256(1_600)));
        _pay(recipients, amounts);
        assertEq(token.balanceOf(alice), 200);
    }

    function testDuplicateProtectionIsSharedAcrossOperators() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        _pay(recipients, amounts);
        disperse.addOperator(alice);
        _fundAndApprove(alice);
        bytes32 id = disperse.batchHash(address(token), recipients, amounts);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSecuritizeDisperse.DuplicateBatch.selector, id, uint256(1_000)));
        disperse.disperseToken(address(token), recipients, amounts);
    }

    function testArrayOrderChangesBatchHash() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        bytes32 first = disperse.batchHash(address(token), recipients, amounts);
        _pay(recipients, amounts);
        (recipients[0], recipients[1]) = (recipients[1], recipients[0]);
        (amounts[0], amounts[1]) = (amounts[1], amounts[0]);
        assertNotEq(disperse.batchHash(address(token), recipients, amounts), first);
        _pay(recipients, amounts);
        assertEq(token.balanceOf(alice), 200);
    }

    function testRecipientFailureRollsBackWholeBatchAndAllowsImmediateRetry() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        bytes32 id = disperse.batchHash(address(token), recipients, amounts);
        token.setBlocked(bob);
        vm.expectRevert(DisperseTestToken.BlockedRecipient.selector);
        _pay(recipients, amounts);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(operator), 1_000_000);
        assertEq(token.balanceOf(address(disperse)), 0);
        assertEq(disperse.lastDispersedAt(id), 0);
        token.setBlocked(address(0));
        _pay(recipients, amounts);
        assertEq(token.balanceOf(bob), 200);
    }

    function testRejectsFeeOnTransferAndCanRetryAfterFeeDisabled() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        token.setChargeFee(true);
        vm.expectRevert(
            abi.encodeWithSelector(MockSecuritizeDisperse.AmountMismatch.selector, uint256(300), uint256(299))
        );
        _pay(recipients, amounts);
        assertEq(token.balanceOf(operator), 1_000_000);
        token.setChargeFee(false);
        _pay(recipients, amounts);
    }

    function testApprovalIsRequiredEvenWhenContractHasEnoughTokens() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        token.mint(address(disperse), 300);
        vm.prank(operator);
        token.approve(address(disperse), 0);
        vm.expectRevert();
        _pay(recipients, amounts);
        assertEq(token.balanceOf(address(disperse)), 300);
        assertEq(token.balanceOf(alice), 0);
    }

    function testExistingAccidentalBalanceIsPreservedAndAdminCanRescueIt() public {
        token.mint(address(disperse), 7);
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        _pay(recipients, amounts);
        assertEq(token.balanceOf(address(disperse)), 7);
        vm.expectEmit(true, true, true, true, address(disperse));
        emit MockSecuritizeDisperse.Rescued(address(token), alice, 7, address(this));
        disperse.rescue(address(token), alice, 7);
        assertEq(token.balanceOf(address(disperse)), 0);
        assertEq(token.balanceOf(alice), 107);
    }

    function testDuplicateRecipientsAreSeparatePayoutEntries() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        recipients[1] = alice;
        _pay(recipients, amounts);
        assertEq(token.balanceOf(alice), 300);
    }

    function testRejectsInvalidBatches() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        vm.expectRevert(MockSecuritizeDisperse.EmptyBatch.selector);
        _pay(new address[](0), new uint256[](0));
        vm.expectRevert(MockSecuritizeDisperse.ArrayLengthMismatch.selector);
        _pay(recipients, new uint256[](1));
        vm.expectRevert(MockSecuritizeDisperse.BatchTooLarge.selector);
        _pay(new address[](201), new uint256[](201));
        recipients[1] = address(0);
        vm.expectRevert(MockSecuritizeDisperse.ZeroAddressInvalid.selector);
        _pay(recipients, amounts);
        recipients[1] = address(disperse);
        vm.expectRevert(abi.encodeWithSelector(MockSecuritizeDisperse.InvalidRecipient.selector, address(disperse)));
        _pay(recipients, amounts);
        recipients[1] = bob;
        amounts[1] = 0;
        vm.expectRevert(MockSecuritizeDisperse.ZeroAmount.selector);
        _pay(recipients, amounts);
        vm.prank(operator);
        vm.expectRevert(MockSecuritizeDisperse.ZeroAddressInvalid.selector);
        disperse.disperseToken(address(0), recipients, amounts);
    }

    function testAcceptsMaximumBatch() public {
        address[] memory recipients = new address[](200);
        uint256[] memory amounts = new uint256[](200);
        for (uint256 i; i < 200; ++i) {
            recipients[i] = address(uint160(0x10000 + i));
            amounts[i] = 1;
        }
        _pay(recipients, amounts);
        assertEq(token.balanceOf(operator), 999_800);
        assertEq(token.balanceOf(address(disperse)), 0);
    }

    function testAdminNeedsSeparateOperatorRoleAndOperatorCannotAdminister() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        assertTrue(disperse.isAdmin(address(this)));
        assertFalse(disperse.isOperator(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), disperse.OPERATOR_ROLE()
            )
        );
        disperse.disperseToken(address(token), recipients, amounts);
        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, bytes32(0))
        );
        disperse.addOperator(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, bytes32(0))
        );
        disperse.rescue(address(token), bob, 1);
        vm.stopPrank();
    }

    function testGenericOperatorGrantAndDedicatedRevocationEmitDomainEvents() public {
        bytes32 role = disperse.OPERATOR_ROLE();
        vm.expectEmit(true, false, false, true, address(disperse));
        emit MockSecuritizeDisperse.OperatorAdded(alice);
        disperse.grantRole(role, alice);
        vm.expectRevert(MockSecuritizeDisperse.UseRevokeOperator.selector);
        disperse.revokeRole(role, alice);
        vm.prank(alice);
        vm.expectRevert(MockSecuritizeDisperse.UseRevokeOperator.selector);
        disperse.renounceRole(role, alice);
        vm.expectEmit(true, false, false, true, address(disperse));
        emit MockSecuritizeDisperse.OperatorRevoked(alice);
        disperse.revokeOperator(alice);
        assertFalse(disperse.isOperator(alice));
    }

    function testAdminDomainEventsCoverGenericGrantRevokeAndRenounce() public {
        vm.expectEmit(true, false, false, true, address(disperse));
        emit MockSecuritizeDisperse.AdminGranted(alice);
        disperse.grantRole(bytes32(0), alice);
        vm.expectEmit(true, false, false, true, address(disperse));
        emit MockSecuritizeDisperse.AdminRevoked(alice);
        disperse.revokeRole(bytes32(0), alice);
        disperse.grantRole(bytes32(0), alice);
        vm.expectEmit(true, false, false, true, address(disperse));
        emit MockSecuritizeDisperse.AdminRevoked(alice);
        vm.prank(alice);
        disperse.renounceRole(bytes32(0), alice);
        assertFalse(disperse.isAdmin(alice));
    }

    function testChangeAdminKeepsOtherAdminsAndRejectsSelfAndZero() public {
        disperse.grantRole(bytes32(0), bob);
        vm.expectRevert(MockSecuritizeDisperse.CannotTransferAdminToSelf.selector);
        disperse.changeAdmin(address(this));
        vm.expectRevert(MockSecuritizeDisperse.ZeroAddressInvalid.selector);
        disperse.changeAdmin(address(0));
        disperse.changeAdmin(alice);
        assertFalse(disperse.isAdmin(address(this)));
        assertTrue(disperse.isAdmin(alice));
        assertTrue(disperse.isAdmin(bob));
    }

    function testZeroAdminAndZeroOperatorAreRejected() public {
        vm.expectRevert(MockSecuritizeDisperse.ZeroAddressInvalid.selector);
        new MockSecuritizeDisperse(address(0));
        vm.expectRevert(MockSecuritizeDisperse.ZeroAddressInvalid.selector);
        disperse.addOperator(address(0));
    }

    function testDuplicateAtTimestampZeroIsStillRejected() public {
        vm.warp(0);
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        bytes32 id = disperse.batchHash(address(token), recipients, amounts);
        _pay(recipients, amounts);
        vm.expectRevert(abi.encodeWithSelector(MockSecuritizeDisperse.DuplicateBatch.selector, id, uint256(0)));
        _pay(recipients, amounts);
    }

    function testFuzzConservesFunds(uint64 first, uint64 second) public {
        (address[] memory recipients, uint256[] memory amounts) = _batch();
        amounts[0] = bound(uint256(first), 1, 100_000);
        amounts[1] = bound(uint256(second), 1, 100_000);
        _pay(recipients, amounts);
        assertEq(token.balanceOf(alice), amounts[0]);
        assertEq(token.balanceOf(bob), amounts[1]);
        assertEq(token.balanceOf(operator) + token.balanceOf(alice) + token.balanceOf(bob), 1_000_000);
        assertEq(token.balanceOf(address(disperse)), 0);
    }
}
