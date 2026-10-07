// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Component identity fixture; no swap or LP execution is provided.
contract V1PermissionedComponent {
    address public immutable poolManager;
    address public immutable registry;
    address public immutable PERMISSIONS_ADAPTER_FACTORY;
    address public router;
    address public lpManager;
    address public ledger;

    constructor(address pm, address r) {
        poolManager = pm;
        registry = r;
        PERMISSIONS_ADAPTER_FACTORY = r;
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
