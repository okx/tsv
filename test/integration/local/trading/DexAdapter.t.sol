// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {DexRouterTestAdapter} from "../../../helpers/v1/DexRouterTestAdapter.sol";

/// @dev Controlled caller used exclusively to inject valid/malformed authenticated callback trailers.
contract TestDexCallbackCaller {
    function execute(address adapter, bytes calldata data) external {
        (bool ok, bytes memory result) = adapter.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}

contract TSVDexAdapterTest is ProtocolFixture {
    TestDexCallbackCaller internal caller;
    DexRouterTestAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        caller = new TestDexCallbackCaller();
        adapter = new DexRouterTestAdapter(address(caller), router);
        router.setAdapterAllowed(address(adapter), true);
    }

    function testUntrustedCallerCannotSpoofAuthenticatedParticipantMarker() public {
        bytes memory payload = _payload(true, address(router), alice, _marker(alice));
        vm.prank(alice);
        (bool ok, bytes memory data) = address(adapter).call(payload);
        assertFalse(ok);
        assertEq(bytes4(data), DexRouterTestAdapter.UnauthorizedDex.selector);
        assertEq(adapter.lastParticipant(), address(0));
    }

    function testMalformedLengthPrefixAndZeroParticipantRejectBeforeFunding() public {
        bytes memory canonical = abi.encodeCall(
            DexRouterTestAdapter.sellBase, (alice, address(router), abi.encode(_swapRequest(true, 1e18)))
        );
        uint256[3] memory markers = [uint256(0), uint256(uint160(alice)), _marker(address(0))];
        for (uint8 i; i < 3; i++) {
            bytes memory payload = abi.encodePacked(canonical, uint256(1e18), markers[i]);
            vm.expectRevert();
            caller.execute(address(adapter), payload);
        }
        vm.expectRevert();
        caller.execute(address(adapter), abi.encodePacked(canonical, _marker(alice)));
        vm.expectRevert();
        caller.execute(address(adapter), abi.encodePacked(canonical, uint256(0), uint256(1e18), _marker(alice)));
        assertEq(adapter.lastParticipant(), address(0));
    }

    function testWrongPoolDirectionOrRecipientRejectsAtomically() public {
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), _payload(true, address(manager), alice, _marker(alice)));
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), _payload(true, address(router), address(0), _marker(alice)));
        bytes memory payload = abi.encodePacked(
            abi.encodeCall(
                DexRouterTestAdapter.sellQuote, (alice, address(router), abi.encode(_swapRequest(true, 1e18)))
            ),
            uint256(1e18),
            _marker(alice)
        );
        vm.expectRevert(DexRouterTestAdapter.InvalidRoute.selector);
        caller.execute(address(adapter), payload);
    }

    function testBothDirectionsRefundOnlyRouteInputAndPreserveExistingDonations() public {
        for (uint8 d; d < 2; d++) {
            bool direction = d == 0;
            IERC20 input = IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1));
            IERC20 output = IERC20(Currency.unwrap(direction ? key.currency1 : key.currency0));
            vm.startPrank(alice);
            input.transfer(address(adapter), 1e18 + 100);
            output.transfer(address(adapter), 200);
            vm.stopPrank();
            uint256 inputBefore = input.balanceOf(address(adapter));
            uint256 outputBefore = output.balanceOf(address(adapter));
            uint256 aliceOutBefore = output.balanceOf(alice);
            caller.execute(address(adapter), _payload(direction, address(router), alice, _marker(alice)));
            assertEq(adapter.lastParticipant(), alice);
            assertEq(input.balanceOf(address(adapter)), inputBefore - 1e18);
            assertEq(output.balanceOf(address(adapter)), outputBefore);
            assertEq(output.balanceOf(alice) - aliceOutBefore, adapter.lastActualOut());
            assertEq(input.allowance(address(adapter), address(router)), 0);
        }
    }

    function _payload(bool direction, address pool, address recipient, uint256 marker)
        internal
        view
        returns (bytes memory)
    {
        bytes memory route = abi.encode(_swapRequest(direction, 1e18));
        bytes memory data = direction
            ? abi.encodeCall(DexRouterTestAdapter.sellBase, (recipient, pool, route))
            : abi.encodeCall(DexRouterTestAdapter.sellQuote, (recipient, pool, route));
        return abi.encodePacked(data, uint256(1e18), marker);
    }

    function _marker(address participant) internal pure returns (uint256) {
        return 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000 | uint256(uint160(participant));
    }
}
