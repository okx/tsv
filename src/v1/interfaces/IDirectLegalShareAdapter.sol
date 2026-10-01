// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Direct conversion interface used by Hook swap accounting.
interface IDirectLegalShareAdapter is IERC165 {
    /// @notice Returns the pool Currency to which this adapter is bound.
    function poolCurrency() external view returns (address);

    /// @notice Returns the reviewed conversion-policy version.
    function adapterVersion() external view returns (uint32);

    /// @notice Converts an amount of the bound Currency into legal shares expressed in WAD.
    /// @param currency Currency being converted; implementations must enforce their configured asset.
    /// @param rawAmount Amount of Currency in its raw token units.
    /// @return legalSharesWad Legal-share amount used by TSV volume accounting.
    function toLegalShares(address currency, uint256 rawAmount) external view returns (uint256 legalSharesWad);
}
