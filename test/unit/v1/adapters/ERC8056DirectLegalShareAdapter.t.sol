// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC8056TestToken} from "../../../../lib/TestToken/erc8056/ERC8056TestToken.sol";
import {ERC8056DirectLegalShareAdapter} from "tsv-v1/adapters/ERC8056DirectLegalShareAdapter.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

contract PlainERC20WithoutMultiplier is ERC20 {
    constructor() ERC20("Plain ERC20", "PLAIN") {}
}

contract ERC8056DirectLegalShareAdapterTest is Test {
    function testRejectsUnderlyingWithoutMultiplierInterface() public {
        ERC20 token = new PlainERC20WithoutMultiplier();

        vm.expectRevert();
        new ERC8056DirectLegalShareAdapter(address(token));
    }

    function testRejectsZeroMultiplierAtConstruction() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        vm.mockCall(address(token), abi.encodeWithSignature("uiMultiplier()"), abi.encode(uint256(0)));

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidAdapterConfig.selector);
        new ERC8056DirectLegalShareAdapter(address(token));
    }

    function testRejectsRevertingMultiplierAtConstruction() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        bytes memory reason = abi.encodeWithSignature("MultiplierUnavailable()");
        vm.mockCallRevert(address(token), abi.encodeWithSignature("uiMultiplier()"), reason);

        vm.expectRevert(reason);
        new ERC8056DirectLegalShareAdapter(address(token));
    }

    function testRejectsMalformedMultiplierAtConstruction() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        uint256[3] memory lengths = [uint256(0), 1, 31];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(address(token), abi.encodeWithSignature("uiMultiplier()"), new bytes(lengths[i]));
            vm.expectRevert();
            new ERC8056DirectLegalShareAdapter(address(token));
            vm.clearMockedCalls();
        }
    }

    function testAcceptsSmallPositiveMultiplierAtConstruction() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        vm.mockCall(address(token), abi.encodeWithSignature("uiMultiplier()"), abi.encode(uint256(1)));

        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));
        assertEq(adapter.currentMultiplier(address(token)), 1);
    }

    function testRuntimeStillRejectsZeroMultiplierAfterDeployment() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));
        vm.mockCall(address(token), abi.encodeWithSignature("uiMultiplier()"), abi.encode(uint256(0)));

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidAdapterConfig.selector);
        adapter.currentMultiplier(address(token));
    }

    function testConvertsUsingMultiplierActiveAtCallTime() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));

        assertEq(adapter.toLegalShares(address(token), 3e18), 3e18);
        token.setUIMultiplier(2e18, block.timestamp + 10);
        assertEq(adapter.toLegalShares(address(token), 3e18), 3e18);

        vm.warp(block.timestamp + 10);
        assertEq(adapter.toLegalShares(address(token), 3e18), 6e18);
    }

    function testScalesUsingTokenDecimals() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 6, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));

        assertEq(adapter.toLegalShares(address(token), 1_500_001), 1_500_001e12);
    }

    function testUsesFloorRounding() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));
        token.setUIMultiplier(5e17, block.timestamp + 1);
        vm.warp(block.timestamp + 1);

        assertEq(adapter.toLegalShares(address(token), 3), 1);
    }

    function testZeroRawAmountConvertsToZero() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));

        assertEq(adapter.toLegalShares(address(token), 0), 0);
    }

    function testRejectsOtherCurrency() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056TestToken other = new ERC8056TestToken("Other", "OTH", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidCurrency.selector);
        adapter.toLegalShares(address(other), 1e18);
    }

    function testDeclaresDirectAdapterInterface() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 18, 0);
        ERC8056DirectLegalShareAdapter adapter = new ERC8056DirectLegalShareAdapter(address(token));

        assertTrue(adapter.supportsInterface(type(IDirectLegalShareAdapter).interfaceId));
    }

    function testRejectsDecimalsAboveSupportedBound() public {
        ERC8056TestToken token = new ERC8056TestToken("Stock", "STK", 19, 0);

        vm.expectRevert(ERC8056DirectLegalShareAdapter.InvalidAdapterConfig.selector);
        new ERC8056DirectLegalShareAdapter(address(token));
    }
}
