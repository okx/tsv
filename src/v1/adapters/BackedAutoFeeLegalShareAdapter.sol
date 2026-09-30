// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RateSnapshot, RoundingMode, LegalShareMode, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";
import {ILegalShareAdapter} from "tsv-v1/interfaces/ILegalShareAdapter.sol";

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
        amount = Math.mulDiv(rawAmount, rate.numerator, rate.denominator, Math.Rounding.Floor);
        if (amount == 0) revert InvalidRate();
    }

    function rawForLegalShares(address currency, uint256 legalSharesWad, RateSnapshot calldata rate, RawBoundMode mode)
        external
        view
        returns (uint256 rawAmount)
    {
        RateSnapshot memory expected = snapshot(currency);
        if (keccak256(abi.encode(rate)) != keccak256(abi.encode(expected))) revert InvalidRate();
        if (legalSharesWad == 0) return 0;

        if (mode == RawBoundMode.MIN_RAW_FOR_AT_LEAST_SHARES) {
            rawAmount = Math.mulDiv(legalSharesWad, rate.denominator, rate.numerator, Math.Rounding.Ceil);
            if (Math.mulDiv(rawAmount, rate.numerator, rate.denominator, Math.Rounding.Floor) < legalSharesWad) {
                revert InvalidRate();
            }
            if (
                rawAmount > 0
                    && Math.mulDiv(rawAmount - 1, rate.numerator, rate.denominator, Math.Rounding.Floor)
                        >= legalSharesWad
            ) {
                revert InvalidRate();
            }
        } else if (mode == RawBoundMode.MAX_RAW_FOR_AT_MOST_SHARES) {
            if (legalSharesWad == type(uint256).max) revert InvalidRate();
            rawAmount = Math.mulDiv(legalSharesWad + 1, rate.denominator, rate.numerator, Math.Rounding.Ceil) - 1;
            if (Math.mulDiv(rawAmount, rate.numerator, rate.denominator, Math.Rounding.Floor) > legalSharesWad) {
                revert InvalidRate();
            }
            if (
                rawAmount < type(uint256).max
                    && Math.mulDiv(rawAmount + 1, rate.numerator, rate.denominator, Math.Rounding.Floor)
                        <= legalSharesWad
            ) {
                revert InvalidRate();
            }
        } else {
            revert InvalidRate();
        }
    }
}
