// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";

/// @dev TSVGovernanceLocalTest scenarios; inherited fixtures contain no test functions.
contract TSVGovernanceLocalTest is ProtocolFixture {
    function testGlobalUpgradeFreezeAllowsSwapLiquidityChangesAndOrdinaryExit() public {
        vm.prank(anchor.guardian());
        bytes32 freeze = anchor.freezeUpgrades();
        _assertDirectLpLifecycle();
        assertTrue(anchor.upgradesFrozen());
        assertEq(anchor.freezeId(), freeze);
    }
}
