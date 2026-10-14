// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest, PoolLifecycle} from "tsv-v1/types/TSVTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
import {PermissionedV4Router} from "tsv-v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol";
import {PermissionFlags} from "../vendor/permissionedPools/libraries/PermissionFlags.sol";
import {IV4Router} from "tsv-v1/vendor/v4-router/interfaces/IV4Router.sol";
import {Actions} from "tsv-v1/vendor/v4-router/libraries/Actions.sol";
import {ReentrancyLock} from "v4-periphery/base/ReentrancyLock.sol";
import {IPermissionsAdapter} from "../vendor/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "../vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

/// @notice One-pool exact-input W/Q swaps submitted directly by participants or approved adapters.
contract TSVSwapRouterV1 is Initializable, UUPSUpgradeable, PermissionedV4Router, ReentrancyLock {
    using PoolIdLibrary for PoolKey;

    error UnauthorizedUpgrade();
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error InvalidRequest();
    error InvalidPool();
    error PoolDelisted();
    error PoolNotTradable();
    error RegistryPaused();
    error Expired();
    error SlippageExceeded();
    error SettlementMismatch();
    error InvalidAdapter();
    error AdapterNotAllowed();
    error InvalidPayer();

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant UPGRADE_ADMIN_ROLE = keccak256("UPGRADE_ADMIN_ROLE");

    // Registry access and approved external adapters.
    TSVRegistryV1 public registry;
    mapping(address adapter => bool allowed) public isAdapterAllowed;

    // Swap context shared with PoolManager callbacks during unlock.
    /// @dev Original user identity exposed to W permission checks while the V4 lock is active.
    address private activeParticipant;
    /// @dev Actual SETTLE_ALL debt; returned after unlock and checked against the requested input.
    uint256 private activeAmountIn;
    /// @dev Actual TAKE_ALL credit, returned after unlock.
    uint256 private activeAmountOut;
    /// @dev Adapter-selected output destination; TAKE_ALL otherwise defaults to the participant.
    address private activeRecipient;
    /// @dev Expected input PoolKey currency; checked against the currency settled by PoolManager.
    address private activeInputCurrency;
    /// @dev Token payer used by _settle for quote-token inputs; appended to preserve prior storage slots.
    address private activePayer;

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

    modifier whenRegistryNotPaused() {
        if (registry.isPaused()) revert RegistryPaused();
        _;
    }

    modifier onlyAllowedAdapter() {
        if (!isAdapterAllowed[msg.sender]) revert AdapterNotAllowed();
        _;
    }

    /// @notice Authorizes or revokes a contract adapter that can submit swaps for a participant.
    function setAdapterAllowed(address adapter, bool allowed)
        external
        whenRegistryNotPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (adapter == address(0) || (allowed && adapter.code.length == 0)) revert InvalidAdapter();
        isAdapterAllowed[adapter] = allowed;
        emit AdapterAuthorizationUpdated(adapter, allowed);
    }

    // Approved-adapter direct-settlement entry point.
    /// @notice Adapter path with caller-prefunded U or caller-paid Q; output is delivered to `recipient`.
    /// @dev U input must already be deposited in W, so `payer` is zero. For Q input, `payer` must be this
    ///      adapter; Q is transferred to PoolManager during settlement.
    function swapExactInputFromContractDirect(
        SwapRequest calldata request,
        address payer,
        address participant,
        address recipient
    )
        external
        whenRegistryNotPaused
        isNotLocked
        onlyAllowedAdapter
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (recipient != participant) revert InvalidRequest();
        address inputCurrency = Currency.unwrap(
            request.zeroForOne ? request.key.currency0 : request.key.currency1
        );
        bool isUnderlyingInput = registry.getCurrencyUnderlying(inputCurrency) != address(0);
        if ((isUnderlyingInput && payer != address(0)) || (!isUnderlyingInput && payer != msg.sender)) {
            revert InvalidPayer();
        }
        return _swap(request, payer, participant, recipient);
    }

    /// @notice Executes an exact-input swap using an allowlisted contract's prefunded input.
    /// @dev The participant remains the SBT and issuer-permission subject; the caller contract pays and receives
    ///      settlement tokens so DEX adapters can custody their own hop input and forward the hop output.
    function swapExactInputFromContract(SwapRequest calldata request, address participant)
        external
        whenRegistryNotPaused
        isNotLocked
        onlyAllowedAdapter
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, msg.sender, participant, msg.sender);
    }

    /// @notice Executes a caller-bound exact-input swap, paying from and sending output to the caller.
    /// @dev The caller is also the TSV SBT and issuer-permission subject; no participant can be selected.
    function swapExactInput(SwapRequest calldata request)
        external
        whenRegistryNotPaused
        isNotLocked
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, msg.sender, msg.sender, msg.sender);
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
        address currencyAddress = Currency.unwrap(currency);
        if (currencyAddress != activeInputCurrency) revert SettlementMismatch();
        poolManager.sync(currency);
        address underlying = registry.getCurrencyUnderlying(currencyAddress);
        if (underlying == address(0)) {
            if (activePayer == address(0)) revert InvalidPayer();
            TSVPermissionedSettlementLib.transferFromPayer(
                currencyAddress, activePayer, address(poolManager), amount
            );
        } else {
            if (PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(currencyAddress) != underlying) {
                revert InvalidAdapter();
            }
            IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(currencyAddress);
            if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
            permissionsAdapter.wrapToPoolManager(amount);
        }
        // PoolManager.unlock itself requires every currency delta to be settled.
        poolManager.settle();
    }

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        TSVPermissionedSettlementLib.transferFromPayer(
            Currency.unwrap(currency), payer, address(poolManager), amount
        );
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
        if (activeAmountIn == 0 || amount == 0) revert SlippageExceeded();
        activeAmountOut = amount;
        super._take(currency, activeRecipient, amount);
    }

    // Private swap execution and request helpers.
    /// @param request Pool key, direction, amount, slippage limit, deadline, and expected multiplier.
    /// @param payer Address supplying Q, or zero when U is already deposited in W.
    /// @param participant Identity checked for swap permission and reported to the permissioned token.
    /// @param recipient Address that receives the swap output.
    /// @dev U is transferred from a nonzero payer into W before unlocking; Q is transferred from payer
    ///      directly to PoolManager after sync. A zero payer means U was prefunded in W. Swaps must fill fully.
    function _swap(
        SwapRequest memory request,
        address payer,
        address participant,
        address recipient
    )
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (recipient == address(0)) revert InvalidRequest();
        _checkRequest(request);
        if (address(request.key.hooks) != registry.hook()) revert InvalidPool();
        if (!registry.isTradable(PoolId.unwrap(request.key.toId()))) revert PoolNotTradable();
        activeParticipant = participant;
        activeRecipient = recipient;
        activeInputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency0 : request.key.currency1);
        activePayer = payer;
        if (participant == address(0) || !registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, participant)) {
            revert Unauthorized();
        }
        address inputCurrency = activeInputCurrency;
        address inputUnderlying = registry.getCurrencyUnderlying(inputCurrency);
        if (inputUnderlying != address(0) && payer != address(0)) {
            TSVPermissionedSettlementLib.transferFromPayer(
                inputUnderlying, payer, inputCurrency, request.amountSpecified
            );
        }
        bytes memory payload = _payload(request);
        // PoolManager forwards payload unchanged; SafeCallback restricts callbacks to that immutable PM.
        poolManager.unlock(payload);
        activePayer = address(0);
        actualIn = activeAmountIn;
        actualOut = activeAmountOut;
        if (actualIn != request.amountSpecified) revert SlippageExceeded();
        // V4 exact-input action enforces the input and minimum-output limits.
    }

    function _checkRequest(SwapRequest memory request) private view {
        if (block.timestamp > request.deadline) revert Expired();
        if (
            request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max)
                || request.limitAmount == 0
        ) revert InvalidRequest();
    }

    function _payload(SwapRequest memory request) private pure returns (bytes memory) {
        bytes[] memory params = new bytes[](3);
        bytes memory hookData = abi.encode(request.expectedMultiplier);
        Currency input = request.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.zeroForOne ? request.key.currency1 : request.key.currency0;
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams(
                request.key, request.zeroForOne, request.amountSpecified, request.limitAmount, 0, hookData
            )
        );
        params[1] = abi.encode(input, request.amountSpecified);
        params[2] = abi.encode(output, request.limitAmount);
        return abi.encode(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        whenRegistryNotPaused
    {
        UUPSUpgradeable.upgradeToAndCall(newImplementation, data);
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
