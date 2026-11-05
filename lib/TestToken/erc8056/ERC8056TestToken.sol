// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @dev ERC-8056 core interface. The standard's optional events do not affect its interface ID.
interface IScaledUIAmount {
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);
    event UIMultiplierUpdateCancelled(uint256 cancelledMultiplier, uint256 cancelledEffectiveAt);

    function uiMultiplier() external view returns (uint256);
}

/// @dev ERC-8056 optional conversion extension.
interface IScaledUIAmountConversion {
    function toUIAmount(uint256 rawAmount) external view returns (uint256);
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}

/// @dev ERC-8056 optional balance extension.
interface IScaledUIAmountBalances {
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
}

/// @dev ERC-8056 required pending-multiplier extension.
interface IScaledUIAmountNewUIMultiplier {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/// @notice Standalone ERC-8056 test token; not intended for production deployment.
/// @dev ERC-20 balances and transfers remain in raw units. UI multiplier updates never mutate
///      balances or supply. Owner minting is included only to simplify test setup.
contract ERC8056TestToken is
    IScaledUIAmount,
    IScaledUIAmountConversion,
    IScaledUIAmountBalances,
    IScaledUIAmountNewUIMultiplier
{
    uint256 private constant MULTIPLIER_SCALE = 1e18;
    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 private constant SCALED_UI_AMOUNT_INTERFACE_ID = 0xa60bf13d;
    bytes4 private constant SCALED_UI_NEW_MULTIPLIER_INTERFACE_ID = 0x4bd27648;
    bytes4 private constant SCALED_UI_CONVERSION_INTERFACE_ID = 0x57854fc3;
    bytes4 private constant SCALED_UI_BALANCES_INTERFACE_ID = 0xd890fd71;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;
    uint256 private _totalSupply;
    mapping(address account => uint256) private _balances;
    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _uiMultiplier = MULTIPLIER_SCALE;
    uint256 private _newUIMultiplier = MULTIPLIER_SCALE;
    uint256 private _effectiveAt;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidMultiplier();
    error EffectiveTimeMustBeFuture();
    error NoPendingMultiplier();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 initialSupply) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _mint(msg.sender, initialSupply);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address account, address spender) external view returns (uint256) {
        return _allowances[account][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = _allowances[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = approved - amount;
            }
            emit Approval(from, msg.sender, approved - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ERC165_INTERFACE_ID || interfaceId == SCALED_UI_AMOUNT_INTERFACE_ID
            || interfaceId == SCALED_UI_NEW_MULTIPLIER_INTERFACE_ID || interfaceId == SCALED_UI_CONVERSION_INTERFACE_ID
            || interfaceId == SCALED_UI_BALANCES_INTERFACE_ID;
    }

    function uiMultiplier() public view override returns (uint256) {
        return block.timestamp >= _effectiveAt ? _newUIMultiplier : _uiMultiplier;
    }

    function newUIMultiplier() external view override returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() external view override returns (uint256) {
        return _effectiveAt;
    }

    /// @notice Schedule a UI-only multiplier update. ERC-20 balances and supply stay unchanged.
    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) external onlyOwner {
        if (newMultiplier == 0) revert InvalidMultiplier();
        if (effectiveAtTimestamp <= block.timestamp) revert EffectiveTimeMustBeFuture();

        uint256 oldMultiplier;
        if (block.timestamp >= _effectiveAt) {
            oldMultiplier = _newUIMultiplier;
            _uiMultiplier = oldMultiplier;
        } else {
            oldMultiplier = _uiMultiplier;
            emit UIMultiplierUpdateCancelled(_newUIMultiplier, _effectiveAt);
        }

        _newUIMultiplier = newMultiplier;
        _effectiveAt = effectiveAtTimestamp;
        emit UIMultiplierUpdated(oldMultiplier, newMultiplier, effectiveAtTimestamp);
    }

    function cancelUIMultiplierUpdate() external onlyOwner {
        if (block.timestamp >= _effectiveAt) revert NoPendingMultiplier();
        emit UIMultiplierUpdateCancelled(_newUIMultiplier, _effectiveAt);
        _newUIMultiplier = _uiMultiplier;
        _effectiveAt = 0;
    }

    function toUIAmount(uint256 rawAmount) public view override returns (uint256) {
        return (rawAmount * uiMultiplier()) / MULTIPLIER_SCALE;
    }

    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        return (uiAmount * MULTIPLIER_SCALE) / uiMultiplier();
    }

    function balanceOfUI(address account) external view override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() external view override returns (uint256) {
        return toUIAmount(_totalSupply);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        emit TransferWithUIAmount(from, to, amount, toUIAmount(amount));
    }

    function _mint(address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}
