// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RawBoundMode} from "tsv-v1/types/TSVTypes.sol";

/// @notice Shared integer conversion and inverse-bound math for legal-share adapters.
library LegalShareMath {
    error InvalidRate();

    function toLegalSharesCeil(uint256 rawAmount, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 amount)
    {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        amount = Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Ceil);
        if (amount == 0) revert InvalidRate();
    }

    function toLegalSharesFloor(uint256 rawAmount, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 amount)
    {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        amount = Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Floor);
        if (amount == 0) revert InvalidRate();
    }

    function rawForLegalSharesCeil(uint256 legalShares, uint256 numerator, uint256 denominator, RawBoundMode mode)
        internal
        pure
        returns (uint256 rawAmount)
    {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        if (legalShares == 0) return 0;

        if (mode == RawBoundMode.MIN_RAW_FOR_AT_LEAST_SHARES) {
            rawAmount = Math.mulDiv(legalShares - 1, denominator, numerator) + 1;
            if (Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Ceil) < legalShares) {
                revert InvalidRate();
            }
            if (rawAmount > 0 && Math.mulDiv(rawAmount - 1, numerator, denominator, Math.Rounding.Ceil) >= legalShares) revert InvalidRate();
        } else if (mode == RawBoundMode.MAX_RAW_FOR_AT_MOST_SHARES) {
            rawAmount = Math.mulDiv(legalShares, denominator, numerator);
            if (Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Ceil) > legalShares) {
                revert InvalidRate();
            }
            if (
                rawAmount < type(uint256).max
                    && Math.mulDiv(rawAmount + 1, numerator, denominator, Math.Rounding.Ceil) <= legalShares
            ) revert InvalidRate();
        } else {
            revert InvalidRate();
        }
    }

    function rawForLegalSharesFloor(uint256 legalShares, uint256 numerator, uint256 denominator, RawBoundMode mode)
        internal
        pure
        returns (uint256 rawAmount)
    {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        if (legalShares == 0) return 0;

        if (mode == RawBoundMode.MIN_RAW_FOR_AT_LEAST_SHARES) {
            rawAmount = Math.mulDiv(legalShares, denominator, numerator, Math.Rounding.Ceil);
            if (Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Floor) < legalShares) {
                revert InvalidRate();
            }
            if (rawAmount > 0 && Math.mulDiv(rawAmount - 1, numerator, denominator, Math.Rounding.Floor) >= legalShares)
            {
                revert InvalidRate();
            }
        } else if (mode == RawBoundMode.MAX_RAW_FOR_AT_MOST_SHARES) {
            if (legalShares == type(uint256).max) revert InvalidRate();
            rawAmount = Math.mulDiv(legalShares + 1, denominator, numerator, Math.Rounding.Ceil) - 1;
            if (Math.mulDiv(rawAmount, numerator, denominator, Math.Rounding.Floor) > legalShares) {
                revert InvalidRate();
            }
            if (
                rawAmount < type(uint256).max
                    && Math.mulDiv(rawAmount + 1, numerator, denominator, Math.Rounding.Floor) <= legalShares
            ) revert InvalidRate();
        } else {
            revert InvalidRate();
        }
    }
}
