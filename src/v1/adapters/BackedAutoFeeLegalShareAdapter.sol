// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDirectLegalShareAdapter} from "tsv-v1/interfaces/IDirectLegalShareAdapter.sol";

interface IBackedShareConversionSource {
    function decimals() external view returns (uint8);
    function getUnderlyingAmountByShares(uint256 sharesAmount) external view returns (uint256 underlyingAmount);
}

interface IBackedWrappedAsset {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
}

/// @notice Converts wrapped Backed shares by calling the issuer token's live conversion method.
/// @dev The returned underlying amount is the legal-share amount in WAD for the reviewed wTSLAx setup.
contract BackedAutoFeeLegalShareAdapter is IDirectLegalShareAdapter {
    error InvalidAdapterConfig();
    error InvalidCurrency();
    error InvalidConversion();

    address public immutable userToken;
    address public immutable override poolCurrency;
    uint32 public immutable override adapterVersion;

    constructor(address underlying_, address wrapped_, uint32 version_) {
        if (
            underlying_ == address(0) || wrapped_ == address(0) || underlying_ == wrapped_ || version_ == 0
                || underlying_.code.length == 0 || wrapped_.code.length == 0
        ) revert InvalidAdapterConfig();
        if (
            IBackedWrappedAsset(wrapped_).asset() != underlying_
                || IBackedShareConversionSource(underlying_).decimals() != 18
                || IBackedWrappedAsset(wrapped_).decimals() != 18
        ) revert InvalidAdapterConfig();
        userToken = underlying_;
        poolCurrency = wrapped_;
        adapterVersion = version_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDirectLegalShareAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

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
