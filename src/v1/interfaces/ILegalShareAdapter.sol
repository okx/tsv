// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateSnapshot, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";

interface ILegalShareAdapter {
    function poolCurrency() external view returns (address);
    function adapterVersion() external view returns (uint32);
    function snapshot(address currency) external view returns (RateSnapshot memory);
    function toLegalShares(address currency, uint256 rawAmount, RateSnapshot calldata rate)
        external
        view
        returns (uint256);
    function rawForLegalShares(address currency, uint256 legalSharesWad, RateSnapshot calldata rate, RawBoundMode mode)
        external
        view
        returns (uint256 rawAmount);
    function isCurrent(address currency, RateSnapshot calldata rate) external view returns (bool);
}
