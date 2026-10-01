// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAssetSettlementAdapter} from "tsv-v1/legacy/IAssetSettlementAdapter.sol";

/// @dev Defines the issuer share token methods used by the settlement adapter.
interface IBackedShares is IERC20 {
    /// @notice Returns the issuer's exact share units held by `account`.
    function sharesOf(address account) external view returns (uint256);

    /// @notice Transfers exact issuer-share units using the issuer's share-aware transfer method.
    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool);

    /// @notice Converts issuer-share units into the token's displayed underlying amount.
    function getUnderlyingAmountByShares(uint256 shares) external view returns (uint256);
}

/// @dev Defines the wrapped issuer token methods used for asset conversion.
interface IIssuerWrapped is IERC20 {
    /// @notice Returns the issuer asset wrapped by this token.
    function asset() external view returns (address);

    /// @notice Mints wrapped shares by pulling the corresponding underlying amount.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Burns wrapped shares and delivers their underlying representation.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Returns the total wrapped-share supply.
    function totalSupply() external view returns (uint256);
}

/// @dev Exposes the active asset operation used to authorize adapter settlement.
interface IActiveAssetOperation {
    /// @notice Returns the active router or LP operation context for a wrapped pool currency.
    /// @param operationId Operation identifier supplied by the settlement adapter caller.
    /// @param poolCurrency Wrapped currency whose operation context is requested.
    /// @return poolId Pool associated with the active operation.
    /// @return owner Original account whose assets are being moved.
    /// @return recipient Account that must receive redeemed assets.
    /// @return forceExit Whether the operation is an administrative forced exit.
    function activeAssetOperation(bytes32 operationId, address poolCurrency)
        external
        view
        returns (bytes32 poolId, address owner, address recipient, bool forceExit);
}

/// @notice Binds one issuer's variable-balance token to its existing stable wrapper.
contract IssuerShareSettlementAdapter is IAssetSettlementAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Reverts when the caller does not have permission to perform the requested operation.
    error Unauthorized();
    /// @dev Reverts when the requested operation is not valid in the current state or callback context.
    error InvalidOperation();
    /// @dev Reverts when the observed token balance change differs from the expected settlement amount.
    error SettlementMismatch();
    /// @dev Reverts when the actual amount falls outside the caller supplied bounds.
    error SlippageExceeded();

    /// @dev Stores the amounts and snapshots prepared for an asset settlement operation.
    struct Prepared {
        /// @dev Identifier of the active operation.
        bytes32 operationId;
        /// @dev Account that initiated the active operation.
        address caller;
        /// @dev Issuer-share amount prepared for settlement.
        uint256 shares;
        /// @dev Adapter's wrapped-token balance captured before the operation.
        uint256 wrappedBefore;
        /// @dev Adapter's issuer-share balance captured before the operation.
        uint256 underlyingSharesBefore;
    }

    /// @dev Stores balances and conversion values captured before a token pull.
    struct PullSnapshot {
        /// @dev Owner's issuer-share balance before the pull.
        uint256 ownerShares;
        /// @dev Owner's displayed token balance before the pull.
        uint256 ownerDisplayed;
        /// @dev Adapter's issuer-share balance before the pull.
        uint256 adapterShares;
        /// @dev Vault's issuer-share balance before the pull.
        uint256 vaultShares;
        /// @dev Wrapped-token total supply before the pull.
        uint256 wrapperSupply;
        /// @dev Adapter's wrapped-token balance before the pull.
        uint256 adapterWrapped;
        /// @dev Receiver's wrapped-token balance before the pull.
        uint256 receiverWrapped;
    }

    /// @dev Stores balances and conversion values captured before a redemption.
    struct RedeemSnapshot {
        /// @dev Recipient's issuer-share balance before redemption.
        uint256 recipientShares;
        /// @dev Recipient's displayed token balance before redemption.
        uint256 recipientDisplayed;
        /// @dev Vault's issuer-share balance before redemption.
        uint256 vaultShares;
        /// @dev Wrapped-token total supply before redemption.
        uint256 wrapperSupply;
    }

    IBackedShares private immutable underlying;
    IIssuerWrapped private immutable wrapped;
    address public immutable router;
    address public immutable lpManager;
    Prepared private prepared;

    /// @notice Binds one issuer share token and wrapper to the Router and LP Manager that may use them.
    /// @param underlying_ Issuer token exposing share-aware transfers and conversions.
    /// @param wrapped_ Issuer wrapper used as the PoolManager Currency.
    /// @param router_ Authorized swap caller.
    /// @param lpManager_ Authorized liquidity caller.
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

    /// @notice Returns the underlying issuer token used by the legacy path.
    function userToken() external view returns (address) {
        return address(underlying);
    }

    /// @notice Returns the wrapper token used as the legacy pool Currency.
    function poolCurrency() external view returns (address) {
        return address(wrapped);
    }

    /// @notice Pulls exact issuer shares, mints the same number of wrapped shares, and delivers them.
    /// @dev Checks share balances, wrapper supply, displayed debit, and every token balance change.
    /// @param owner Account whose shares are pulled.
    /// @param receiver Account receiving wrapped shares; must be the authorized calling manager.
    /// @param shares Exact number of shares to wrap.
    /// @param maxDisplayedDebit Maximum displayed underlying debit allowed for `owner`.
    /// @param operationId Active operation whose owner and pool currency must match.
    /// @return wrappedDelivered Wrapped shares transferred to `receiver`.
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

    /// @notice Records the expected redemption amount before the caller transfers wrapped shares in.
    /// @param shares Exact wrapped-share amount expected for redemption.
    /// @param operationId Active operation whose recipient must receive the underlying shares.
    function prepareReceive(uint256 shares, bytes32 operationId) external nonReentrant {
        (, address recipient,) = _requireContext(operationId);
        if (prepared.operationId != 0 || operationId == 0 || shares == 0 || recipient == address(0)) {
            revert InvalidOperation();
        }
        prepared = Prepared(
            operationId, msg.sender, shares, wrapped.balanceOf(address(this)), underlying.sharesOf(address(this))
        );
    }

    /// @notice Redeems the prepared wrapped shares and verifies exact share delivery and displayed-credit bounds.
    /// @param recipient Recipient bound by the active operation context.
    /// @param shares Exact wrapped-share amount previously prepared and transferred to this adapter.
    /// @param minDisplayedCredit Minimum displayed underlying balance increase; forced exits require zero.
    /// @param operationId Active operation that authorized the redemption.
    /// @return sharesDelivered Issuer shares delivered to `recipient`.
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

    /// @dev Checks the caller is a configured manager and that its active context names valid owner and recipient.
    /// @param operationId Operation ID to validate against the calling manager.
    /// @return owner Original owner recorded by the active operation.
    /// @return recipient Recipient recorded by the active operation.
    /// @return forceExit Whether the operation uses the forced-exit path.
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
