// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Deploys the fixed governance Anchor with its three independent identities.
contract DeployGovernanceV1 is ScriptEnvironment {
    error InvalidDeploymentInput();

    function run() external returns (TSVGovernanceAnchor anchor) {
        uint256 deployerKey = _envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address governor = _envAddress("TSV_GOVERNOR");
        address guardian = _envAddress("TSV_GUARDIAN");
        address council = _envAddress("TSV_RECOVERY_COUNCIL");
        if (block.chainid != _envUint("TSV_CHAIN_ID")) revert InvalidDeploymentInput();

        vm.startBroadcast(deployerKey);
        anchor = new TSVGovernanceAnchor(governor, guardian, council);
        vm.stopBroadcast();
        if (
            anchor.governor() != governor || anchor.guardian() != guardian || anchor.upgradesFrozen()
                || anchor.recoveryCouncil() != council
        ) revert InvalidDeploymentInput();
        console2.log("GovernanceAnchor", address(anchor));
    }
}
