// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateSnapshot, RoundingMode, LegalShareMode, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";
import {ILegalShareAdapter} from "tsv-v1/interfaces/ILegalShareAdapter.sol";
import {LegalShareMath} from "tsv-v1/libraries/LegalShareMath.sol";

interface IBackedMultiplier {
    function getCurrentMultiplier()
        external
        view
        returns (uint256 currentMultiplier, uint256 periodsPassed, uint256 currentMultiplierNonce);
}

/// @notice Technical display-unit accounting. Listing still requires issuer/legal approval.
contract BackedAutoFeeLegalShareAdapter is ILegalShareAdapter {
    error InvalidRate();

    address public immutable userToken;
    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    constructor(address underlying_, address wrapped_, uint32 version_) {
        if (underlying_ == address(0) || wrapped_ == address(0) || underlying_ == wrapped_ || version_ == 0) {
            revert InvalidRate();
        }
        userToken = underlying_;
        poolCurrency = wrapped_;
        adapterVersion = version_;
    }

    function legalShareMode() external pure returns (LegalShareMode) {
        return LegalShareMode.ONCHAIN_DYNAMIC;
    }

    function snapshot(address currency) public view returns (RateSnapshot memory rate) {
        if (currency != poolCurrency) revert InvalidRate();
        (uint256 multiplier,, uint256 nonce) = IBackedMultiplier(userToken).getCurrentMultiplier();
        if (multiplier == 0) revert InvalidRate();
        rate = RateSnapshot(
            keccak256(abi.encode(userToken, multiplier, nonce, adapterVersion)),
            multiplier,
            1e18,
            adapterVersion,
            RoundingMode.FLOOR
        );
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
        amount = LegalShareMath.toLegalSharesFloor(rawAmount, rate.numerator, rate.denominator);
    }

    function rawForLegalShares(address currency, uint256 legalSharesWad, RateSnapshot calldata rate, RawBoundMode mode)
        external
        view
        returns (uint256 rawAmount)
    {
        RateSnapshot memory expected = snapshot(currency);
        if (keccak256(abi.encode(rate)) != keccak256(abi.encode(expected))) revert InvalidRate();
        rawAmount = LegalShareMath.rawForLegalSharesFloor(legalSharesWad, rate.numerator, rate.denominator, mode);
    }
}
