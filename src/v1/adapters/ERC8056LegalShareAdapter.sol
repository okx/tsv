// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateSnapshot, RoundingMode, LegalShareMode, RawBoundMode} from "tsv-v1/types/TSVTypes.sol";
import {ILegalShareAdapter} from "tsv-v1/interfaces/ILegalShareAdapter.sol";
import {LegalShareMath} from "tsv-v1/libraries/LegalShareMath.sol";

interface IERC8056MultiplierSource {
    function decimals() external view returns (uint8);
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/// @notice Converts raw ERC-8056 token amounts using the current on-chain UI multiplier.
/// @dev This formula is technical plumbing only. Listing still requires issuer/legal approval.
contract ERC8056LegalShareAdapter is ILegalShareAdapter {
    error InvalidRate();

    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    constructor(address currency_, uint32 version_) {
        if (currency_ == address(0) || currency_.code.length == 0 || version_ == 0) revert InvalidRate();
        uint8 decimals_ = IERC8056MultiplierSource(currency_).decimals();
        if (decimals_ > 18) revert InvalidRate();
        poolCurrency = currency_;
        adapterVersion = version_;
    }

    function legalShareMode() external pure returns (LegalShareMode) {
        return LegalShareMode.ONCHAIN_DYNAMIC;
    }

    function snapshot(address currency) public view returns (RateSnapshot memory rate) {
        if (currency != poolCurrency) revert InvalidRate();
        IERC8056MultiplierSource token = IERC8056MultiplierSource(currency);
        uint256 multiplier = token.uiMultiplier();
        uint256 pendingMultiplier = token.newUIMultiplier();
        uint256 effectiveAt_ = token.effectiveAt();
        uint8 decimals_ = token.decimals();
        if (multiplier == 0 || pendingMultiplier == 0 || decimals_ > 18) revert InvalidRate();
        // A different pending multiplier must carry a concrete activation time.
        // This rejects malformed ERC-8056-like tokens without making the
        // pending value part of the active rate identity.
        if (pendingMultiplier != multiplier && effectiveAt_ == 0) revert InvalidRate();

        // The snapshot identifies the multiplier that is active for this call.
        // A scheduled-but-not-yet-effective multiplier must not make the current
        // snapshot stale; it becomes a new snapshot only once uiMultiplier()
        // starts returning it at the issuer-defined effective time.
        rate = RateSnapshot(
            keccak256(abi.encode(currency, multiplier, decimals_, adapterVersion)),
            multiplier,
            10 ** decimals_,
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
        returns (uint256 legalSharesWad)
    {
        RateSnapshot memory expected = snapshot(currency);
        if (keccak256(abi.encode(rate)) != keccak256(abi.encode(expected))) revert InvalidRate();
        legalSharesWad = LegalShareMath.toLegalSharesFloor(rawAmount, rate.numerator, rate.denominator);
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
