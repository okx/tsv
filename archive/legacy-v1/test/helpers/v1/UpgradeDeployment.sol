// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryV2, LedgerV2, InboxV2, HookV2, RouterV2, LPManagerV2} from "./GovernanceUpgradeMocks.sol";

/// @dev Matching V2 implementations in the canonical six-component binding order.
library UpgradeDeployment {
    function deployV2(address pm, address factory) internal returns (address[6] memory implementations) {
        return [
            address(new RegistryV2()),
            address(new LedgerV2()),
            address(new InboxV2()),
            address(new HookV2()),
            address(new RouterV2(pm, factory)),
            address(new LPManagerV2())
        ];
    }
}
