// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";

interface ISmartWalletSbtV1 {
    function verify(address user, uint256 tokenId) external view returns (bool);
    function paused() external view returns (bool);
}

contract TSVSBTAdapterV1 is TSVGoverned {
    error InvalidSBT();

    ISmartWalletSbtV1 public sbt;
    uint256 public tokenId;

    event SbtConfigChanged(
        address indexed oldSbt, address indexed newSbt, uint256 oldTokenId, uint256 newTokenId, bytes32 evidenceHash
    );

    function initialize(address authority, address timelock, address controller, address sbt_, uint256 tokenId_)
        external
        initializer
    {
        __TSVGoverned_init(authority, timelock, controller);
        if (sbt_.code.length == 0) revert InvalidSBT();
        sbt = ISmartWalletSbtV1(sbt_);
        tokenId = tokenId_;
    }

    function setSbtConfig(address sbt_, uint256 tokenId_, bytes32 evidenceHash) external onlyGovernor {
        if (sbt_.code.length == 0 || evidenceHash == 0) revert InvalidSBT();
        address oldSbt = address(sbt);
        uint256 oldId = tokenId;
        sbt = ISmartWalletSbtV1(sbt_);
        tokenId = tokenId_;
        emit SbtConfigChanged(oldSbt, sbt_, oldId, tokenId_, evidenceHash);
    }

    function hasCredential(address owner) public view returns (bool) {
        return sbt.verify(owner, tokenId);
    }

    function isEligible(address owner) external view returns (bool) {
        return !sbt.paused() && hasCredential(owner);
    }
}
