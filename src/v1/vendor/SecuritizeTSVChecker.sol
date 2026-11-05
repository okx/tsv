/**
 * Copyright 2026 Securitize Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.22;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC165} from "../../../lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {BaseAllowlistChecker} from "./permissionedPools/BaseAllowListChecker.sol";
import {PermissionFlag, PermissionFlags} from "./permissionedPools/libraries/PermissionFlags.sol";
import {IAllowlistChecker} from "./permissionedPools/interfaces/IAllowlistChecker.sol";
import {ISecuritizeTSVChecker} from "./interfaces/ISecuritizeTSVChecker.sol";
import {IDSServiceConsumer} from "./interfaces/IDSServiceConsumer.sol";
import {IDSRegistryService} from "./interfaces/IDSRegistryService.sol";
import {IDSLockManager} from "./interfaces/IDSLockManager.sol";
import {IDSBlackListManager} from "./interfaces/IDSBlackListManager.sol";
import {IDSWalletManager} from "./interfaces/IDSWalletManager.sol";
import {IDSToken} from "./interfaces/IDSToken.sol";

/**
 * @title SecuritizeTSVChecker
 * @notice Issuer-eligibility checker for CETs (DS tokens) traded on Tokenized Securities Venues built on
 *         Uniswap v4 permissioned pools. One checker serves every CET on a chain.
 * @dev Every DS service is resolved from the token itself (getDSService), so no per-CET registration is needed.
 *      Venue-facing views never revert: if the token is not a DS token or any service read fails, they return
 *      NONE / false, so the checker can never authorize an unwind by error.
 *
 *      checkAllowlist(account, token) evaluation order, first match wins:
 *        1. token paused                                                   -> NONE
 *        2. account reported lost                                          -> UNWIND_ALLOWED
 *        3. account not registered to an investor, or a platform wallet    -> NONE
 *        4. account blacklisted, investor locked, or token in wind-down     -> UNWIND_ALLOWED
 *        5. investor liquidity-restricted for this token                   -> SWAP_ALLOWED
 *           otherwise                                                      -> SWAP_ALLOWED | LIQUIDITY_ALLOWED
 */
