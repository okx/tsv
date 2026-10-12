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

/// @notice One-pool exact-input W/Q swaps submitted by approved adapters.
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
    /// @notice Adapter path that settles directly from the participant and delivers output to `recipient`.
    /// @dev The participant must approve this router for the input token. Before the PoolManager swap,
    ///      U is transferred directly from the participant into W, or Q into this router. The input is
    ///      then settled from that prefunded balance, and output is taken directly to `recipient`.
    function swapExactInputFromAdapterDirect(
        SwapRequest calldata request,
        address participant,
        address recipient
    ) external whenRegistryNotPaused isNotLocked returns (uint256 actualIn, uint256 actualOut) {
        return _swap(request, participant, participant, recipient);
    }

    /// @notice Executes an exact-input swap using an allowlisted contract's prefunded input.
    /// @dev The participant remains the SBT and issuer-permission subject; the caller contract pays and receives
    ///      settlement tokens so DEX adapters can custody their own hop input and forward the hop output.
    function swapExactInputFromContract(SwapRequest calldata request, address participant)
        external
        whenRegistryNotPaused
        isNotLocked
        returns (uint256 actualIn, uint256 actualOut)
    {
        return _swap(request, msg.sender, participant, msg.sender);
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
            TSVPermissionedSettlementLib.transferFromSelf(currencyAddress, address(poolManager), amount);
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
    /// @param payer Address supplying the settlement-token input.
    /// @param participant Identity checked for swap permission and reported to the permissioned token.
    /// @param recipient Address that receives the swap output.
    /// @dev Input is transferred from payer into W or this router before unlocking PoolManager;
    ///      it is settled from that prefunded balance and must fill completely.
    function _swap(
        SwapRequest memory request,
        address payer,
        address participant,
        address recipient
    )
        private
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (!isAdapterAllowed[msg.sender]) revert AdapterNotAllowed();
        if (recipient == address(0)) revert InvalidRequest();
        _checkRequest(request);
        if (address(request.key.hooks) != registry.hook()) revert InvalidPool();
        if (registry.getPoolLifeCycle(request.key) == PoolLifecycle.DELIST) revert PoolDelisted();
        if (!registry.isTradable(PoolId.unwrap(request.key.toId()))) revert PoolNotTradable();
        activeParticipant = participant;
        activeRecipient = recipient;
        activeInputCurrency = Currency.unwrap(request.zeroForOne ? request.key.currency0 : request.key.currency1);
        if (participant == address(0) || !registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, participant)) {
            revert Unauthorized();
        }
        address inputCurrency = activeInputCurrency;
        address inputUnderlying = registry.getCurrencyUnderlying(inputCurrency);
        address inputToken = inputUnderlying == address(0) ? inputCurrency : inputUnderlying;
        address inputRecipient = inputUnderlying == address(0) ? address(this) : inputCurrency;
        TSVPermissionedSettlementLib.transferFromPayer(
            inputToken, payer, inputRecipient, request.amountSpecified
        );
        bytes memory payload = _payload(request);
        // PoolManager forwards payload unchanged; SafeCallback restricts callbacks to that immutable PM.
        poolManager.unlock(payload);
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
