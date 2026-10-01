// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Defines asset preparation and settlement hooks for issuer-backed tokens.
interface IAssetSettlementAdapter {
    /// @notice Returns the user-facing token accepted by this legacy settlement adapter.
    function userToken() external view returns (address);

    /// @notice Returns the wrapped or pool Currency used for V4 settlement.
    function poolCurrency() external view returns (address);

    /// @notice Pulls user tokens and delivers the requested pool Currency to a receiver.
    /// @param owner User whose token balance is debited.
    /// @param receiver Address receiving the pool Currency.
    /// @param shares Pool-currency amount to deliver.
    /// @param maxDisplayedDebit Maximum user-token amount that may be pulled.
    /// @param operationId Identifier binding this transfer to its enclosing legacy operation.
    /// @return wrappedDelivered Actual pool-Currency amount delivered.
    function pullAndWrap(
        address owner,
        address receiver,
        uint256 shares,
        uint256 maxDisplayedDebit,
        bytes32 operationId
    ) external returns (uint256 wrappedDelivered);
    /// @notice Prepares the adapter to accept the specified pool-Currency amount for redemption.
    /// @param shares Pool-currency amount expected from the caller.
    /// @param operationId Identifier binding this preparation to its enclosing legacy operation.
    function prepareReceive(uint256 shares, bytes32 operationId) external;

    /// @notice Redeems pool Currency and delivers the underlying user token to a recipient.
    /// @param recipient Address receiving the user token.
    /// @param shares Pool-currency amount to redeem.
    /// @param minDisplayedCredit Minimum underlying-token amount that must be delivered.
    /// @param operationId Identifier binding this redemption to its enclosing legacy operation.
    /// @return sharesDelivered Actual pool-currency amount processed by the adapter.
    function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
        external
        returns (uint256 sharesDelivered);
}
