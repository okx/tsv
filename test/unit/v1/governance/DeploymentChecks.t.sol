// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "../../../helpers/v1/ProtocolFixture.sol";
import {DeployGovernanceV1} from "../../../../script/DeployGovernanceV1.s.sol";
import {DeployCoreV1} from "../../../../script/DeployCoreV1.s.sol";
import {VerifyDeploymentV1} from "../../../../script/VerifyDeploymentV1.s.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";

/// @dev Per-instance inputs avoid process-global environment races between parallel tests.
abstract contract ScriptInputStore {
    mapping(string => string) private inputs;

    function setInput(string memory name, string memory value) external {
        inputs[name] = value;
    }

    function _input(string memory name) internal view returns (string memory) {
        return inputs[name];
    }
}

contract DeployCoreValidationHarness is DeployCoreV1, ScriptInputStore {
    function checkEnvironment() external view {
        _checkInput(_loadInput());
    }

    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

contract VerifyDeploymentHarness is VerifyDeploymentV1, ScriptInputStore {
    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

contract GovernanceDeploymentHarness is DeployGovernanceV1, ScriptInputStore {
    function _envAddress(string memory name) internal view override returns (address) {
        return vm.parseAddress(_input(name));
    }

    function _envBytes32(string memory name) internal view override returns (bytes32) {
        return vm.parseBytes32(_input(name));
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        return vm.parseUint(_input(name));
    }
}

/// @dev Actual deployment validators and manifest verification against the local protocol fixture.
contract TSVDeploymentChecksTest is ProtocolFixture {
    DeployCoreValidationHarness internal coreValidator;
    VerifyDeploymentHarness internal verifier;

    function setUp() public override {
        super.setUp();
        coreValidator = new DeployCoreValidationHarness();
        verifier = new VerifyDeploymentHarness();
        _setEnvironment();
    }

    function testCoreDeploymentAcceptsValidUnboundEnvironment() public view {
        coreValidator.checkEnvironment();
    }

    function testCoreDeploymentRejectsWrongChain() public {
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsAlreadyBoundAnchor() public {
        anchor.bindProxies(_proxies());
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsMissingExternalCode() public {
        _setInput("TSV_POOL_MANAGER", vm.toString(makeAddr("missing-pool-manager")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_SBT", vm.toString(makeAddr("missing-sbt")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_GOVERNANCE_ANCHOR", vm.toString(makeAddr("missing-anchor")));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsWrongExternalCodeHashes() public {
        _setInput("TSV_POOL_MANAGER_CODEHASH", vm.toString(keccak256("wrong-manager-code")));
        _expectInvalidCoreInput();
        _setEnvironment();
        _setInput("TSV_SBT_CODEHASH", vm.toString(keccak256("wrong-sbt-code")));
        _expectInvalidCoreInput();
    }

    function testCoreDeploymentRejectsEveryMismatchedGovernanceIdentity() public {
        string[3] memory names = ["TSV_GOVERNOR", "TSV_GUARDIAN", "TSV_RECOVERY_COUNCIL"];
        for (uint256 i; i < names.length; ++i) {
            _setInput(names[i], vm.toString(makeAddr("unexpected-identity")));
            _expectInvalidCoreInput();
            _setEnvironment();
        }
    }

    function testCoreDeploymentRejectsFailingSbtSelectors() public {
        sbt.setFailReads(false, true);
        _expectInvalidCoreInput();
        sbt.setFailReads(true, false);
        _expectInvalidCoreInput();
    }

    function testFuzzCoreDeploymentRejectsOffsetOutsideOneDay(uint64 offset) public {
        _setInput("TSV_DAY_START_OFFSET_SECONDS", vm.toString(bound(offset, 86_400, type(uint64).max)));
        _expectInvalidCoreInput();
    }

    function testGovernanceDeploymentRejectsWrongChainBeforeBroadcast() public {
        GovernanceDeploymentHarness deployer = new GovernanceDeploymentHarness();
        deployer.setInput("TSV_GOVERNOR", vm.toString(anchor.governor()));
        deployer.setInput("TSV_GUARDIAN", vm.toString(anchor.guardian()));
        deployer.setInput("TSV_RECOVERY_COUNCIL", vm.toString(anchor.recoveryCouncil()));
        // Zero is intentionally invalid and unused: the chain guard runs before broadcasting.
        deployer.setInput("TSV_DEPLOYER_PRIVATE_KEY", "0");
        deployer.setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert(DeployGovernanceV1.InvalidDeploymentInput.selector);
        deployer.run();
    }

    function testVerifierAcceptsCorrectBoundDeployment() public {
        anchor.bindProxies(_proxies());
        verifier.run();
    }

    function testVerifierRejectsUnboundAnchor() public {
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testVerifierRejectsWrongChainAndProxyOrder() public {
        anchor.bindProxies(_proxies());
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
        _setEnvironment();
        _setInput("TSV_REGISTRY", vm.toString(address(ledger)));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testFuzzVerifierRejectsWrongImplementationAtAnyProxy(uint8 index) public {
        index = uint8(bound(index, 0, 5));
        anchor.bindProxies(_proxies());
        _setInput(string.concat(_proxyEnvName(index), "_IMPLEMENTATION"), vm.toString(makeAddr("wrong-implementation")));
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testFuzzVerifierRejectsWrongImplementationCodeHashAtAnyProxy(uint8 index) public {
        index = uint8(bound(index, 0, 5));
        anchor.bindProxies(_proxies());
        _setInput(
            string.concat(_proxyEnvName(index), "_IMPLEMENTATION_CODEHASH"), vm.toString(keccak256("wrong-code-hash"))
        );
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
    }

    function testVerifierRejectsStaleIdentityManifestAfterRecovery() public {
        anchor.bindProxies(_proxies());
        address next = makeAddr("next-governor");
        address currentGuardian = anchor.guardian();
        vm.prank(anchor.recoveryCouncil());
        bytes32 id = anchor.proposeRecovery(next, currentGuardian, keccak256("manifest"), keccak256("evidence"));
        vm.prank(anchor.guardian());
        anchor.approveRecovery(id);
        anchor.executeRecovery(id);
        vm.expectRevert(VerifyDeploymentV1.VerificationFailed.selector);
        verifier.run();
        _setInput("TSV_GOVERNOR", vm.toString(next));
        verifier.run();
    }

    function _expectInvalidCoreInput() private {
        vm.expectRevert(DeployCoreV1.InvalidDeploymentInput.selector);
        coreValidator.checkEnvironment();
    }

    function _setInput(string memory name, string memory value) private {
        coreValidator.setInput(name, value);
        verifier.setInput(name, value);
    }

    function _setEnvironment() private {
        _setInput("TSV_CHAIN_ID", vm.toString(block.chainid));
        _setInput("TSV_GOVERNANCE_ANCHOR", vm.toString(address(anchor)));
        _setInput("TSV_GOVERNOR", vm.toString(anchor.governor()));
        _setInput("TSV_GUARDIAN", vm.toString(anchor.guardian()));
        _setInput("TSV_RECOVERY_COUNCIL", vm.toString(anchor.recoveryCouncil()));
        _setInput("TSV_POOL_MANAGER", vm.toString(address(manager)));
        _setInput("TSV_POOL_MANAGER_CODEHASH", vm.toString(address(manager).codehash));
        _setInput("TSV_SBT", vm.toString(address(sbt)));
        _setInput("TSV_SBT_CODEHASH", vm.toString(address(sbt).codehash));
        _setInput("TSV_SBT_TOKEN_ID", "1");
        _setInput("TSV_DAY_START_OFFSET_SECONDS", "14400");
        address[6] memory proxies = _proxies();
        for (uint256 i; i < 6; ++i) {
            address implementation = TSVERC1967Proxy(payable(proxies[i])).tsvImplementation();
            string memory name = _proxyEnvName(i);
            _setInput(name, vm.toString(proxies[i]));
            _setInput(string.concat(name, "_IMPLEMENTATION"), vm.toString(implementation));
            _setInput(string.concat(name, "_IMPLEMENTATION_CODEHASH"), vm.toString(implementation.codehash));
        }
    }

    function _proxies() private view returns (address[6] memory) {
        return [address(registry), address(ledger), address(inbox), address(hook), address(router), address(lpManager)];
    }

    function _proxyEnvName(uint256 index) private pure returns (string memory) {
        string[6] memory names =
            ["TSV_REGISTRY", "TSV_VOLUME_LEDGER", "TSV_DATA_INBOX", "TSV_HOOK", "TSV_SWAP_ROUTER", "TSV_LP_MANAGER"];
        return names[index];
    }
}
