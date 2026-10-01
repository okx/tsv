// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Direct conversion interface used by Hook swap accounting.
interface IDirectLegalShareAdapter is IERC165 {
    function poolCurrency() external view returns (address);
    function adapterVersion() external view returns (uint32);
    function toLegalShares(address currency, uint256 rawAmount) external view returns (uint256 legalSharesWad);
}
