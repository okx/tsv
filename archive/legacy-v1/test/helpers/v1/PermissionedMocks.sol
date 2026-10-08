// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAllowlistChecker, IERC165} from "v4-periphery/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag, PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @dev Issuer-owned policy fixture. It neither calls nor depends on TSV Registry or SBT.
contract V1IssuerAllowlistChecker is IAllowlistChecker {
    mapping(address => mapping(address => PermissionFlag)) private accountPermissions;
    mapping(address => mapping(address => bool)) private configured;
    bool public failReads;

    function setPermissions(address account, address token, PermissionFlag permissions) external {
        configured[account][token] = true;
        accountPermissions[account][token] = permissions;
    }

    function setFailReads(bool value) external {
        failReads = value;
    }

    function checkAllowlist(address account, address token) external view returns (PermissionFlag) {
        require(!failReads, "issuer checker unavailable");
        return configured[account][token]
            ? accountPermissions[account][token]
            : PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IAllowlistChecker).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev Component identity fixture; no swap or LP execution is provided.
contract V1PermissionedComponent {
    address public immutable poolManager;
    address public immutable registry;
    address public immutable PERMISSIONS_ADAPTER_FACTORY;
    address public router;
    address public lpManager;
    address public ledger;

    constructor(address pm, address r, address factory) {
        poolManager = pm;
        registry = r;
        PERMISSIONS_ADAPTER_FACTORY = factory;
    }

    function setLinks(address router_, address lp_, address ledger_) external {
        router = router_;
        lpManager = lp_;
        ledger = ledger_;
    }
}

/// @dev Distinct contract receiver for exit configuration and ownership rotation tests.
contract V1ConfigReceiver {
    function execute(address target, bytes calldata payload) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
}
