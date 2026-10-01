// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    function setMultiplier(uint256 value, uint256 nonce) external {
        multiplier = value;
        multiplierNonce = nonce;
    }

    function setBlocked(address recipient, bool reject) external {
        blocked = recipient;
        rejectReceiver = reject;
    }

    function mintShares(address to, uint256 shares) external {
        sharesOf[to] += shares;
        totalShares += shares;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * multiplier / 1e18;
    }

    function balanceOf(address owner) public view returns (uint256) {
        return sharesOf[owner] * multiplier / 1e18;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferShares(to, amount * 1e18 / multiplier);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "allowance");
        allowances[from][msg.sender] -= amount;
        _move(from, to, amount * 1e18 / multiplier);
        return true;
    }

    function transferSharesFrom(address from, address to, uint256 shares) external returns (bool) {
        uint256 displayed = getUnderlyingAmountByShares(shares);
        require(allowances[from][msg.sender] >= displayed, "display allowance");
        allowances[from][msg.sender] -= displayed;
        _move(from, to, shares);
        return true;
    }

    function transferShares(address to, uint256 shares) public returns (bool) {
        _move(msg.sender, to, shares);
        return true;
    }

    function getUnderlyingAmountByShares(uint256 shares) public view returns (uint256) {
        return shares * multiplier / 1e18;
    }

    function getCurrentMultiplier() external view returns (uint256, uint256, uint256) {
        return (multiplier, 0, multiplierNonce);
    }

    function _move(address from, address to, uint256 shares) private {
        require(!rejectReceiver || to != blocked, "issuer refused owner");
        require(sharesOf[from] >= shares, "shares");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, getUnderlyingAmountByShares(shares));
    }
}

contract V1MockIssuerWrapped is ERC20 {
    V1MockIssuerShares public immutable underlying;

    constructor(V1MockIssuerShares token) ERC20("Wrapped TSLAx", "wTSLAx") {
        underlying = token;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function mintTestShares(address receiver, uint256 shares) external {
        _mint(receiver, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        require(underlying.transferSharesFrom(msg.sender, address(this), shares));
        _mint(receiver, shares);
        return underlying.getUnderlyingAmountByShares(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        require(underlying.transferShares(receiver, shares));
        return underlying.getUnderlyingAmountByShares(shares);
    }
}
