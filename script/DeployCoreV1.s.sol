// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {ScriptEnvironment} from "./ScriptEnvironment.sol";
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
contract DeployCoreV1 is ScriptEnvironment {
    /// @dev Reverts when the chain, external contracts, code hashes, or governance links are invalid.
    error InvalidDeploymentInput();
    /// @dev Reverts when a deployed address or linked component differs from its prediction.
    error AddressPredictionMismatch();
    /// @dev Reverts when no salt produces a Hook proxy address with all required V4 permission bits.
    error HookSaltNotFound();

    uint160 private constant HOOK_FLAGS = 0x3FFF;
    uint256 private constant MAX_SALT_ATTEMPTS = 500_000;

    /// @dev Captures environment-provided dependencies and configuration for the core deployment.
    struct Input {
        /// @dev V4 PoolManager used by the Hook, Router and LP Manager.
        address poolManager;
        /// @dev Expected deployed bytecode hash for `poolManager`.
        bytes32 poolManagerCodeHash;
        /// @dev Fixed governance root storing identities and the global upgrade switch.
        TSVGovernanceAnchor anchor;
        /// @dev Participant SBT used by the Registry for credential checks.
        address sbt;
        /// @dev Expected deployed bytecode hash for `sbt`.
        bytes32 sbtCodeHash;
        /// @dev SBT token identifier required for participant eligibility.
        uint256 sbtTokenId;
        /// @dev UTC seconds after midnight at which a trade day begins.
        uint32 dayStartOffset;
    }

    /// @dev Collects deployed proxy addresses, implementation addresses and the Hook salt.
    struct Deployment {
        /// @dev Deployed Registry proxy.
        TSVRegistryV1 registry;
        /// @dev Deployed volume Ledger proxy.
        TSVVolumeLedgerV1 ledger;
        /// @dev Deployed report Inbox proxy.
        TSVDataInboxV1 inbox;
        /// @dev Deployed Swap Router proxy.
        TSVSwapRouterV1 router;
        /// @dev Deployed LP Manager proxy.
        TSVLPManagerV1 lpManager;
        /// @dev Deployed Hook proxy.
        TSVHookV1 hook;
        /// @dev Factory used to deploy the Hook proxy.
        TSVHookProxyFactoryV1 hookFactory;
        /// @dev CREATE2 salt that produced the Hook's V4 permission address.
        bytes32 hookSalt;
        /// @dev Implementation addresses corresponding to each proxy.
        Implementations implementations;
    }

    /// @dev Stores implementation addresses corresponding to the core proxy contracts.
    struct Implementations {
        /// @dev Registry implementation address.
        address registry;
        /// @dev Volume Ledger implementation address.
        address ledger;
        /// @dev Data Inbox implementation address.
        address inbox;
        /// @dev Swap Router implementation address.
        address router;
        /// @dev LP Manager implementation address.
        address lpManager;
        /// @dev Hook implementation address.
        address hook;
    }

    /// @notice Deploys and initializes the six core proxy contracts and their implementations.
    /// @dev Reads deployment inputs from the environment and checks the predicted CREATE2 Hook address.
    /// @return d The deployed proxies, Hook factory, salt and implementation addresses.
    function run() external returns (Deployment memory d) {
        uint256 deployerKey = _envUint("TSV_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        Input memory input = _loadInput();
        _checkInput(input);

        vm.startBroadcast(deployerKey);
        _deployBase(input, d);
        vm.stopBroadcast();

        _deployDependent(input, d, deployerKey, deployer);
        _logDeployment(d);
    }

    /// @dev Deploys the Registry, Ledger and Inbox proxies plus implementations for dependent components.
    /// @param input Validated addresses and configuration used to initialize the core proxies.
    /// @param d Deployment record populated with proxy and implementation addresses.
    function _deployBase(Input memory input, Deployment memory d) private {
        d.implementations.registry = address(new TSVRegistryV1());
        d.registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.registry, abi.encodeCall(TSVRegistryV1.initialize, (address(input.anchor)))
                )
            )
        );
        d.implementations.ledger = address(new TSVVolumeLedgerV1());
        d.ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.ledger,
                    abi.encodeCall(
                        TSVVolumeLedgerV1.initialize, (address(input.anchor), address(d.registry), input.dayStartOffset)
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
                        TSVDataInboxV1.initialize, (address(input.anchor), address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.implementations.router = address(new TSVSwapRouterV1());
        d.implementations.lpManager = address(new TSVLPManagerV1());
        d.implementations.hook = address(new TSVHookV1());
        d.hookFactory = new TSVHookProxyFactoryV1();
    }

    /// @dev Predicts dependent proxy addresses, deploys Router, LP Manager and a flag-compatible Hook.
    /// @param input Validated external dependencies and governance configuration.
    /// @param d Deployment record populated by the base deployment stage.
    /// @param deployerKey Private key used to broadcast the dependent deployments.
    /// @param deployer Address whose next CREATE nonces determine Router and LP Manager addresses.
    function _deployDependent(Input memory input, Deployment memory d, uint256 deployerKey, address deployer) private {
        uint64 nextNonce = vm.getNonce(deployer);
        address predictedRouter = vm.computeCreateAddress(deployer, nextNonce);
        address predictedLpManager = vm.computeCreateAddress(deployer, uint256(nextNonce) + 1);
        bytes memory hookInitData = abi.encodeCall(
            TSVHookV1.initialize,
            (
                address(input.anchor),
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
                        (address(input.anchor), input.poolManager, address(d.registry), address(d.ledger))
                    )
                )
            )
        );
        d.lpManager = TSVLPManagerV1(
            address(
                new TSVERC1967Proxy(
                    d.implementations.lpManager,
                    abi.encodeCall(
                        TSVLPManagerV1.initialize, (address(input.anchor), input.poolManager, address(d.registry))
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
                || d.hook.router() != address(d.router) || d.hook.lpManager() != address(d.lpManager)
                || address(d.lpManager.registry()) != address(d.registry)
        ) revert AddressPredictionMismatch();
    }

    /// @dev Prints proxy addresses, implementation addresses, the Hook salt and required follow-up steps.
    /// @param d Deployment record to log.
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

    /// @dev Loads addresses, code hashes, SBT identity and trade-day offset from environment variables.
    /// @return input Deployment configuration read from the environment.
    function _loadInput() internal view returns (Input memory input) {
        input.poolManager = _envAddress("TSV_POOL_MANAGER");
        input.poolManagerCodeHash = _envBytes32("TSV_POOL_MANAGER_CODEHASH");
        input.anchor = TSVGovernanceAnchor(_envAddress("TSV_GOVERNANCE_ANCHOR"));
        input.sbt = _envAddress("TSV_SBT");
        input.sbtCodeHash = _envBytes32("TSV_SBT_CODEHASH");
        input.sbtTokenId = _envUint("TSV_SBT_TOKEN_ID");
        uint256 offset = _envUint("TSV_DAY_START_OFFSET_SECONDS");
        if (offset >= 86_400) revert InvalidDeploymentInput();
        input.dayStartOffset = uint32(offset);
    }

    /// @dev Verifies chain, code hashes and the pre-bound governance relationships before broadcasting.
    /// @param input Deployment configuration to validate.
    function _checkInput(Input memory input) internal view {
        if (
            block.chainid != _envUint("TSV_CHAIN_ID") || input.poolManager.code.length == 0
                || input.poolManagerCodeHash == 0 || input.poolManager.codehash != input.poolManagerCodeHash
                || input.sbt.code.length == 0 || input.sbtCodeHash == 0 || input.sbt.codehash != input.sbtCodeHash
                || address(input.anchor).code.length == 0 || input.anchor.proxiesBound()
                || input.anchor.governor() != _envAddress("TSV_GOVERNOR")
                || input.anchor.guardian() != _envAddress("TSV_GUARDIAN")
                || input.anchor.recoveryCouncil() != _envAddress("TSV_RECOVERY_COUNCIL")
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

    /// @dev Searches salts until the predicted proxy address has the required Uniswap V4 Hook permission bits.
    /// @param factory Factory used to calculate deterministic proxy addresses.
    /// @param implementation Hook implementation used by the proxy.
    /// @param initData Initialization call encoded for the Hook proxy.
    /// @return salt Salt that produces an address with all required Hook flags.
    /// @return predicted Predicted Hook proxy address for the selected salt.
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
