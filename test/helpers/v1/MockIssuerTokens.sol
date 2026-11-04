// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Provides a configurable issuer-share token fixture for tests.
contract V1MockIssuerShares is IERC20 {
    string public constant name = "TSLAx mock";
    string public constant symbol = "TSLAx";
    uint8 public constant decimals = 18;
    uint256 public multiplier = 1e18;
    uint256 public multiplierNonce;
    uint256 private totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) private allowances;
    bool public rejectReceiver;
    address public blocked;

    /// @dev Updates the mock issuer conversion multiplier and version nonce.
    function setMultiplier(uint256 value, uint256 nonce) external {
        multiplier = value;
        multiplierNonce = nonce;
    }

    /// @dev Configures whether the mock share token rejects transfers to a recipient.
    function setBlocked(address recipient, bool reject) external {
        blocked = recipient;
        rejectReceiver = reject;
    }

    /// @dev Mints mock issuer shares to the selected account.
    function mintShares(address to, uint256 shares) external {
        sharesOf[to] += shares;
        totalShares += shares;
    }

    /// @dev Returns the total mock issuer share supply.
    function totalSupply() external view returns (uint256) {
        return totalShares * multiplier / 1e18;
    }

    /// @dev Returns the mock issuer share balance of an account.
    function balanceOf(address owner) public view returns (uint256) {
        return sharesOf[owner] * multiplier / 1e18;
    }

    /// @dev Returns the mock issuer share allowance for a spender.
    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    /// @dev Sets the mock issuer share allowance for a spender.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Transfers mock issuer shares to a recipient.
    function transfer(address to, uint256 amount) external returns (bool) {
        return transferShares(to, amount * 1e18 / multiplier);
    }

    /// @dev Transfers mock issuer shares using an allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "allowance");
        allowances[from][msg.sender] -= amount;
        _move(from, to, amount * 1e18 / multiplier);
        return true;
    }

    /// @dev Transfers a fixed number of issuer shares using an allowance.
    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool) {
        uint256 displayed = getUnderlyingAmountByShares(shares);
        require(allowances[from][msg.sender] >= displayed, "display allowance");
        allowances[from][msg.sender] -= displayed;
        _move(from, to, shares);
        return true;
    }

    /// @dev Transfers a fixed number of issuer shares.
    function transferShares(address to, uint256 shares) public returns (bool) {
        _move(msg.sender, to, shares);
        return true;
    }

    /// @dev Converts mock issuer shares to their configured underlying amount.
    function getUnderlyingAmountByShares(uint256 shares) public view returns (uint256) {
        return shares * multiplier / 1e18;
    }

    /// @dev Returns the configured multiplier and its mock metadata.
    function getCurrentMultiplier() external view returns (uint256, uint256, uint256) {
        return (multiplier, 0, multiplierNonce);
    }

    /// @dev Updates mock share balances and emits the corresponding transfer event.
    function _move(address from, address to, uint256 shares) private {
        require(!rejectReceiver || to != blocked, "issuer refused owner");
        require(sharesOf[from] >= shares, "shares");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, getUnderlyingAmountByShares(shares));
    }
}

/// @dev Provides a wrapped ERC-20 fixture for issuer settlement tests.
contract V1MockIssuerWrapped is ERC20 {
    V1MockIssuerShares public immutable underlying;

    /// @dev Binds the issuer-share token used as the wrapped token underlying.
    constructor(V1MockIssuerShares token) ERC20("Wrapped TSLAx", "wTSLAx") {
        underlying = token;
    }

    /// @dev Returns the underlying asset associated with the wrapped token.
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @dev Exposes the mock multiplier through the ERC-8056 adapter surface used by TSV fixtures.
    function uiMultiplier() external view returns (uint256) {
        return underlying.multiplier();
    }

    /// @dev Mints mock wrapped-token shares for a test.
    function mintTestShares(address receiver, uint256 shares) external {
        _mint(receiver, shares);
    }

    /// @dev Mints wrapped tokens to a recipient after pulling the matching issuer shares.
    function mint(uint256 shares, address receiver) external returns (uint256) {
        require(underlying.transferSharesFrom(msg.sender, address(this), shares));
        _mint(receiver, shares);
        return underlying.getUnderlyingAmountByShares(shares);
    }

    /// @dev Redeems wrapped tokens for the configured underlying amount.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        require(underlying.transferShares(receiver, shares));
        return underlying.getUnderlyingAmountByShares(shares);
    }
}
