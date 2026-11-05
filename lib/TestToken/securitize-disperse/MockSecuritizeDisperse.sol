// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Test-only implementation of the documented Securitize push distribution interface.
/// @dev This is an independent mock, not Securitize's implementation. No proxy or pause mechanism.
contract MockSecuritizeDisperse is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant DUPLICATE_WINDOW = 10 minutes;

    // Timestamp + 1 distinguishes an unpaid batch from one paid at timestamp zero.
    mapping(bytes32 batch => uint256 timestampPlusOne) private _lastPaid;

    event Paid(address indexed payoutToken, address indexed recipient, uint256 amount);
    event Dispersed(
        address indexed payoutToken, address indexed sender, uint256 total, uint256 count, bytes32 indexed batchHash
    );
    event Rescued(address indexed token, address indexed to, uint256 amount, address indexed caller);
    event AdminGranted(address indexed admin);
    event AdminRevoked(address indexed admin);
    event OperatorAdded(address indexed operator);
    event OperatorRevoked(address indexed operator);

    error ZeroAddressInvalid();
    error CannotTransferAdminToSelf();
    error UseRevokeOperator();
    error EmptyBatch();
    error BatchTooLarge();
    error ArrayLengthMismatch();
    error ZeroAmount();
    error InvalidRecipient(address recipient);
    error DuplicateBatch(bytes32 batchHash, uint256 lastDispersedAt);
    error AmountMismatch(uint256 expected, uint256 received);

    constructor(address initialAdmin) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /// @notice Pulls the total from the operator, then pays every entry in one atomic transaction.
    /// @dev Amounts are raw payout-token units. A failed transfer rolls back the entire batch.
    function disperseToken(address payoutToken, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        if (payoutToken == address(0)) revert ZeroAddressInvalid();
        uint256 count = recipients.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (count != amounts.length) revert ArrayLengthMismatch();

        uint256 total;
        for (uint256 i; i < count; ++i) {
            _checkRecipient(recipients[i], amounts[i]);
            total += amounts[i];
        }

        bytes32 id = batchHash(payoutToken, recipients, amounts);
        uint256 paid = _lastPaid[id];
        if (paid != 0 && block.timestamp < paid - 1 + DUPLICATE_WINDOW) {
            revert DuplicateBatch(id, paid - 1);
        }
        _lastPaid[id] = block.timestamp + 1;

        IERC20 token = IERC20(payoutToken);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), total);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != total) revert AmountMismatch(total, received);

        for (uint256 i; i < count; ++i) {
            token.safeTransfer(recipients[i], amounts[i]);
            emit Paid(payoutToken, recipients[i], amounts[i]);
        }
        emit Dispersed(payoutToken, msg.sender, total, count, id);
    }

    function rescue(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0)) revert ZeroAddressInvalid();
        _checkRecipient(to, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount, msg.sender);
    }

    function batchHash(address payoutToken, address[] calldata recipients, uint256[] calldata amounts)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payoutToken, recipients, amounts));
    }

    function lastDispersedAt(bytes32 batchHash_) external view returns (uint256) {
        uint256 paid = _lastPaid[batchHash_];
        return paid == 0 ? 0 : paid - 1;
    }

    function isOperator(address account) public view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }

    function isAdmin(address account) public view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    /// @dev Transfers the caller's admin role; any other existing admins remain admins.
    function changeAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == msg.sender) revert CannotTransferAdminToSelf();
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function addOperator(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, account);
    }

    function revokeOperator(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(OPERATOR_ROLE, account);
    }

    function revokeRole(bytes32 role, address account) public override {
        if (role == OPERATOR_ROLE) revert UseRevokeOperator();
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == OPERATOR_ROLE) revert UseRevokeOperator();
        super.renounceRole(role, callerConfirmation);
    }

    // Centralize domain events so generic AccessControl paths cannot skip them.
    function _grantRole(bytes32 role, address account) internal override returns (bool changed) {
        if (account == address(0)) revert ZeroAddressInvalid();
        changed = super._grantRole(role, account);
        if (changed) {
            if (role == DEFAULT_ADMIN_ROLE) emit AdminGranted(account);
            if (role == OPERATOR_ROLE) emit OperatorAdded(account);
        }
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool changed) {
        changed = super._revokeRole(role, account);
        if (changed) {
            if (role == DEFAULT_ADMIN_ROLE) emit AdminRevoked(account);
            if (role == OPERATOR_ROLE) emit OperatorRevoked(account);
        }
    }

    function _checkRecipient(address recipient, uint256 amount) private view {
        if (recipient == address(0)) revert ZeroAddressInvalid();
        if (recipient == address(this)) revert InvalidRecipient(recipient);
        if (amount == 0) revert ZeroAmount();
    }
}
