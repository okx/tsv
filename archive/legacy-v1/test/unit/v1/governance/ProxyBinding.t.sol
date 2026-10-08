// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SixProxyFixture} from "../../../helpers/v1/SixProxyFixture.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Binding is permanent and any failed validation must leave the Anchor unbound.
contract TSVProxyBindingTest is SixProxyFixture {
    function _bindInSetUp() internal pure override returns (bool) {
        return false;
    }

    function testOnlyGovernorCanBindProxies() public {
        address[3] memory callers = [guardian, council, makeAddr("outsider")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
            anchor.bindProxies(businessProxies);
        }
        _assertUnbound();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testProxiesCannotBeReboundEvenByGovernor() public {
        anchor.bindProxies(businessProxies);
        vm.expectRevert(TSVGovernanceAnchor.Unauthorized.selector);
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testFuzzBindingRejectsMissingCodeAtAnyPosition(uint8 position, bool zeroAddress) public {
        position = uint8(bound(position, 0, 5));
        address[6] memory invalid = businessProxies;
        invalid[position] = zeroAddress ? address(0) : makeAddr("missing-proxy");
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(invalid);
        _assertUnbound();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testFuzzBindingRejectsDifferentAnchorAtAnyPosition(uint8 position) public {
        position = uint8(bound(position, 0, 5));
        vm.mockCall(
            businessProxies[position],
            abi.encodeWithSignature("governanceAnchor()"),
            abi.encode(makeAddr("other-anchor"))
        );
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(businessProxies);
        _assertUnbound();
        vm.clearMockedCalls();
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testBindingRejectsDuplicateProxyAndWrongOrder() public {
        address[6] memory invalid = businessProxies;
        invalid[5] = invalid[4];
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        anchor.bindProxies(invalid);
        _assertUnbound();
        invalid = businessProxies;
        (invalid[1], invalid[2]) = (invalid[2], invalid[1]);
        // The swapped contracts do not expose the required component ABI.
        vm.expectRevert();
        anchor.bindProxies(invalid);
        _assertUnbound();
    }

    function testEveryBrokenCrossLinkRollsBackAndCanBeRetried() public {
        uint8[16] memory owners = [0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 3, 3, 4, 5, 4, 5];
        string[16] memory getters = [
            "hook()",
            "lpManager()",
            "dataInbox()",
            "registry()",
            "hook()",
            "dataInbox()",
            "registry()",
            "ledger()",
            "registry()",
            "ledger()",
            "router()",
            "lpManager()",
            "registry()",
            "registry()",
            "poolManager()",
            "poolManager()"
        ];
        for (uint256 i; i < owners.length; ++i) {
            vm.mockCall(
                businessProxies[owners[i]], abi.encodeWithSignature(getters[i]), abi.encode(makeAddr("wrong-link"))
            );
            vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
            anchor.bindProxies(businessProxies);
            _assertUnbound();
            vm.clearMockedCalls();
        }
        anchor.bindProxies(businessProxies);
        _assertBound();
    }

    function testBatchCannotRunBeforeBinding() public {
        UpgradePlan memory plan = _currentPlan(1);
        vm.expectRevert(TSVGovernanceAnchor.InvalidBundle.selector);
        _execute(plan);
        _assertImplementations(plan);
    }

    function _assertUnbound() private view {
        assertFalse(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), address(0), "partial binding survived revert");
        }
    }

    function _assertBound() private view {
        assertTrue(anchor.proxiesBound());
        for (uint256 i; i < 6; ++i) {
            assertEq(anchor.proxies(i), businessProxies[i]);
        }
    }
}
