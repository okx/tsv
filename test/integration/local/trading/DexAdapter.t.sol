// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
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
        adapter = new TSVAdapter(address(router), address(this), address(caller), vm.addr(TEST_AUTH_KEY));
        router.setAdapterAllowed(address(adapter), true);
    }

    function testUntrustedCallerCannotSpoofAuthenticatedParticipantMarker() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice, 1e18);
        vm.prank(alice);
        (bool ok, bytes memory data) = address(adapter).call(payload);
        assertFalse(ok);
        assertEq(bytes4(data), TSVAdapter.UnauthorizedDexRouter.selector);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testMalformedLengthPrefixAndZeroParticipantRejectBeforeFunding() public {
        bytes memory route = _adapterRoute(adapter, address(caller), key, issuer.multiplier(), 1e18, true, alice, alice);
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

    function testPoolArgumentIsIgnoredAndZeroRecipientRejectsAtomically() public {
        _fundInput(true, 1e18);
        caller.execute(address(adapter), _payload(true, address(manager), alice, alice, alice, 1e18));

        _fundInput(true, 1e18);
        bytes memory route = _adapterRoute(
            adapter, address(caller), key, issuer.multiplier(), 1e18, true, alice, address(0)
        );
        bytes memory zeroRecipient = _adapterPayload(true, address(0), address(router), route, alice, alice);
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        caller.execute(address(adapter), zeroRecipient);
    }

    function testBothDirectionsConsumeInputBalanceAndPreserveExistingOutputDonations() public {
        uint256 routerQuoteDonation = 333;
        quote.mint(address(router), routerQuoteDonation);
        for (uint8 d; d < 2; d++) {
            bool direction = d == 0;
            IERC20 input = _settlementToken(direction ? key.currency0 : key.currency1);
            IERC20 output = _settlementToken(direction ? key.currency1 : key.currency0);
            uint256 freeStockBefore = underlying.balanceOf(address(stock)) - stock.totalSupply();
            vm.startPrank(alice);
            input.transfer(address(input) == address(underlying) ? address(stock) : address(adapter), 1e18 + 100);
            output.transfer(address(adapter), 200);
            vm.stopPrank();
            uint256 aliceOutBefore = output.balanceOf(alice);
            uint256 usedBefore = ledger.usedWad(SECURITY, DAY);
            caller.execute(address(adapter), _payload(direction, address(router), alice, alice, alice, 1e18));
            assertEq(input.balanceOf(address(adapter)), address(input) == address(underlying) ? 0 : 100);
            if (address(input) == address(underlying)) {
                assertEq(underlying.balanceOf(address(stock)) - stock.totalSupply(), freeStockBefore + 100);
            }
            assertEq(output.balanceOf(address(adapter)), 200);
            uint256 delivered = output.balanceOf(alice) - aliceOutBefore;
            assertGt(delivered, 0);
            assertEq(
                ledger.usedWad(SECURITY, DAY) - usedBefore,
                address(input) == address(underlying) ? 1e18 : delivered
            );
            assertEq(_inventory(), freeStockBefore + (address(input) == address(underlying) ? 100 : 0));
            assertEq(input.allowance(address(adapter), address(router)), 0);
            assertEq(stock.balanceOf(address(adapter)), 0);
            assertEq(quote.balanceOf(address(router)), routerQuoteDonation);
            assertEq(router.msgSender(), address(0));
            // Remove the output donation before it becomes the next direction's input.
            vm.prank(address(adapter));
            output.transfer(alice, 200);
        }
    }

    function testBuyRequiresRecipientToMatchParticipant() public {
        address recipient = makeAddr("recipient-without-sbt");
        bool quoteToStock = router.settlementCurrency(Currency.unwrap(key.currency0)) == Currency.unwrap(key.currency0);
        IERC20 output = _settlementToken(quoteToStock ? key.currency1 : key.currency0);
        _fundInput(quoteToStock, 1e18);
        vm.expectRevert(TSVSwapRouterV1.InvalidRequest.selector);
        caller.execute(address(adapter), _payload(quoteToStock, address(router), recipient, alice, alice, 1e18));
        assertEq(output.balanceOf(recipient), 0);
        assertFalse(registry.hasCredential(recipient));
        assertFalse(registry.hasCredential(address(adapter)));
    }

    function testPartialFillRevertsAndPreservesPrefundingNonceAndAllowance() public {
        bool direction = Currency.unwrap(key.currency0) == address(stock);
        IERC20 input = IERC20(address(underlying));
        address refundTo = makeAddr("separate-refund");
        uint256 stockInputBefore = input.balanceOf(address(stock));
        vm.prank(alice);
        input.transfer(address(stock), 1e22);
        bytes memory payload = _payload(direction, address(router), alice, alice, refundTo, 1e22);
        bytes32 beforeState = _digest();
        vm.expectRevert(TSVSwapRouterV1.SlippageExceeded.selector);
        caller.execute(address(adapter), payload);
        assertEq(_digest(), beforeState);
        assertEq(input.balanceOf(address(stock)), stockInputBefore + 1e22);
        assertEq(input.balanceOf(refundTo), 0);
        assertEq(input.allowance(address(adapter), address(router)), 0);
        assertFalse(adapter.isNonceUsed(authNonce - 1));
    }

    function testIneligibleParticipantCannotUseEligibleRefundAddress() public {
        address participant = makeAddr("no-sbt");
        bool quoteToStock = router.settlementCurrency(Currency.unwrap(key.currency0)) == Currency.unwrap(key.currency0);
        bytes memory payload = _payload(quoteToStock, address(router), participant, participant, alice, 1e18);
        _fundInput(quoteToStock, 1e18);
        vm.expectRevert(PermissionedV4Router.Unauthorized.selector);
        caller.execute(address(adapter), payload);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testSuccessfulAuthorizationCannotBeReplayed() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice, 1e18);
        _fundInput(true, 1e18);
        caller.execute(address(adapter), payload);
        assertTrue(adapter.isNonceUsed(0));
        vm.expectRevert(CallerAuth.AUTH_NonceUsed.selector);
        caller.execute(address(adapter), payload);
    }

    function testExpiredAuthorizationReverts() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice, 1e18);
        vm.warp(block.timestamp + 101);
        vm.expectRevert(TSVAdapter.AuthExpired.selector);
        caller.execute(address(adapter), payload);
    }

    function testMultiplierTamperingInvalidatesSignedRoute() public {
        bytes memory route = _adapterRoute(adapter, address(caller), key, issuer.multiplier(), 1e18, true, alice, alice);
        TSVAdapter.MoreInfo memory info = abi.decode(route, (TSVAdapter.MoreInfo));
        info.expectedMultiplier = 2e18;
        bytes memory payload = _adapterPayload(true, alice, address(router), abi.encode(info), alice, alice);
        vm.expectRevert(CallerAuth.AUTH_BadAuthSig.selector);
        caller.execute(address(adapter), payload);
        assertFalse(adapter.isNonceUsed(info.nonce));
    }

    function testSignedStaleMultiplierRejectsAndPreservesNonceAndPrefunding() public {
        bytes memory payload = _payload(true, address(router), alice, alice, alice, 1e16);
        IERC20 input = _settlementToken(key.currency0);
        _fundInput(true, 1e16);
        issuer.setMultiplier(2e18, 1);
        bytes32 beforeState = _digest();
        vm.expectRevert();
        caller.execute(address(adapter), payload);
        assertEq(_digest(), beforeState);
        assertFalse(adapter.isNonceUsed(authNonce - 1));
        assertEq(
            input.balanceOf(address(input) == address(underlying) ? address(stock) : address(adapter)), 1e16
        );
        assertEq(input.allowance(address(adapter), address(router)), 0);
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
        _fundInput(true, 1e18);
        bytes memory payload = _payload(true, address(router), alice, alice, alice, 1e18);
        bytes32 before_ = _digest();
        vm.expectRevert(TSVSwapRouterV1.AdapterNotAllowed.selector);
        caller.execute(address(adapter), payload);
        assertEq(_digest(), before_);
        assertEq(
            input.balanceOf(address(input) == address(underlying) ? address(stock) : address(adapter)), 1e18
        );
        assertEq(input.allowance(address(adapter), address(router)), 0);
        assertFalse(adapter.isNonceUsed(0));
    }

    function testAdapterPaymentPreservesUserIdentityAndLocksEverySwapEntry() public {
        for (uint256 d; d < 2; ++d) {
            bool direction = d == 0;
            IERC20 input = _settlementToken(direction ? key.currency0 : key.currency1);
            _fundInput(direction, 1e16);
            if (address(input) == address(underlying)) {
                underlying.setCallback(address(this), abi.encodeCall(this.assertAdapterLock, ()));
            } else {
                quote.setCallback(address(this), abi.encodeCall(this.assertAdapterLock, ()));
            }
            caller.execute(address(adapter), _payload(direction, address(router), alice, alice, alice, 1e16));
            underlying.setCallback(address(0), bytes(""));
            quote.setCallback(address(0), bytes(""));
            assertEq(router.msgSender(), address(0));
        }
    }

    function assertAdapterLock() external {
        require(msg.sender == address(underlying) || msg.sender == address(quote));
        assertEq(router.msgSender(), alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        _swap(true, 1e16);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        _swap(false, 1e16);
        SwapRequest memory request = _request(true, 1e16);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInputFromContractDirect(request, address(0), alice, alice);
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        router.swapExactInputFromContract(request, alice);
    }

    function _settlementToken(Currency currency) internal view returns (IERC20) {
        return IERC20(router.settlementCurrency(Currency.unwrap(currency)));
    }

    function _fundInput(bool zeroForOne, uint256 amountIn) internal {
        address inputCurrency = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        IERC20 input = _settlementToken(zeroForOne ? key.currency0 : key.currency1);
        address sink = inputCurrency == address(stock) ? address(stock) : address(adapter);
        vm.prank(alice);
        input.transfer(sink, amountIn);
    }

    function _payload(
        bool direction,
        address pool,
        address recipient,
        address participant,
        address refundTo,
        uint256 amountIn
    ) internal returns (bytes memory) {
        return _adapterPayload(
            direction,
            recipient,
            pool,
            _adapterRoute(
                adapter,
                address(caller),
                key,
                issuer.multiplier(),
                amountIn,
                direction,
                participant,
                recipient
            ),
            participant,
            refundTo
        );
    }
}
