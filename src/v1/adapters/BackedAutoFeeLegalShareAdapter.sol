// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

/// @dev Exposes share-to-underlying conversion data from the issuer token.
interface IBackedShareConversionSource {
    /// @notice Returns the number of decimals used by the issuer's share representation.
    function decimals() external view returns (uint8);

    /// @notice Converts a wrapped-share amount to its underlying legal-share amount.
    function getUnderlyingAmountByShares(uint256 sharesAmount) external view returns (uint256 underlyingAmount);

    /// @notice Returns the current multiplier used by the issuer's share conversion.
    function getCurrentMultiplier()
        external
        view
        returns (uint256 currentMultiplier, uint256 periodsPassed, uint256 nonce);
}

/// @dev Exposes the underlying asset associated with the wrapped token.
interface IBackedWrappedAsset {
    /// @notice Returns the underlying asset represented by this wrapped token.
    function asset() external view returns (address);

    /// @notice Returns the wrapped token's decimal precision.
    function decimals() external view returns (uint8);
}

/// @notice Converts wrapped Backed shares by calling the issuer token's live conversion method.
/// @dev The returned underlying amount is the legal-share amount in WAD for the reviewed wTSLAx setup.
contract BackedAutoFeeLegalShareAdapter is IDirectLegalShareAdapter {
    /// @dev Reverts when the adapter configuration is invalid or incomplete.
    error InvalidAdapterConfig();
    /// @dev Reverts when the requested Currency does not match the configured adapter Currency.
    error InvalidCurrency();
    /// @dev Reverts when the issuer conversion returned an invalid legal-share amount.
    error InvalidConversion();

    address public immutable userToken;
    address public immutable override poolCurrency;

    /// @notice Binds the wrapped pool currency to its issuer conversion source.
    /// @param underlying_ Issuer token that exposes the live share conversion method.
    /// @param wrapped_ Token used as the pool currency and returned by the issuer wrapper.
    constructor(address underlying_, address wrapped_) {
        if (
            underlying_ == address(0) || wrapped_ == address(0) || underlying_ == wrapped_
                || underlying_.code.length == 0 || wrapped_.code.length == 0
        ) revert InvalidAdapterConfig();
        if (
            IBackedWrappedAsset(wrapped_).asset() != underlying_
                || IBackedShareConversionSource(underlying_).decimals() != 18
                || IBackedWrappedAsset(wrapped_).decimals() != 18
        ) revert InvalidAdapterConfig();
        userToken = underlying_;
        poolCurrency = wrapped_;
    }

    /// @notice Reports support for the direct legal-share adapter and ERC-165 interfaces.
    /// @param interfaceId Interface identifier to check.
    /// @return True when this adapter implements the requested interface.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDirectLegalShareAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Returns the live issuer multiplier used for the bound pool Currency.
    function currentMultiplier(address currency) external view override returns (uint256 multiplier) {
        if (currency != poolCurrency) revert InvalidCurrency();
        (multiplier,,) = IBackedShareConversionSource(userToken).getCurrentMultiplier();
        if (multiplier == 0) revert InvalidConversion();
    }

    /// @notice Converts a pool-currency amount to its live legal-share amount in WAD.
    /// @param currency Currency supplied by the caller; must equal `poolCurrency`.
    /// @param rawAmount Amount in the pool currency's raw units.
    /// @return legalSharesWad Underlying legal shares returned by the issuer conversion source.
    function toLegalShares(address currency, uint256 rawAmount)
        external
        view
        override
        returns (uint256 legalSharesWad)
    {
        if (currency != poolCurrency) revert InvalidCurrency();
        if (rawAmount == 0) return 0;

        legalSharesWad = IBackedShareConversionSource(userToken).getUnderlyingAmountByShares(rawAmount);
        if (legalSharesWad == 0) revert InvalidConversion();
    }
}
