// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {PermissionFlags} from "v4-periphery/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {IV4Router} from "tsv-v1/vendor/v4-router/interfaces/IV4Router.sol";
import {Actions} from "tsv-v1/vendor/v4-router/libraries/Actions.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";
import {IPermissionsAdapter} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "v4-periphery/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice One-pool W/Q swaps. Users pay and receive U for stocks and original Q for quotes.
contract TSVSwapRouterV1 is Initializable, UUPSUpgradeable, PermissionedV4Router, ReentrancyLock {
    error UnauthorizedUpgrade();
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error InvalidRequest();
    error InvalidPool();
    error Expired();
    error SlippageExceeded();
    error SettlementMismatch();
    error InvalidAdapter();
    error AdapterNotAllowed();

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    // Registry access and approved external adapters.
    TSVRegistryV1 public registry;
    mapping(address adapter => bool allowed) public isAdapterAllowed;

    // Every swap overwrites this context; the V4 lock determines whether it is active.
    address private activeParticipant;
    uint256 private activeAmountIn;
    uint256 private activeAmountOut;

    event AdapterAuthorizationUpdated(address indexed adapter, bool allowed);

    /// @dev PoolManager and the issuer PermissionsAdapterFactory are fixed in implementation bytecode.
    constructor(address pm, address factory)
        PermissionedV4Router(IPoolManager(pm), IPermissionsAdapterFactory(factory))
    {
        _disableInitializers();
        if (pm.code.length == 0 || factory.code.length == 0) revert InvalidRequest();
        if (PERMISSIONS_ADAPTER_FACTORY.POOL_MANAGER() != pm) revert InvalidRequest();
    }

    /// @notice Initializes proxy storage and validates the implementation's immutable dependencies.
    /// @dev pm is repeated from the implementation constructor so proxy deployment can verify
    ///      that the selected implementation matches the intended environment and reject a mismatched one.
    /// @param pm Expected PoolManager; must match the implementation's immutable poolManager.
    /// @param registry_ Registry storing TSV identity permissions and admitted currencies.
    function initialize(address pm, address registry_) external initializer {
        if (registry_.code.length == 0 || pm != address(poolManager)) {
            revert InvalidRequest();
        }
        registry = TSVRegistryV1(registry_);
    }

    modifier onlyRole(bytes32 role) {
        if (!registry.hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);
        _;
    }

    /// @notice Authorizes or revokes a contract adapter that can submit swaps for a participant.
    function setAdapterAllowed(address adapter, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0) || (allowed && adapter.code.length == 0)) revert InvalidAdapter();
        isAdapterAllowed[adapter] = allowed;
        emit AdapterAuthorizationUpdated(adapter, allowed);
    }

    // User and approved-adapter swap entry points.
    /// @notice Exact input may fill partially; only realized input is paid.
    function swapExactInput(SwapRequest calldata request)
        external
        isNotLocked
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, true, msg.sender);
    }

    /// @notice Exact output must fill exactly the requested amount.
    function swapExactOutput(SwapRequest calldata request)
        external
        isNotLocked
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, false, msg.sender);
    }

    /// @notice Checks the authenticated DEX user; the approved Adapter pays and receives U/Q.
    function swapExactInputFromAdapter(SwapRequest calldata request, address participant)
        external
        isNotLocked
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (!isAdapterAllowed[msg.sender]) revert AdapterNotAllowed();
        return _swap(request, true, participant);
    }

    // Router views.
    /// @notice Currency used outside the pool: stocks settle in U, quotes in Q.
    function settlementCurrency(address currency) external view returns (address) {
        address underlying = registry.getCurrencyUnderlying(currency);
        return underlying == address(0) ? currency : underlying;
    }

    /// @notice Returns the real user during an active operation, or zero while idle.
    function msgSender() public view override returns (address) {
        return _getLocker() == address(0) ? address(0) : activeParticipant;
    }

    // PoolManager settlement callbacks.
    /// @dev SETTLE_ALL supplies the actual input debt; TAKE_ALL supplies the actual output credit.
    function _settle(Currency currency, address, uint256 amount) internal override {
        activeAmountIn = amount;
        poolManager.sync(currency);
        // The V4 locker is the payer (user or Adapter); msgSender() remains the credential subject.
        // Parent _pay enforces swappingEnabled and isAllowed before transferring and wrapping.
        _pay(currency, _getLocker(), amount);
        // PoolManager.unlock itself requires every currency delta to be settled.
        poolManager.settle();
    }

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        TSVPermissionedSettlementLib.transferExact(Currency.unwrap(currency), payer, address(poolManager), amount);
    }

    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address underlying,
        uint256 amount
    ) internal override {
        TSVPermissionedSettlementLib.payStock(address(permissionsAdapter), underlying, payer, amount);
    }

    function _take(Currency currency, address, uint256 amount) internal override {
        address currencyAddress = Currency.unwrap(currency);
        if (activeAmountIn == 0 || amount == 0) revert SlippageExceeded();
        activeAmountOut = amount;
        address recipient = _getLocker();
        address underlying = registry.getCurrencyUnderlying(currencyAddress);
        IERC20 settlementToken = IERC20(underlying == address(0) ? currencyAddress : underlying);
        // Q leaves PM directly; W burns on take and releases U from the W contract.
        address transferSource = underlying == address(0) ? address(poolManager) : currencyAddress;
        uint256 sourceBalanceBefore = settlementToken.balanceOf(transferSource);
        uint256 recipientBalanceBefore = settlementToken.balanceOf(recipient);
        super._take(currency, recipient, amount);
        TSVPermissionedSettlementLib.assertDecrease(
            sourceBalanceBefore, settlementToken.balanceOf(transferSource), amount
        );
        TSVPermissionedSettlementLib.assertIncrease(
            recipientBalanceBefore, settlementToken.balanceOf(recipient), amount
        );
    }

    // Private swap execution and request helpers.
    function _swap(SwapRequest memory request, bool exactInput, address participant)
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        _checkRequest(request);
        // The configured TSV Hook enforces pool admission, asset status and trading pauses.
        if (address(request.key.hooks) != registry.hook()) revert InvalidPool();
        activeParticipant = participant;
        (address stockCurrency, address underlying) = _stockAsset(request.key);
        if (participant == address(0) || !registry.isAllowed(PermissionFlags.SWAP_ALLOWED, participant)) {
            revert Unauthorized();
        }
        bytes memory payload = _payload(request, exactInput);
        TSVPermissionedSettlementLib.StockInventory memory inventoryBefore =
            TSVPermissionedSettlementLib.stockInventory(stockCurrency, underlying, address(poolManager));
        // PoolManager forwards payload unchanged; SafeCallback restricts callbacks to that immutable PM.
        poolManager.unlock(payload);
        actualIn = activeAmountIn;
        actualOut = activeAmountOut;
        // V4 actions enforce input/output limits; TSV additionally requires exact output equality.
        if (!exactInput && actualOut != request.amountSpecified) revert SlippageExceeded();
        // Memory survives unlock and covers U changes on either the stock or quote transfer path.
        TSVPermissionedSettlementLib.StockInventory memory inventoryAfter =
            TSVPermissionedSettlementLib.stockInventory(stockCurrency, underlying, address(poolManager));
        TSVPermissionedSettlementLib.assertUnderlyingUnchanged(inventoryBefore, inventoryAfter);
        if (inventoryBefore.collateral - inventoryBefore.supply != inventoryAfter.collateral - inventoryAfter.supply) {
            revert SettlementMismatch();
        }
    }

    function _stockAsset(PoolKey memory key) private view returns (address stockCurrency, address underlying) {
        stockCurrency = Currency.unwrap(key.currency0);
        underlying = registry.getCurrencyUnderlying(stockCurrency);
        if (underlying == address(0)) {
            stockCurrency = Currency.unwrap(key.currency1);
            underlying = registry.getCurrencyUnderlying(stockCurrency);
        }
    }

    function _checkRequest(SwapRequest memory request) private view {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
    }

    function _payload(SwapRequest memory request, bool exactInput) private pure returns (bytes memory) {
        bytes[] memory params = new bytes[](3);
        bytes memory hookData = abi.encode(request.expectedMultiplier);
        Currency input = request.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.zeroForOne ? request.key.currency1 : request.key.currency0;
        if (exactInput) {
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, hookData
                )
            );
        } else {
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams(
                    request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, hookData
                )
            );
        }
        params[1] = abi.encode(input, exactInput ? request.amountSpecified : request.limitAmount);
        params[2] = abi.encode(output, exactInput ? request.limitAmount : request.amountSpecified);
        return abi.encode(
            abi.encodePacked(
                uint8(exactInput ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    /// @dev Future upgrades must preserve immutable PoolManager/Factory identities and the new storage layout.
    function _authorizeUpgrade(address implementation) internal view override {
        if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
        if (_getLocker() != address(0)) revert ContractLocked();
        if (
            address(TSVSwapRouterV1(implementation).poolManager()) != address(poolManager)
                || address(TSVSwapRouterV1(implementation).PERMISSIONS_ADAPTER_FACTORY())
                    != address(PERMISSIONS_ADAPTER_FACTORY)
        ) revert InvalidRequest();
    }
}
