// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateSnapshot, RoundingMode, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";
import {ILegalShareAdapter} from "tsv-v1/interfaces/ILegalShareAdapter.sol";
import {LegalShareMath} from "tsv-v1/libraries/LegalShareMath.sol";

contract StaticLegalShareAdapter is ILegalShareAdapter {
    error InvalidRate();

    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;
    uint256 public immutable sharesPerWholeTokenWad;
    uint256 public immutable denominator;
    bytes32 public immutable rateId;

    constructor(address currency_, uint8 decimals_, uint256 ratio_, uint32 version_) {
        if (currency_ == address(0) || decimals_ > 18 || ratio_ == 0 || version_ == 0) revert InvalidRate();
        poolCurrency = currency_;
        adapterVersion = version_;
        sharesPerWholeTokenWad = ratio_;
        denominator = 10 ** decimals_;
        rateId = keccak256(abi.encode(currency_, ratio_, decimals_, version_));
    }

    function snapshot(address currency) public view returns (RateSnapshot memory rate) {
        if (currency != poolCurrency) revert InvalidRate();
        rate = RateSnapshot(rateId, sharesPerWholeTokenWad, denominator, adapterVersion, RoundingMode.CEIL);
    }

    function isCurrent(address currency, RateSnapshot calldata rate) external view returns (bool) {
        RateSnapshot memory expected = snapshot(currency);
        return keccak256(abi.encode(rate)) == keccak256(abi.encode(expected));
    }

    function toLegalShares(address currency, uint256 rawAmount, RateSnapshot calldata rate)
        external
        view
        returns (uint256 amount)
    {
        RateSnapshot memory expected = snapshot(currency);
        if (keccak256(abi.encode(rate)) != keccak256(abi.encode(expected))) revert InvalidRate();
        amount = LegalShareMath.toLegalSharesCeil(rawAmount, rate.numerator, rate.denominator);
    }

    function rawForLegalShares(address currency, uint256 legalSharesWad, RateSnapshot calldata rate, RawBoundMode mode)
        external
        view
        returns (uint256 rawAmount)
    {
        RateSnapshot memory expected = snapshot(currency);
        if (keccak256(abi.encode(rate)) != keccak256(abi.encode(expected))) revert InvalidRate();
        rawAmount = LegalShareMath.rawForLegalSharesCeil(legalSharesWad, rate.numerator, rate.denominator, mode);
    }
}
