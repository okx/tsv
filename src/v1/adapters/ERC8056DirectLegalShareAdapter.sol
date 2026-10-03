// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

interface IERC8056DirectMultiplierSource {
    function decimals() external view returns (uint8);
    function uiMultiplier() external view returns (uint256);
}

/// @notice Converts raw ERC-8056 token amounts using the multiplier active at call time.
contract ERC8056DirectLegalShareAdapter is IDirectLegalShareAdapter {
    error InvalidAdapterConfig();
    error InvalidCurrency();
    error InvalidRate();

    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    constructor(address currency_, uint32 version_) {
        if (currency_ == address(0) || currency_.code.length == 0 || version_ == 0) revert InvalidAdapterConfig();
        uint8 decimals_ = IERC8056DirectMultiplierSource(currency_).decimals();
        if (decimals_ > 18) revert InvalidAdapterConfig();
        poolCurrency = currency_;
        adapterVersion = version_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDirectLegalShareAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Converts raw token units using the multiplier active at this call.
    function toLegalShares(address currency, uint256 rawAmount)
        external
        view
        override
        returns (uint256 legalSharesWad)
    {
        if (rawAmount == 0) return 0;
        (uint256 multiplier, uint8 decimals_) = _currentMultiplier(currency);
        legalSharesWad = Math.mulDiv(rawAmount, multiplier, 10 ** uint256(decimals_));
        if (legalSharesWad == 0) revert InvalidRate();
    }

    function _currentMultiplier(address currency) private view returns (uint256 multiplier, uint8 decimals_) {
        if (currency != poolCurrency) revert InvalidCurrency();

        IERC8056DirectMultiplierSource token = IERC8056DirectMultiplierSource(currency);
        multiplier = token.uiMultiplier();
        decimals_ = token.decimals();

        if (multiplier == 0 || decimals_ > 18) revert InvalidAdapterConfig();
    }
}
