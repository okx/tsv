// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernanceFixture} from "./GovernanceFixture.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @dev Six real UUPS proxies. CREATE2 mining is tested separately by the factory suite.
abstract contract SixProxyFixture is GovernanceFixture {
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    TSVDataInboxV1 internal inbox;
    TSVHookV1 internal hook;
    TSVSwapRouterV1 internal router;
    TSVLPManagerV1 internal lp;
    address[6] internal businessProxies;

    struct UpgradePlan {
        address[] targets;
        address[] implementations;
        bytes[] calls;
    }

    function setUp() public virtual override {
        super.setUp();
        registry = TSVRegistryV1(address(_newRegistryProxy()));
        ledger = TSVVolumeLedgerV1(
            _proxy(
                address(new TSVVolumeLedgerV1()),
                abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(anchor), address(registry), 14_400))
            )
        );
        inbox = TSVDataInboxV1(
            _proxy(
                address(new TSVDataInboxV1()),
                abi.encodeCall(TSVDataInboxV1.initialize, (address(anchor), address(registry), address(ledger)))
            )
        );
        router = TSVSwapRouterV1(
            _proxy(
                address(new TSVSwapRouterV1(address(this), address(registry))),
                abi.encodeCall(
                    TSVSwapRouterV1.initialize, (address(anchor), address(this), address(registry), address(ledger))
                )
            )
        );
        lp = TSVLPManagerV1(
            _proxy(
                address(new TSVLPManagerV1()),
                abi.encodeCall(TSVLPManagerV1.initialize, (address(anchor), address(this), address(registry)))
            )
        );
        hook = TSVHookV1(address(uint160(0x3FFF)));
        vm.etch(address(hook), type(TSVERC1967Proxy).runtimeCode);
        vm.store(
            address(hook),
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(uint160(address(new TSVHookV1()))))
        );
        hook.initialize(
            address(anchor), address(this), address(registry), address(ledger), address(router), address(lp)
        );
        registry.bindComponents(address(hook), address(lp), address(inbox));
        ledger.bindWriters(address(hook), address(inbox));
        businessProxies =
            [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lp)];
        if (_bindInSetUp()) anchor.bindProxies(businessProxies);
    }

    function _bindInSetUp() internal pure virtual returns (bool) {
        return true;
    }

    function _proxy(address implementation, bytes memory data) internal returns (address) {
        return address(new TSVERC1967Proxy(implementation, data));
    }

    function _implementation(address proxy) internal view returns (address) {
        return TSVERC1967Proxy(payable(proxy)).tsvImplementation();
    }

    function _currentPlan(uint256 count) internal view returns (UpgradePlan memory plan) {
        plan.targets = new address[](count);
        plan.implementations = new address[](count);
        plan.calls = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            plan.targets[i] = businessProxies[i];
            plan.implementations[i] = _implementation(businessProxies[i]);
        }
    }

    function _execute(UpgradePlan memory plan) internal {
        anchor.upgradeBatch(plan.targets, plan.implementations, plan.calls);
    }

    function _assertImplementations(UpgradePlan memory plan) internal view {
        for (uint256 i; i < plan.targets.length; ++i) {
            assertEq(_implementation(plan.targets[i]), plan.implementations[i], "unexpected implementation");
        }
        assertFalse(anchor.upgradeContextActive(), "batch context leaked");
    }
}
