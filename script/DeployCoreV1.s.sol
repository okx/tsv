// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TSVBusinessAuthority} from "tsv-v1/governance/TSVBusinessAuthority.sol";
import {TSVUpgradeTimelock} from "tsv-v1/governance/TSVUpgradeTimelock.sol";
import {TSVEmergencyUpgradeController} from "tsv-v1/governance/TSVEmergencyUpgradeController.sol";
import {TSVGovernanceAnchor} from "tsv-v1/governance/TSVGovernanceAnchor.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {TSVHookProxyFactoryV1} from "tsv-v1/deployment/TSVHookProxyFactoryV1.sol";
import {TSVRegistryV1, ISmartWalletSbtV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {TSVHookV1} from "tsv-v1/core/TSVHookV1.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";
import {TSVLPManagerV1} from "tsv-v1/periphery/TSVLPManagerV1.sol";

/// @notice Deploys six initialized business proxies with an actual CREATE2 Hook address.
/// @dev Governance binding, SBT configuration and asset approvals remain separate governance transactions.
contract DeployCoreV1 is Script {
    error InvalidDeploymentInput();
    error AddressPredictionMismatch();
    error HookSaltNotFound();

    uint160 private constant HOOK_FLAGS = 0x3FFF;
    uint256 private constant MAX_SALT_ATTEMPTS = 500_000;

    struct Input {
        address poolManager;
        bytes32 poolManagerCodeHash;
        TSVBusinessAuthority authority;
        TSVGovernanceAnchor anchor;
        TSVUpgradeTimelock timelock;
        TSVEmergencyUpgradeController controller;
        address sbt;
        bytes32 sbtCodeHash;
        uint256 sbtTokenId;
        uint32 dayStartOffset;
    }

    struct Deployment {
        TSVRegistryV1 registry;
        TSVVolumeLedgerV1 ledger;
        TSVDataInboxV1 inbox;
        TSVSwapRouterV1 router;
        TSVLPManagerV1 lpManager;
        TSVHookV1 hook;
        TSVHookProxyFactoryV1 hookFactory;
        bytes32 hookSalt;
        Implementations implementations;
    }

    struct Implementations {
        address registry;
        address ledger;
        address inbox;
        address router;
        address lpManager;
        address hook;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        Input memory input = _loadInput();
        _checkInput(input);

        vm.startBroadcast(deployerKey);
        _deployBase(input, d);
        vm.stopBroadcast();

        _deployDependent(input, d, deployerKey, deployer);
        _logDeployment(d);
    }

    function _deployBase(Input memory input, Deployment memory d) private {
        d.implementations.registry = address(new TSVRegistryV1());
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.registry,
                    abi.encodeCall(
                        TSVRegistryV1.initialize,
                        (address(input.anchor), address(input.timelock), address(input.controller))
                    )
                )
            )
        );
        d.implementations.ledger = address(new TSVVolumeLedgerV1());
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.ledger,
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize,
                        (
                            address(input.anchor),
                            address(input.timelock),
                            address(input.controller),
                            address(d.registry),
                            input.dayStartOffset
                        )
                    )
                )
            )
        );
        d.implementations.inbox = address(new TSVDataInboxV1());
        d.inbox = TSVDataInboxV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.inbox,
                    abi.encodeCall(
                        TSVDataInboxV1.initialize,
                        (
                            address(input.anchor),
                            address(input.timelock),
                            address(input.controller),
                            address(d.registry),
                            address(d.ledger)
                        )
                    )
                )
            )
        );
        d.implementations.router = address(new TSVSwapRouterV1());
        d.implementations.lpManager = address(new TSVLPManagerV1());
        d.implementations.hook = address(new TSVHookV1());
        d.hookFactory = new TSVHookProxyFactoryV1();
    }

    function _deployDependent(Input memory input, Deployment memory d, uint256 deployerKey, address deployer) private {
        uint64 nextNonce = vm.getNonce(deployer);
        address predictedRouter = vm.computeCreateAddress(deployer, nextNonce);
        address predictedLpManager = vm.computeCreateAddress(deployer, uint256(nextNonce) + 1);
        bytes memory hookInitData = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(input.anchor),
                address(input.timelock),
                address(input.controller),
                input.poolManager,
                address(d.registry),
                address(d.ledger),
                predictedRouter,
                predictedLpManager
            )
        );
        address predictedHook;
        (d.hookSalt, predictedHook) = _mineHook(d.hookFactory, d.implementations.hook, hookInitData);

        vm.startBroadcast(deployerKey);
        d.router = TSVSwapRouterV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.router,
                    abi.encodeCall(
                        TSVSwapRouterV1.initialize,
                        (
                            address(input.anchor),
                            address(input.timelock),
                            address(input.controller),
                            input.poolManager,
                            address(d.registry),
                            address(d.ledger),
                            predictedHook
                        )
                    )
                )
            )
        );
        d.lpManager = TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.lpManager,
                    abi.encodeCall(
                        TSVLPManagerV1.initialize,
                        (
                            address(input.anchor),
                            address(input.timelock),
                            address(input.controller),
                            input.poolManager,
                            address(d.registry)
                        )
                    )
                )
            )
        );
        d.hook = TSVHookV1(d.hookFactory.deploy(d.implementations.hook, hookInitData, d.hookSalt));
        vm.stopBroadcast();

        if (
            address(d.router) != predictedRouter || address(d.lpManager) != predictedLpManager
                || address(d.hook) != predictedHook || (uint160(address(d.hook)) & HOOK_FLAGS) != HOOK_FLAGS
                || TSVERC1967Proxy(payable(address(d.hook))).tsvImplementation() != d.implementations.hook
                || address(d.router.hook()) != address(d.hook) || d.hook.router() != address(d.router)
                || d.hook.lpManager() != address(d.lpManager) || address(d.lpManager.registry()) != address(d.registry)
        ) revert AddressPredictionMismatch();
    }

    function _logDeployment(Deployment memory d) private pure {
        console2.log("Registry", address(d.registry));
        console2.log("VolumeLedger", address(d.ledger));
        console2.log("DataInbox", address(d.inbox));
        console2.log("SwapRouter", address(d.router));
        console2.log("LPManager and Receipt", address(d.lpManager));
        console2.log("Hook", address(d.hook));
        console2.log("HookFactory", address(d.hookFactory));
        console2.log("RegistryImplementation", d.implementations.registry);
        console2.log("VolumeLedgerImplementation", d.implementations.ledger);
        console2.log("DataInboxImplementation", d.implementations.inbox);
        console2.log("SwapRouterImplementation", d.implementations.router);
        console2.log("LPManagerImplementation", d.implementations.lpManager);
        console2.log("HookImplementation", d.implementations.hook);
        console2.log("Hook CREATE2 salt:");
        console2.logBytes32(d.hookSalt);
        console2.log(
            "Governance must bind Anchor proxies, Registry/Ledger, configure SBT and grant roles before opening assets."
        );
    }

    function _loadInput() private view returns (Input memory input) {
        input.poolManager = vm.envAddress("TSV_POOL_MANAGER");
        input.poolManagerCodeHash = vm.envBytes32("TSV_POOL_MANAGER_CODEHASH");
        input.authority = TSVBusinessAuthority(vm.envAddress("TSV_BUSINESS_AUTHORITY"));
        input.anchor = TSVGovernanceAnchor(vm.envAddress("TSV_GOVERNANCE_ANCHOR"));
        input.timelock = TSVUpgradeTimelock(payable(vm.envAddress("TSV_UPGRADE_TIMELOCK")));
        input.controller = TSVEmergencyUpgradeController(vm.envAddress("TSV_EMERGENCY_CONTROLLER"));
        input.sbt = vm.envAddress("TSV_SBT");
        input.sbtCodeHash = vm.envBytes32("TSV_SBT_CODEHASH");
        input.sbtTokenId = vm.envUint("TSV_SBT_TOKEN_ID");
        uint256 offset = vm.envUint("TSV_DAY_START_OFFSET_SECONDS");
        if (offset >= 86_400) revert InvalidDeploymentInput();
        input.dayStartOffset = uint32(offset);
    }

    function _checkInput(Input memory input) private view {
        if (
            block.chainid != vm.envUint("TSV_CHAIN_ID") || input.poolManager.code.length == 0
                || input.poolManagerCodeHash == 0 || input.poolManager.codehash != input.poolManagerCodeHash
                || input.sbt.code.length == 0 || input.sbtCodeHash == 0 || input.sbt.codehash != input.sbtCodeHash
                || address(input.authority).code.length == 0 || address(input.anchor).code.length == 0
                || address(input.timelock).code.length == 0 || address(input.controller).code.length == 0
                || address(input.timelock.businessAuthority()) != address(input.authority)
                || address(input.timelock.emergencyController()) != address(input.controller)
                || address(input.timelock.governanceAnchor()) != address(input.anchor)
                || address(input.anchor.timelock()) != address(input.timelock)
                || address(input.anchor.authority()) != address(input.authority)
                || address(input.anchor.controller()) != address(input.controller)
                || input.anchor.guardian() != input.timelock.guardian()
                || input.anchor.recoveryCouncil() != input.timelock.recoveryCouncil() || input.anchor.proxiesBound()
                || input.authority.upgradeTimelock() != address(input.timelock)
                || input.controller.upgradeTimelock() != address(input.timelock)
                || input.authority.governor() != input.timelock.governor()
                || input.controller.governor() != input.timelock.governor()
                || input.controller.guardian() != input.timelock.guardian() || !input.controller.frozen()
        ) revert InvalidDeploymentInput();
        try ISmartWalletSbtV1(input.sbt).paused() returns (bool) {}
        catch {
            revert InvalidDeploymentInput();
        }
        try ISmartWalletSbtV1(input.sbt).verify(address(this), input.sbtTokenId) returns (bool) {}
        catch {
            revert InvalidDeploymentInput();
        }
    }

    function _mineHook(TSVHookProxyFactoryV1 factory, address implementation, bytes memory initData)
        private
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < MAX_SALT_ATTEMPTS; ++i) {
            salt = bytes32(i);
            predicted = factory.predict(implementation, initData, salt);
            if ((uint160(predicted) & HOOK_FLAGS) == HOOK_FLAGS && predicted.code.length == 0) {
                return (salt, predicted);
            }
        }
        revert HookSaltNotFound();
    }
}
