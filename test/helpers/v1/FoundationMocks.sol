// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Provides a basic ERC-20 token fixture for unit tests.
contract V1MockToken is ERC20 {
    uint8 private immutable tokenDecimals;

    /// @dev Creates a test token with the requested name and decimal precision.
    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        tokenDecimals = decimals_;
    }

    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    /// @dev Returns the test multiplier used to convert displayed balances.
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }
}

/// @dev Provides a deliberately incomplete adapter fixture for validation tests.
contract V1SnapshotOnlyAdapterMock {
    address public immutable poolCurrency;
    uint32 public immutable adapterVersion;

    /// @dev Configures the currency and version exposed by the incomplete adapter fixture.
    constructor(address currency_, uint32 version_) {
        poolCurrency = currency_;
        adapterVersion = version_;
    }
}
