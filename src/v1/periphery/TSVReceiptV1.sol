// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";

contract TSVReceiptV1 is TSVGoverned, ERC721Upgradeable {
    error NonTransferable();
    error UnauthorizedManager();

    address public lpManager;

    function initialize(address authority, address timelock, address controller, address manager_)
        external
        initializer
    {
        __TSVGoverned_init(authority, timelock, controller);
        if (manager_ == address(0)) revert UnauthorizedManager();
        __ERC721_init("TSV LP Receipt", "TSVLP");
        lpManager = manager_;
    }

    function mint(address owner, uint256 positionId) external {
        if (msg.sender != lpManager) revert UnauthorizedManager();
        _mint(owner, positionId);
    }

    function burn(uint256 positionId) external {
        if (msg.sender != lpManager) revert UnauthorizedManager();
        _burn(positionId);
    }

    function approve(address, uint256) public pure override {
        revert NonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override {
        revert NonTransferable();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert NonTransferable();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
