// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAssetSettlementAdapter} from "tsv-v1/legacy/IAssetSettlementAdapter.sol";

interface IBackedShares is IERC20 {
    function sharesOf(address account) external view returns (uint256);
    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool);
    function getUnderlyingAmountByShares(uint256 shares) external view returns (uint256);
}

interface IIssuerWrapped is IERC20 {
    function asset() external view returns (address);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function totalSupply() external view returns (uint256);
}

interface IActiveAssetOperation {
    function activeAssetOperation(bytes32 operationId, address poolCurrency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit);
}

/// @notice Binds one issuer's variable-balance token to its existing stable wrapper.
contract IssuerShareSettlementAdapter is IAssetSettlementAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidOperation();
    error SettlementMismatch();
    error SlippageExceeded();

    struct Prepared {
        bytes32 operationId;
        address caller;
        uint256 shares;
        uint256 wrappedBefore;
        uint256 underlyingSharesBefore;
    }

    struct PullSnapshot {
        uint256 ownerShares;
        uint256 ownerDisplayed;
        uint256 adapterShares;
        uint256 vaultShares;
        uint256 wrapperSupply;
        uint256 adapterWrapped;
        uint256 receiverWrapped;
    }

    struct RedeemSnapshot {
        uint256 recipientShares;
        uint256 recipientDisplayed;
        uint256 vaultShares;
        uint256 wrapperSupply;
    }

    IBackedShares private immutable underlying;
    IIssuerWrapped private immutable wrapped;
    address public immutable router;
    address public immutable lpManager;
    Prepared private prepared;

    constructor(address underlying_, address wrapped_, address router_, address lpManager_) {
        if (
            underlying_.code.length == 0 || wrapped_.code.length == 0 || router_ == address(0)
                || lpManager_ == address(0) || underlying_ == wrapped_
                || IIssuerWrapped(wrapped_).asset() != underlying_
        ) revert InvalidOperation();
        underlying = IBackedShares(underlying_);
        wrapped = IIssuerWrapped(wrapped_);
        router = router_;
        lpManager = lpManager_;
    }

    function userToken() external view returns (address) {
        return address(underlying);
    }

    function poolCurrency() external view returns (address) {
        return address(wrapped);
    }

    function pullAndWrap(
        address owner,
        address receiver,
        uint256 shares,
        uint256 maxDisplayedDebit,
        bytes32 operationId
    ) external nonReentrant returns (uint256 wrappedDelivered) {
        (address contextOwner,,) = _requireContext(operationId);
        if (
            prepared.operationId != 0 || shares == 0 || owner == address(0) || owner == address(this)
                || owner != contextOwner || receiver != msg.sender || maxDisplayedDebit == 0
        ) revert InvalidOperation();

        PullSnapshot memory p = PullSnapshot(
            underlying.sharesOf(owner),
            underlying.balanceOf(owner),
            underlying.sharesOf(address(this)),
            underlying.sharesOf(address(wrapped)),
            wrapped.totalSupply(),
            wrapped.balanceOf(address(this)),
            wrapped.balanceOf(receiver)
        );

        if (!underlying.transferSharesFrom(owner, address(this), shares)) revert SettlementMismatch();
        if (
            p.ownerShares < shares || underlying.sharesOf(owner) != p.ownerShares - shares
                || underlying.sharesOf(address(this)) != p.adapterShares + shares
        ) revert SettlementMismatch();
        uint256 displayedAllowance = underlying.getUnderlyingAmountByShares(shares);
        if (displayedAllowance == 0) revert SettlementMismatch();
        IERC20(address(underlying)).forceApprove(address(wrapped), 0);
        IERC20(address(underlying)).forceApprove(address(wrapped), displayedAllowance);
        wrapped.mint(shares, address(this));
        IERC20(address(underlying)).forceApprove(address(wrapped), 0);
        if (
            underlying.sharesOf(address(this)) != p.adapterShares
                || underlying.sharesOf(address(wrapped)) != p.vaultShares + shares
                || wrapped.totalSupply() != p.wrapperSupply + shares
                || wrapped.balanceOf(address(this)) != p.adapterWrapped + shares
        ) revert SettlementMismatch();

        IERC20(address(wrapped)).safeTransfer(receiver, shares);
        if (
            wrapped.balanceOf(address(this)) != p.adapterWrapped
                || wrapped.balanceOf(receiver) != p.receiverWrapped + shares
        ) revert SettlementMismatch();
        uint256 ownerDisplayedAfter = underlying.balanceOf(owner);
        if (p.ownerDisplayed < ownerDisplayedAfter || p.ownerDisplayed - ownerDisplayedAfter > maxDisplayedDebit) {
            revert SlippageExceeded();
        }
        return shares;
    }

    function prepareReceive(uint256 shares, bytes32 operationId) external nonReentrant {
        (, address recipient,) = _requireContext(operationId);
        if (prepared.operationId != 0 || operationId == 0 || shares == 0 || recipient == address(0)) {
            revert InvalidOperation();
        }
        prepared = Prepared(
            operationId, msg.sender, shares, wrapped.balanceOf(address(this)), underlying.sharesOf(address(this))
        );
    }

    function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
        external
        nonReentrant
        returns (uint256 sharesDelivered)
    {
        (, address contextRecipient, bool forceExit) = _requireContext(operationId);
        Prepared memory p = prepared;
        if (
            p.operationId != operationId || p.caller != msg.sender || p.shares != shares || shares == 0
                || contextRecipient != recipient || recipient == address(0) || (forceExit && minDisplayedCredit != 0)
                || wrapped.balanceOf(address(this)) != p.wrappedBefore + shares
        ) revert InvalidOperation();

        RedeemSnapshot memory s = RedeemSnapshot(
            underlying.sharesOf(recipient),
            underlying.balanceOf(recipient),
            underlying.sharesOf(address(wrapped)),
            wrapped.totalSupply()
        );

        wrapped.redeem(shares, recipient, address(this));
        if (
            underlying.sharesOf(recipient) != s.recipientShares + shares || s.vaultShares < shares
                || underlying.sharesOf(address(wrapped)) != s.vaultShares - shares || s.wrapperSupply < shares
                || wrapped.totalSupply() != s.wrapperSupply - shares
                || wrapped.balanceOf(address(this)) != p.wrappedBefore
                || underlying.sharesOf(address(this)) != p.underlyingSharesBefore
        ) revert SettlementMismatch();
        uint256 displayedAfter = underlying.balanceOf(recipient);
        if (displayedAfter < s.recipientDisplayed || displayedAfter - s.recipientDisplayed < minDisplayedCredit) {
            revert SlippageExceeded();
        }
        delete prepared;
        return shares;
    }

    function _requireContext(bytes32 operationId)
        private
        view
        returns (address owner, address recipient, bool forceExit)
    {
        if (msg.sender != router && msg.sender != lpManager) revert Unauthorized();
        (bytes32 poolId, address o, address r, bool forced) =
            IActiveAssetOperation(msg.sender).activeAssetOperation(operationId, address(wrapped));
        if (poolId == 0 || o == address(0) || r == address(0)) revert InvalidOperation();
        return (o, r, forced);
    }
}
