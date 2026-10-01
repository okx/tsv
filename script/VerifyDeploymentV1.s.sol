// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @notice Read-only post-deployment check. Role, report, asset and issuer evidence remain manifest gates.
contract VerifyDeploymentV1 is Script {
    error VerificationFailed();

    function run() external view {
        if (block.chainid != vm.envUint("TSV_CHAIN_ID")) revert VerificationFailed();
        TSVGovernanceAnchor anchor = TSVGovernanceAnchor(vm.envAddress("TSV_GOVERNANCE_ANCHOR"));
        address[6] memory a = [
            vm.envAddress("TSV_REGISTRY"),
            vm.envAddress("TSV_VOLUME_LEDGER"),
            vm.envAddress("TSV_DATA_INBOX"),
            vm.envAddress("TSV_HOOK"),
            vm.envAddress("TSV_SWAP_ROUTER"),
            vm.envAddress("TSV_LP_MANAGER")
        ];
        _checkGovernance(anchor, a);
        _checkLinks(anchor, a);
        _checkImplementations(a);
        console2.log("TSV governance, six proxy links, code hashes and implementation addresses verified.");
    }

    function _checkGovernance(TSVGovernanceAnchor anchor, address[6] memory a) private view {
        if (
            address(anchor).code.length == 0 || !anchor.proxiesBound()
                || address(anchor.timelock()) != vm.envAddress("TSV_UPGRADE_TIMELOCK")
                || address(anchor.authority()) != vm.envAddress("TSV_BUSINESS_AUTHORITY")
                || address(anchor.controller()) != vm.envAddress("TSV_EMERGENCY_CONTROLLER")
                || anchor.guardian() != anchor.timelock().guardian()
                || anchor.recoveryCouncil() != anchor.timelock().recoveryCouncil()
                || address(anchor.timelock().governanceAnchor()) != address(anchor)
                || address(anchor.timelock().businessAuthority()) != address(anchor.authority())
                || address(anchor.timelock().emergencyController()) != address(anchor.controller())
        ) revert VerificationFailed();
        for (uint256 i; i < 6; ++i) {
            if (
                a[i].code.length == 0 || anchor.proxies(i) != a[i]
                    || address(TSVRegistryV1(a[i]).governanceAnchor()) != address(anchor)
            ) revert VerificationFailed();
        }
    }

    function _checkLinks(TSVGovernanceAnchor anchor, address[6] memory a) private view {
        TSVRegistryV1 registry = TSVRegistryV1(a[0]);
        TSVVolumeLedgerV1 ledger = TSVVolumeLedgerV1(a[1]);
        TSVDataInboxV1 inbox = TSVDataInboxV1(a[2]);
        TSVHookV1 hook = TSVHookV1(a[3]);
        TSVSwapRouterV1 router = TSVSwapRouterV1(a[4]);
        TSVLPManagerV1 lp = TSVLPManagerV1(a[5]);
        address poolManager = vm.envAddress("TSV_POOL_MANAGER");
        address sbt = vm.envAddress("TSV_SBT");
        if (
            poolManager.code.length == 0 || sbt.code.length == 0
                || poolManager.codehash != vm.envBytes32("TSV_POOL_MANAGER_CODEHASH")
                || sbt.codehash != vm.envBytes32("TSV_SBT_CODEHASH") || address(registry.participantSbt()) != sbt
                || registry.sbtTokenId() != vm.envUint("TSV_SBT_TOKEN_ID") || registry.hook() != a[3]
                || registry.lpManager() != a[5] || registry.dataInbox() != a[2] || address(ledger.registry()) != a[0]
                || ledger.hook() != a[3] || ledger.dataInbox() != a[2] || address(inbox.registry()) != a[0]
                || address(inbox.ledger()) != a[1] || address(hook.poolManager()) != poolManager
                || address(hook.registry()) != a[0] || address(hook.ledger()) != a[1] || hook.router() != a[4]
                || hook.lpManager() != a[5] || address(router.poolManager()) != poolManager
                || address(router.registry()) != a[0] || address(router.ledger()) != a[1]
                || address(lp.poolManager()) != poolManager
                || address(lp.registry()) != a[0] || (uint160(a[3]) & 0x3FFF) != 0x3FFF
                || address(anchor.authority()) != address(registry.businessAuthority())
        ) revert VerificationFailed();
    }

    function _checkImplementations(address[6] memory a) private view {
        address[6] memory expected = [
            vm.envAddress("TSV_REGISTRY_IMPLEMENTATION"),
            vm.envAddress("TSV_VOLUME_LEDGER_IMPLEMENTATION"),
            vm.envAddress("TSV_DATA_INBOX_IMPLEMENTATION"),
            vm.envAddress("TSV_HOOK_IMPLEMENTATION"),
            vm.envAddress("TSV_SWAP_ROUTER_IMPLEMENTATION"),
            vm.envAddress("TSV_LP_MANAGER_IMPLEMENTATION")
        ];
        for (uint256 i; i < 6; ++i) {
            if (
                expected[i].code.length == 0 || expected[i].codehash != vm.envBytes32(_hashEnvName(i))
                    || TSVERC1967Proxy(payable(a[i])).tsvImplementation() != expected[i]
            ) revert VerificationFailed();
        }
    }

    function _hashEnvName(uint256 i) private pure returns (string memory) {
        if (i == 0) return "TSV_REGISTRY_IMPLEMENTATION_CODEHASH";
        if (i == 1) return "TSV_VOLUME_LEDGER_IMPLEMENTATION_CODEHASH";
        if (i == 2) return "TSV_DATA_INBOX_IMPLEMENTATION_CODEHASH";
        if (i == 3) return "TSV_HOOK_IMPLEMENTATION_CODEHASH";
        if (i == 4) return "TSV_SWAP_ROUTER_IMPLEMENTATION_CODEHASH";
        return "TSV_LP_MANAGER_IMPLEMENTATION_CODEHASH";
    }
}