contract SecuritizeTSVChecker is ISecuritizeTSVChecker, BaseAllowlistChecker, UUPSUpgradeable, OwnableUpgradeable {
    event WindDownSet(address indexed tokenAddress, bool isWindDown);
    event ReportedLostSet(address indexed wallet, bool isReportedLost);
    event LiquidityRestrictionSet(string investorId, address indexed tokenAddress, bool restricted);

    /// @notice Thrown when an invalid address (zero address) is provided
    /// @custom:selector 0xe6c4247b
    error InvalidAddress();

    /// @notice Thrown when an empty investor ID is provided
    error InvalidInvestorId();

    /// @notice Thrown when a DS service of `token` cannot be read
    error ServiceUnavailable(address token);

    /// @notice Thrown when reporting lost a wallet that is not registered to an investor
    error WalletNotRegistered(address wallet);

    /// @notice Thrown when reporting lost a wallet that is already reported lost
    error WalletAlreadyReportedLost(address wallet);

    /// @notice Thrown when clearing a wallet that is not reported lost
    error WalletNotReportedLost(address wallet);

    /// @notice Securitize permission bit: the adapter owner may force-unwind the account's positions
    PermissionFlag public constant UNWIND_ALLOWED = PermissionFlag.wrap(0x8000);

    /// @notice DS service IDs (see IDSServiceConsumer in the DS protocol)
    uint256 public constant REGISTRY_SERVICE = 4;
    uint256 public constant WALLET_MANAGER = 32;
    uint256 public constant LOCK_MANAGER = 64;
    uint256 public constant BLACKLIST_MANAGER = 8197;

    /// @notice Tokens in wind-down (cash merger, liquidation, delisting): every holder becomes unwindable
    mapping(address token => bool) public windDown;

    /// @notice Investor ID recorded when a wallet was reported lost; empty if not reported lost
    /// @dev Keyed per wallet only: CETs share the Global Registry Service, so a lost wallet is lost for all CETs
    mapping(address wallet => string) public lostInvestorId;

    /// @notice Investors restricted from providing liquidity for a token
    mapping(string investorId => mapping(address token => bool)) public liquidityRestricted;

    /// @dev Modifier to validate that address is not zero
    /// @param account The address to validate
    modifier notZeroAddress(address account) {
        if (account == address(0)) {
            revert InvalidAddress();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract, making the deployer the owner
     * @dev Ownership is expected to be transferred to the Securitize owner wallet after deployment
     */
    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Venue-facing views
    // ---------------------------------------------------------------------------------------------------------------

    /**
     * @notice Returns the permission flags for `account` with respect to the CET `tokenAddress`
     * @dev Never reverts and never returns ALL_ALLOWED (0xFFFF)
     * @param account The account to check
     * @param tokenAddress The CET (DS token)
     * @return The permission flags
     */
    function checkAllowlist(
        address account,
        address tokenAddress
    ) public view override(BaseAllowlistChecker, IAllowlistChecker) returns (PermissionFlag) {
        // 1. Paused (or not a DS token)
        (bool ok, bool flag) = _readBool(tokenAddress, abi.encodeCall(IDSToken.isPaused, ()));
        if (!ok || flag) {
            return PermissionFlags.NONE;
        }

        // 2. Reported lost
        if (bytes(lostInvestorId[account]).length != 0) {
            return UNWIND_ALLOWED;
        }

        // 3. Not registered to an investor, or a platform wallet (adapters, venue contracts)
        string memory investorId;
        (ok, investorId) = _getInvestor(tokenAddress, account);
        if (!ok || bytes(investorId).length == 0) {
            return PermissionFlags.NONE;
        }
        (ok, flag) = _readServiceBool(
            tokenAddress,
            WALLET_MANAGER,
            abi.encodeCall(IDSWalletManager.isPlatformWallet, (account))
        );
        if (!ok || flag) {
            return PermissionFlags.NONE;
        }

        // 4. Blacklisted, investor locked, or token in wind-down
        (ok, flag) = _readServiceBool(
            tokenAddress,
            BLACKLIST_MANAGER,
            abi.encodeCall(IDSBlackListManager.isBlacklisted, (account))
        );
        if (!ok) {
            return PermissionFlags.NONE;
        }
        bool unwind = flag;
        (ok, flag) = _readServiceBool(
            tokenAddress,
            LOCK_MANAGER,
            abi.encodeCall(IDSLockManager.isInvestorLocked, (investorId))
        );
        if (!ok) {
            return PermissionFlags.NONE;
        }
        if (unwind || flag || windDown[tokenAddress]) {
            return UNWIND_ALLOWED;
        }

        // 5. Eligible investor
        if (liquidityRestricted[investorId][tokenAddress]) {
            return PermissionFlags.SWAP_ALLOWED;
        }
        return PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED;
    }

    /// @inheritdoc ISecuritizeTSVChecker
    function isUnwindable(address account, address tokenAddress) external view returns (bool) {
        return checkAllowlist(account, tokenAddress) == UNWIND_ALLOWED;
    }

    /// @inheritdoc ISecuritizeTSVChecker
    function canReassign(address from, address to, address tokenAddress) external view returns (bool) {
        string memory investorId = lostInvestorId[from];
        if (bytes(investorId).length == 0 || bytes(lostInvestorId[to]).length != 0) {
            return false;
        }

        (bool ok, bool flag) = _readBool(tokenAddress, abi.encodeCall(IDSToken.isPaused, ()));
        if (!ok || flag) {
            return false;
        }

        string memory toInvestorId;
        (ok, toInvestorId) = _getInvestor(tokenAddress, to);
        if (!ok || keccak256(bytes(toInvestorId)) != keccak256(bytes(investorId))) {
            return false;
        }

        (ok, flag) = _readServiceBool(
            tokenAddress,
            BLACKLIST_MANAGER,
            abi.encodeCall(IDSBlackListManager.isBlacklisted, (to))
        );
        if (!ok || flag) {
            return false;
        }

        (ok, flag) = _readServiceBool(
            tokenAddress,
            LOCK_MANAGER,
            abi.encodeCall(IDSLockManager.isInvestorLocked, (investorId))
        );
        return ok && !flag;
    }

    /**
     * @notice ERC-165: IAllowlistChecker (0x9d38cc8c), ISecuritizeTSVChecker extension (0x3fbe4f67), IERC165
     * @param interfaceId The interface ID to check
     */
    function supportsInterface(bytes4 interfaceId) public view override(BaseAllowlistChecker, IERC165) returns (bool) {
        return interfaceId == type(ISecuritizeTSVChecker).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin (owner only, not part of the venue interface)
    // ---------------------------------------------------------------------------------------------------------------

    /**
     * @notice Sets or clears the wind-down state of a token
     * @dev Runbook: set wind-down, unwind the remaining positions, and only then pause the token
     * @param tokenAddress The CET
     * @param isWindDown The new state
     */
    function setWindDown(address tokenAddress, bool isWindDown) external onlyOwner notZeroAddress(tokenAddress) {
        windDown[tokenAddress] = isWindDown;
        emit WindDownSet(tokenAddress, isWindDown);
    }

    /**
     * @notice Reports a wallet lost, recording the investor ID it is registered to in the token's registry
     * @dev Runbook: blacklist (or lock) the wallet on the token first so it cannot receive CETs, then call this
     *      while the wallet is still registered. Removing it from the registry afterwards is optional.
     *      `tokenAddress` is only used to resolve the registry.
     * @param wallet The lost wallet
     * @param tokenAddress Any CET using the registry the wallet is registered in
     */
    function setReportedLost(
        address wallet,
        address tokenAddress
    ) external onlyOwner notZeroAddress(wallet) notZeroAddress(tokenAddress) {
        if (bytes(lostInvestorId[wallet]).length != 0) {
            revert WalletAlreadyReportedLost(wallet);
        }
        (bool ok, string memory investorId) = _getInvestor(tokenAddress, wallet);
        if (!ok) {
            revert ServiceUnavailable(tokenAddress);
        }
        if (bytes(investorId).length == 0) {
            revert WalletNotRegistered(wallet);
        }
        lostInvestorId[wallet] = investorId;
        emit ReportedLostSet(wallet, true);
    }

    /**
     * @notice Clears a lost-wallet report
     * @param wallet The wallet previously reported lost
     */
    function clearReportedLost(address wallet) external onlyOwner {
        if (bytes(lostInvestorId[wallet]).length == 0) {
            revert WalletNotReportedLost(wallet);
        }
        delete lostInvestorId[wallet];
        emit ReportedLostSet(wallet, false);
    }

    /**
     * @notice Restricts or unrestricts an investor from providing liquidity for a token
     * @param investorId The investor ID
     * @param tokenAddress The CET
     * @param restricted The new state
     */
    function setLiquidityRestricted(
        string calldata investorId,
        address tokenAddress,
        bool restricted
    ) external onlyOwner notZeroAddress(tokenAddress) {
        if (bytes(investorId).length == 0) {
            revert InvalidInvestorId();
        }
        liquidityRestricted[investorId][tokenAddress] = restricted;
        emit LiquidityRestrictionSet(investorId, tokenAddress, restricted);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Proxy helpers
    // ---------------------------------------------------------------------------------------------------------------

    /**
     * @notice Returns the proxy's ERC1967 implementation address
     * @dev Useful for verifying the current implementation
     * @return The address of the current implementation contract
     * @custom:selector 0x35f5011d
     */
    function getImplementationAddress() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @notice Returns the highest version that has been initialized
     * @dev Useful for tracking upgrade history
     * @return The initialization version number
     * @custom:selector 0x8129fc1c
     */
    function getInitializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    /**
     * @dev Authorizes contract upgrades, restricted to owner only
     * @param newImplementation The address of the new implementation (unused but required by interface)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ---------------------------------------------------------------------------------------------------------------
    // Fail-safe reads: low-level staticcalls with return-data validation, so a missing, reverting or malformed
    // service yields ok = false instead of reverting (try/catch cannot catch ABI decoding failures).
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Reads the investor ID of `wallet` from the token's registry
    function _getInvestor(address token, address wallet) private view returns (bool ok, string memory investorId) {
        address registry;
        (ok, registry) = _getService(token, REGISTRY_SERVICE);
        if (!ok) {
            return (false, "");
        }
        return _readString(registry, abi.encodeCall(IDSRegistryService.getInvestor, (wallet)));
    }

    /// @dev Resolves a DS service of `token` and reads a bool from it
    function _readServiceBool(
        address token,
        uint256 serviceId,
        bytes memory data
    ) private view returns (bool ok, bool value) {
        address service;
        (ok, service) = _getService(token, serviceId);
        if (!ok) {
            return (false, false);
        }
        return _readBool(service, data);
    }

    /// @dev Resolves a DS service address; fails if the token does not answer or returns the zero address
    function _getService(address token, uint256 serviceId) private view returns (bool ok, address service) {
        uint256 word;
        (ok, word) = _readWord(token, abi.encodeCall(IDSServiceConsumer.getDSService, (serviceId)));
        if (!ok || word == 0 || word > type(uint160).max) {
            return (false, address(0));
        }
        return (true, address(uint160(word)));
    }

    /// @dev Reads a strictly ABI-encoded bool (0 or 1)
    function _readBool(address target, bytes memory data) private view returns (bool ok, bool value) {
        uint256 word;
        (ok, word) = _readWord(target, data);
        if (!ok || word > 1) {
            return (false, false);
        }
        return (true, word == 1);
    }

    /// @dev Reads the first 32-byte word returned by `target`. Calls to accounts without code succeed with empty
    ///      return data, so they fail the length check.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (!ok || ret.length < 32) {
            return (false, 0);
        }
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Reads an ABI-encoded string, validating offset and length before decoding
    function _readString(address target, bytes memory data) private view returns (bool ok, string memory value) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (!ok || ret.length < 64) {
            return (false, "");
        }
        uint256 offset = abi.decode(ret, (uint256));
        if (offset > ret.length - 32) {
            return (false, "");
        }
        uint256 length;
        assembly {
            length := mload(add(add(ret, 32), offset))
        }
        if (length > ret.length - 32 - offset) {
            return (false, "");
        }
        return (true, abi.decode(ret, (string)));
    }
}
