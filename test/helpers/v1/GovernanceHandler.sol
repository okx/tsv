// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVGovernanceAnchor, IAnchoredProxyV1} from "tsv-v1/governance/TSVGovernanceAnchor.sol";

/// @dev Independent authority/state model for randomized sequences, including rejected operations.
contract GovernanceHandler is Test {
    TSVGovernanceAnchor public immutable anchor;
    address public immutable council;
    address public modelGovernor;
    address public modelGuardian;
    address public previousGovernor;
    address public previousGuardian;
    uint64 public modelEpoch;
    uint64 public modelGuardianEpoch;
    uint64 public modelFreezeEpoch;
    bool public modelFrozen;
    bytes32 public modelFreezeId;
    uint256 public successfulUpgrades;
    uint256 public successfulRecoveries;
    uint256 private nextIdentity;
    address[6] public proxies;
    address[6] public expectedImplementations;
    address[6] private originalImplementations;
    address[6] private replacements;
    bytes32[] private proposalIds;

    struct ProposalModel {
        address governor;
        address guardian;
        uint64 epoch;
        uint64 guardianEpoch;
        bool active;
        bool approved;
    }
    mapping(bytes32 => ProposalModel) private proposals;

    constructor(
        TSVGovernanceAnchor root,
        address[6] memory targets,
        address[6] memory originals,
        address[6] memory next
    ) {
        anchor = root;
        council = root.recoveryCouncil();
        modelGovernor = root.governor();
        modelGuardian = root.guardian();
        proxies = targets;
        originalImplementations = originals;
        expectedImplementations = originals;
        replacements = next;
    }

    function propose(uint256 actorSeed, bool rotateGuardian) external {
        address actor = _actor(actorSeed);
        address nextGovernor = address(uint160(0x10000 + ++nextIdentity));
        address nextGuardian = rotateGuardian ? address(uint160(0x10000 + ++nextIdentity)) : modelGuardian;
        bytes32 salt = keccak256(abi.encode(nextIdentity, actorSeed));
        bytes32 id = keccak256(
            abi.encode(block.chainid, address(anchor), modelEpoch, modelGuardianEpoch, nextGovernor, nextGuardian, salt)
        );
        bool allowed = actor == council;
        bytes memory result = _attempt(
            actor,
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.proposeRecovery, (nextGovernor, nextGuardian, salt)),
            allowed
        );
        if (allowed) {
            assertEq(abi.decode(result, (bytes32)), id);
            proposals[id] = ProposalModel(nextGovernor, nextGuardian, modelEpoch, modelGuardianEpoch, true, false);
            proposalIds.push(id);
        }
    }

    function approve(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGuardian && proposal.active && _current(proposal);
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.approveRecovery, (id)), allowed);
        if (allowed) proposal.approved = true;
    }

    function revoke(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGuardian && proposal.approved;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.revokeRecoveryApproval, (id)), allowed);
        if (allowed) proposal.approved = false;
    }

    function cancel(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        address actor = _actor(actorSeed);
        bool allowed = actor == council && proposal.active;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.cancelRecovery, (id)), allowed);
        if (allowed) proposal.active = false;
    }

    function recover(uint256 actorSeed, uint256 proposalSeed) external {
        bytes32 id = _proposal(proposalSeed);
        ProposalModel storage proposal = proposals[id];
        bool allowed = proposal.active && proposal.approved && _current(proposal);
        _attempt(_actor(actorSeed), address(anchor), abi.encodeCall(TSVGovernanceAnchor.executeRecovery, (id)), allowed);
        if (allowed) {
            previousGovernor = modelGovernor;
            modelGovernor = proposal.governor;
            if (modelGuardian != proposal.guardian) {
                previousGuardian = modelGuardian;
                modelGuardian = proposal.guardian;
                ++modelGuardianEpoch;
            }
            ++modelEpoch;
            ++successfulRecoveries;
            proposal.active = false;
            proposal.approved = false;
        }
    }

    function freeze(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGuardian && !modelFrozen;
        bytes memory result =
            _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.freezeUpgrades, ()), allowed);
        if (allowed) {
            ++modelFreezeEpoch;
            modelFrozen = true;
            modelFreezeId = keccak256(abi.encode(block.chainid, address(anchor), modelFreezeEpoch, modelGuardian));
            assertEq(abi.decode(result, (bytes32)), modelFreezeId);
        }
    }

    function unfreeze(uint256 actorSeed, bool wrongIncident) external {
        address actor = _actor(actorSeed);
        bytes32 id = wrongIncident ? keccak256("wrong-incident") : modelFreezeId;
        bool allowed = actor == modelGuardian && modelFrozen && !wrongIncident;
        _attempt(actor, address(anchor), abi.encodeCall(TSVGovernanceAnchor.unfreezeUpgrades, (id)), allowed);
        if (allowed) modelFrozen = false;
    }

    function upgradeSingle(uint256 actorSeed, uint8 proxySeed) external {
        uint256 index = proxySeed % 6;
        address next = _nextImplementation(index);
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGovernor && !modelFrozen;
        _attempt(actor, proxies[index], abi.encodeCall(IAnchoredProxyV1.upgradeToAndCall, (next, bytes(""))), allowed);
        if (allowed) {
            expectedImplementations[index] = next;
            ++successfulUpgrades;
        }
    }

    function upgradeBatch(uint256 actorSeed, uint8 countSeed) external {
        uint256 count = 1 + countSeed % 6;
        address[] memory targets = new address[](count);
        address[] memory implementations = new address[](count);
        for (uint256 i; i < count; ++i) {
            targets[i] = proxies[i];
            implementations[i] = _nextImplementation(i);
        }
        address actor = _actor(actorSeed);
        bool allowed = actor == modelGovernor && !modelFrozen;
        _attempt(
            actor,
            address(anchor),
            abi.encodeCall(TSVGovernanceAnchor.upgradeBatch, (targets, implementations, new bytes[](count))),
            allowed
        );
        if (allowed) {
            for (uint256 i; i < count; ++i) {
                expectedImplementations[i] = implementations[i];
            }
            successfulUpgrades += count;
        }
    }

    function _attempt(address actor, address target, bytes memory data, bool allowed)
        private
        returns (bytes memory result)
    {
        vm.prank(actor);
        bool ok;
        (ok, result) = target.call(data);
        assertEq(ok, allowed, "operation diverged from governance model");
    }

    function _current(ProposalModel storage proposal) private view returns (bool) {
        return proposal.epoch == modelEpoch && proposal.guardianEpoch == modelGuardianEpoch;
    }

    function _proposal(uint256 seed) private view returns (bytes32) {
        return proposalIds.length == 0 ? keccak256("unknown-proposal") : proposalIds[seed % proposalIds.length];
    }

    function _nextImplementation(uint256 index) private view returns (address) {
        return expectedImplementations[index] == originalImplementations[index]
            ? replacements[index]
            : originalImplementations[index];
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 index = seed % 6;
        if (index == 0) return modelGovernor;
        if (index == 1) return modelGuardian;
        if (index == 2) return council;
        if (index == 3) return address(0xDEAD);
        if (index == 4) return previousGovernor == address(0) ? address(0xCAFE) : previousGovernor;
        return previousGuardian == address(0) ? address(0xBABE) : previousGuardian;
    }
}
