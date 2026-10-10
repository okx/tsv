// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {WrappedSwapFixture} from "../../../helpers/v1/WrappedSwapFixture.sol";
import {TSVAdapterFixture} from "../../../helpers/v1/TSVAdapterFixture.sol";
import {TSVAdapter} from "dex-adapters/adapters/uniswap-v4/TSVAdapter.sol";
import {CallerAuth} from "dex-adapters/libraries/CallerAuth.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";

/// @dev Reproduces the existing DexRouter callback ABI and authenticated trailers.
contract TestDexCallbackCaller {
    function execute(address adapter, bytes calldata data) external {
        (bool ok, bytes memory result) = adapter.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

contract TSVDexAdapterTest is WrappedSwapFixture, TSVAdapterFixture {
    TestDexCallbackCaller internal caller;
    TSVAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        caller = new TestDexCallbackCaller();
        adapter = new TSVAdapter(address(router), vm.addr(TEST_AUTH_KEY));
        router.setAdapterAllowed(address(adapter), true);
    }

    function testUntrustedCallerCannotSpoofAuthenticatedParticipantMarker() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice);
        vm.prank(alice);
        (bool ok, bytes memory data) = address(adapter).call(payload);
        assertFalse(ok);
        assertEq(bytes4(data), CallerAuth.AUTH_UntrustedCaller.selector);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testMalformedLengthPrefixAndZeroParticipantRejectBeforeFunding() public {
        bytes memory route = _adapterRoute(adapter, address(caller), key);
        bytes memory canonical = abi.encodeCall(TSVAdapter.sellBase, (alice, address(router), route));
        vm.expectRevert(TSVAdapter.InvalidTrailer.selector);
        caller.execute(address(adapter), canonical);
        vm.expectRevert(TSVAdapter.InvalidTrailer.selector);
        caller.execute(address(adapter), abi.encodePacked(canonical, uint256(1e18), uint256(uint160(alice))));
        vm.expectRevert(TSVAdapter.InvalidTrailer.selector);
        caller.execute(
            address(adapter),
            abi.encodePacked(_adapterPayload(true, alice, address(router), route, alice, alice), uint256(0))
        );
        vm.expectRevert(TSVAdapter.InvalidParticipant.selector);
        caller.execute(address(adapter), _adapterPayload(true, alice, address(router), route, address(0), alice));
        assertFalse(adapter.isNonceUsed(0));
    }

    function testWrongPoolOrRecipientRejectsAtomically() public {
        bytes memory wrongPool = _payload(true, address(manager), alice, alice, alice);
        vm.expectRevert(TSVAdapter.InvalidPool.selector);
        caller.execute(address(adapter), wrongPool);
        bytes memory zeroRecipient = _payload(true, address(router), address(0), alice, alice);
        vm.expectRevert(TSVAdapter.InvalidAddress.selector);
        caller.execute(address(adapter), zeroRecipient);
    }

    function testBothDirectionsConsumeInputBalanceAndPreserveExistingOutputDonations() public {
        for (uint8 d; d < 2; d++) {
            bool direction = d == 0;
            IERC20 input = _settlementToken(direction ? key.currency0 : key.currency1);
            IERC20 output = _settlementToken(direction ? key.currency1 : key.currency0);
            vm.startPrank(alice);
            input.transfer(address(adapter), 1e18 + 100);
            output.transfer(address(adapter), 200);
            vm.stopPrank();
            uint256 aliceOutBefore = output.balanceOf(alice);
            uint256 usedBefore = ledger.used(SECURITY, DAY);
            caller.execute(address(adapter), _payload(direction, address(router), alice, alice, alice));
            assertEq(input.balanceOf(address(adapter)), 0);
            assertEq(output.balanceOf(address(adapter)), 200);
            uint256 delivered = output.balanceOf(alice) - aliceOutBefore;
            assertGt(delivered, 0);
            assertEq(
                ledger.used(SECURITY, DAY) - usedBefore, address(input) == address(underlying) ? 1e18 + 100 : delivered
            );
            assertEq(input.allowance(address(adapter), address(router)), 0);
            assertEq(stock.balanceOf(address(adapter)), 0);
            assertEq(_inventory(), 17);
            assertEq(router.msgSender(), address(0));
            // Remove the output donation before it becomes the next direction's input.
            vm.prank(address(adapter));
            output.transfer(alice, 200);
        }
    }

    function testParticipantAndCustomRecipientAreIndependent() public {
        address recipient = makeAddr("recipient-without-sbt");
        IERC20 input = _settlementToken(key.currency0);
        IERC20 output = _settlementToken(key.currency1);
        vm.prank(alice);
        input.transfer(address(adapter), 1e18);
        caller.execute(address(adapter), _payload(true, address(router), recipient, alice, alice));
        assertGt(output.balanceOf(recipient), 0);
        assertFalse(registry.hasCredential(recipient));
        assertFalse(registry.hasCredential(address(adapter)));
    }

    function testPartialFillRefundsToRefundMarkerNotParticipant() public {
        bool direction = Currency.unwrap(key.currency0) == address(stock);
        IERC20 input = IERC20(address(underlying));
        address refundTo = makeAddr("separate-refund");
        vm.prank(alice);
        input.transfer(address(adapter), 1e22);
        uint256 usedBefore = ledger.used(SECURITY, DAY);
        caller.execute(address(adapter), _payload(direction, address(router), alice, alice, refundTo));
        uint256 actualIn = ledger.used(SECURITY, DAY) - usedBefore;
        assertGt(actualIn, 0);
        assertLt(actualIn, 1e22);
        assertEq(input.balanceOf(refundTo), 1e22 - actualIn);
        assertEq(input.balanceOf(address(adapter)), 0);
        assertEq(input.allowance(address(adapter), address(router)), 0);
    }

    function testIneligibleParticipantCannotUseEligibleRefundAddress() public {
        address participant = makeAddr("no-sbt");
        bytes memory payload = _payload(true, address(router), alice, participant, alice);
        vm.prank(alice);
        _settlementToken(key.currency0).transfer(address(adapter), 1e18);
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        caller.execute(address(adapter), payload);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testSuccessfulAuthorizationCannotBeReplayed() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice);
        vm.prank(alice);
        _settlementToken(key.currency0).transfer(address(adapter), 1e18);
        caller.execute(address(adapter), payload);
        assertTrue(adapter.isNonceUsed(0));
        vm.expectRevert(CallerAuth.AUTH_NonceUsed.selector);
        caller.execute(address(adapter), payload);
    }

    function testExpiredAuthorizationReverts() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice);
        vm.warp(block.timestamp + 101);
        vm.expectRevert(TSVAdapter.AuthExpired.selector);
        caller.execute(address(adapter), payload);
    }

    function testAdapterAuthorizationRequiresGovernorAndCanBeRevoked() public {
        vm.expectRevert();
        vm.prank(alice);
        router.setAdapterAllowed(address(adapter), false);
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(address(0), true);
        vm.expectRevert(TSVSwapRouterV1.InvalidAdapter.selector);
        router.setAdapterAllowed(alice, true);
        router.setAdapterAllowed(address(adapter), false);
        assertFalse(router.isAdapterAllowed(address(adapter)));
        IERC20 input = _settlementToken(key.currency0);
        vm.prank(alice);
        input.transfer(address(adapter), 1e18);
        bytes memory payload = _payload(true, address(router), alice, alice, alice);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        caller.execute(address(adapter), payload);
        assertEq(_digest(), before_);
        assertEq(input.balanceOf(address(adapter)), 1e18);
        assertEq(input.allowance(address(adapter), address(router)), 0);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testAdapterPaymentPreservesUserIdentityAndLocksEverySwapEntry() public {
        for (uint256 d; d < 2; ++d) {
            bool direction = d == 0;
            IERC20 input = _settlementToken(direction ? key.currency0 : key.currency1);
            vm.prank(alice);
            input.transfer(address(adapter), 1e16);
            if (address(input) == address(underlying)) {
                underlying.setCallback(address(this), abi.encodeCall(this.assertAdapterLock, ()));
            } else {
                quote.setCallback(address(this), abi.encodeCall(this.assertAdapterLock, ()));
            }
            caller.execute(address(adapter), _payload(direction, address(router), alice, alice, alice));
            underlying.setCallback(address(0), bytes(""));
            quote.setCallback(address(0), bytes(""));
            assertEq(router.msgSender(), address(0));
        }
    }

    function assertAdapterLock() external {
        require(msg.sender == address(underlying) || msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInput(_request(true, true, 1e16));
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactOutput(_request(false, false, 1e16));
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInputFromAdapterDirect(_request(true, true, 1e16), alice, alice);
    }

    function _settlementToken(Currency currency) internal view returns (IERC20) {
        return IERC20(router.settlementCurrency(Currency.unwrap(currency)));
    }

    function _payload(bool direction, address pool, address recipient, address participant, address refundTo)
        internal
        returns (bytes memory)
    {
        return _adapterPayload(
            direction, recipient, pool, _adapterRoute(adapter, address(caller), key), participant, refundTo
        );
    }
}
