// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TradingLPHandler} from "../../../helpers/v1/TradingLPHandler.sol";

/// @dev Mixed trading and LP sequences, checked against independent balance/position/quota models.
contract TSVStatefulTradingLPTest is Test {
    TradingLPHandler internal handler;

    function setUp() public {
        handler = new TradingLPHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = TradingLPHandler.swap.selector;
        selectors[1] = TradingLPHandler.open.selector;
        selectors[2] = TradingLPHandler.change.selector;
        selectors[3] = TradingLPHandler.collect.selector;
        selectors[4] = TradingLPHandler.close.selector;
        selectors[5] = TradingLPHandler.credential.selector;
        selectors[6] = TradingLPHandler.pause.selector;
        selectors[7] = TradingLPHandler.conversion.selector;
        selectors[8] = TradingLPHandler.quota.selector;
        selectors[9] = TradingLPHandler.advanceDay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantPositionsReceiptsBalancesVolumeAndV4DebtMatchModel() public view {
        handler.assertModel();
    }

    function testModelTraversesSuccessfulAndRejectedSwapLPQuotaAndDayChanges() public {
        handler.open(10, false);
        handler.swap(1e14, true, true, false);
        handler.change(1, true, false);
        handler.collect(0);
        handler.pause(1);
        handler.swap(1e14, true, true, false);
        handler.change(1, false, false);
        handler.pause(2);
        handler.swap(1e14, false, false, false);
        handler.change(1, true, false);
        handler.credential(false, false);
        handler.close(0, true);
        handler.credential(true, false);
        handler.pause(0);
        handler.quota(true, false);
        handler.swap(1e14, true, true, false);
        handler.quota(false, true);
        handler.swap(1e14, true, true, false);
        handler.advanceDay(1);
        handler.swap(1e14, false, false, false);
        handler.assertModel();
        assertEq(handler.successfulSwaps(), 4);
        assertGe(handler.successfulLPChanges(), 4);
        assertGe(handler.rejectedOperations(), 3);
    }
}
