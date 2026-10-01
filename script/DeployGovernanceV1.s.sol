// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @notice Deploys the non-proxy governance trio and fixed Anchor. Binding is a separate Timelock operation.
contract DeployGovernanceV1 is Script {
    error InvalidDeploymentInput();

    function run()
        external
        returns (
            TSVUpgradeTimelock timelock,
            TSVBusinessAuthority authority,
            TSVEmergencyUpgradeController controller,
            TSVGovernanceAnchor anchor
        )
    {
        uint256 deployerKey = vm.envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address governor = vm.envAddress("TSV_GOVERNOR");
        address guardian = vm.envAddress("TSV_GUARDIAN");
        address council = vm.envAddress("TSV_RECOVERY_COUNCIL");
        address executor = vm.envAddress("TSV_EXECUTOR");
        uint256 expectedChainId = vm.envUint("TSV_CHAIN_ID");
        if (
            block.chainid != expectedChainId || governor == address(0) || guardian == address(0)
                || council == address(0) || executor == address(0) || governor == guardian || governor == council
                || guardian == council
        ) revert InvalidDeploymentInput();

        address[] memory executors = new address[](1);
        executors[0] = executor;
        vm.startBroadcast(deployerKey);
        timelock = new TSVUpgradeTimelock(governor, guardian, council, executors);
        authority = new TSVBusinessAuthority(governor, address(timelock));
        controller = new TSVEmergencyUpgradeController(governor, guardian, address(timelock));
        anchor = new TSVGovernanceAnchor(address(timelock), address(authority), address(controller));
        vm.stopBroadcast();

        if (
            timelock.governor() != governor || timelock.guardian() != guardian || timelock.recoveryCouncil() != council
                || authority.upgradeTimelock() != address(timelock) || controller.upgradeTimelock() != address(timelock)
                || !controller.frozen() || address(anchor.timelock()) != address(timelock)
        ) revert InvalidDeploymentInput();
        console2.log("UpgradeTimelock", address(timelock));
        console2.log("BusinessAuthority", address(authority));
        console2.log("EmergencyUpgradeController", address(controller));
        console2.log("GovernanceAnchor", address(anchor));
        console2.log("Bind authority, controller and Anchor through scheduled Timelock calls before core deployment.");
    }
}
