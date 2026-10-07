// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PermissionFlag} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @notice Read-only post-deployment check. Role, report, asset and issuer evidence remain manifest gates.
contract VerifyDeploymentV1 is ScriptEnvironment {
    /// @dev Reverts when a deployment address or governance link does not match the manifest.
    error VerificationFailed();

    /// @notice Verifies governance bindings, proxy links and implementation addresses.
    /// @dev Reads the expected deployment manifest values from environment variables and reverts on mismatch.
    function run() external view {
        if (block.chainid != _envUint("TSV_CHAIN_ID")) revert VerificationFailed();
        TSVGovernanceAnchor anchor = TSVGovernanceAnchor(_envAddress("TSV_GOVERNANCE_ANCHOR"));
        address[6] memory a = [
            _envAddress("TSV_REGISTRY"),
            _envAddress("TSV_VOLUME_LEDGER"),
            _envAddress("TSV_DATA_INBOX"),
            _envAddress("TSV_HOOK"),
            _envAddress("TSV_SWAP_ROUTER"),
            _envAddress("TSV_LP_MANAGER")
        ];
        _checkGovernance(anchor, a);
        _checkLinks(a);
        _checkImplementations(a);
        console2.log("TSV governance, six proxy links and implementation addresses verified.");
    }

    /// @dev Checks the Anchor's governance links and confirms all six proxies are bound to it.
    /// @param anchor Governance anchor expected to control the deployed proxies.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkGovernance(TSVGovernanceAnchor anchor, address[6] memory a) private view {
        if (
            address(anchor).code.length == 0 || !anchor.proxiesBound()
                || anchor.governor() != _envAddress("TSV_GOVERNOR") || anchor.guardian() != _envAddress("TSV_GUARDIAN")
                || anchor.recoveryCouncil() != _envAddress("TSV_RECOVERY_COUNCIL")
        ) revert VerificationFailed();
        for (uint256 i; i < 6; ++i) {
            if (
                a[i].code.length == 0 || anchor.proxies(i) != a[i]
                    || address(TSVRegistryV1(a[i]).governanceAnchor()) != address(anchor)
                    || !TSVRegistryV1(a[i]).hasRole(bytes32(0), anchor.governor())
            ) revert VerificationFailed();
        }
    }

    /// @dev Checks cross-contract links, external contract code, SBT configuration and Hook permission bits.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkLinks(address[6] memory a) private view {
        TSVRegistryV1 registry = TSVRegistryV1(a[0]);
        TSVVolumeLedgerV1 ledger = TSVVolumeLedgerV1(a[1]);
        TSVDataInboxV1 inbox = TSVDataInboxV1(a[2]);
        TSVHookV1 hook = TSVHookV1(a[3]);
        TSVSwapRouterV1 router = TSVSwapRouterV1(a[4]);
        TSVLPManagerV1 lp = TSVLPManagerV1(a[5]);
        address poolManager = _envAddress("TSV_POOL_MANAGER");
        address sbt = _envAddress("TSV_SBT");
        address factory = _envAddress("TSV_PERMISSIONS_ADAPTER_FACTORY");
        address validationLibrary = _envAddress("TSV_PERMISSIONED_VALIDATION_LIBRARY");
        if (
            poolManager.code.length == 0 || sbt.code.length == 0 || factory.code.length == 0
                || validationLibrary.code.length == 0 || registry.permissionedValidationLibrary() != validationLibrary
                || registry.permissionsAdapterFactory() != factory || registry.permissionedPoolManager() != poolManager
                || address(router.PERMISSIONS_ADAPTER_FACTORY()) != factory || address(registry.participantSbt()) != sbt
                || _envUint("TSV_RETAIL_SBT_TOKEN_ID") == _envUint("TSV_MARKETMAKER_SBT_TOKEN_ID")
                || !_checkIdentity(
                    registry, _envUint("TSV_RETAIL_SBT_TOKEN_ID"), _envUint("TSV_RETAIL_SBT_PERMISSIONS")
                )
                || !_checkIdentity(
                        registry, _envUint("TSV_MARKETMAKER_SBT_TOKEN_ID"), _envUint("TSV_MARKETMAKER_SBT_PERMISSIONS")
                    ) || registry.hook() != a[3] || registry.lpManager() != a[5] || registry.dataInbox() != a[2]
                || address(ledger.registry()) != a[0] || ledger.hook() != a[3] || ledger.dataInbox() != a[2]
                || address(inbox.registry()) != a[0] || address(inbox.ledger()) != a[1]
                || address(hook.poolManager()) != poolManager || address(hook.registry()) != a[0]
                || address(hook.ledger()) != a[1] || hook.router() != a[4] || hook.lpManager() != a[5]
                || address(router.poolManager()) != poolManager || address(router.registry()) != a[0]
                || address(lp.poolManager()) != poolManager || address(lp.registry()) != a[0]
                || (uint160(a[3]) & 0x3FFF) != 0x3FFF
        ) revert VerificationFailed();
    }

    function _checkIdentity(TSVRegistryV1 registry, uint256 tokenId, uint256 expectedMask) private view returns (bool) {
        (bool registered, PermissionFlag permissions) = registry.sbtIdentityConfig(tokenId);
        uint256 mask = uint16(PermissionFlag.unwrap(permissions));
        return registered && expectedMask <= 3 && mask == expectedMask;
    }

    /// @dev Compares each proxy's implementation address with the deployment manifest.
    /// @param a Proxy addresses in Registry, Ledger, Inbox, Hook, Router and LP Manager order.
    function _checkImplementations(address[6] memory a) private view {
        address[6] memory expected = [
            _envAddress("TSV_REGISTRY_IMPLEMENTATION"),
            _envAddress("TSV_VOLUME_LEDGER_IMPLEMENTATION"),
            _envAddress("TSV_DATA_INBOX_IMPLEMENTATION"),
            _envAddress("TSV_HOOK_IMPLEMENTATION"),
            _envAddress("TSV_SWAP_ROUTER_IMPLEMENTATION"),
            _envAddress("TSV_LP_MANAGER_IMPLEMENTATION")
        ];
        for (uint256 i; i < 6; ++i) {
            if (expected[i].code.length == 0 || TSVERC1967Proxy(payable(a[i])).tsvImplementation() != expected[i]) {
                revert VerificationFailed();
            }
        }
    }
}
