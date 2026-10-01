// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAssetSettlementAdapter {
    function userToken() external view returns (address);
    function poolCurrency() external view returns (address);
    function pullAndWrap(
        address owner,
        address receiver,
        uint256 shares,
        uint256 maxDisplayedDebit,
        bytes32 operationId
    ) external returns (uint256 wrappedDelivered);
    function prepareReceive(uint256 shares, bytes32 operationId) external;
    function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
        external
        returns (uint256 sharesDelivered);
}
