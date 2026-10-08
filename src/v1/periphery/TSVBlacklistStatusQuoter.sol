// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStatusQuoter} from "../interfaces/IStatusQuoter.sol";
import {IBlacklistStatus} from "../interfaces/IBlacklistStatus.sol";

/// @notice Authorizes forced exits only for accounts on the configured issuer blacklist.
contract TSVBlacklistStatusQuoter is IStatusQuoter {
    error InvalidBlacklist();

    IBlacklistStatus public immutable blacklist;

    constructor(IBlacklistStatus blacklist_) {
        if (address(blacklist_).code.length == 0) revert InvalidBlacklist();
        blacklist = blacklist_;
    }

    /// @dev Query failures revert rather than authorizing an exit.
    function isUnwindable(address account) external view returns (bool) {
        return blacklist.isBlacklisted(account);
    }
}
