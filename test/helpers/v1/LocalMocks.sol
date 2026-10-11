// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";

/// @dev Exposes token metadata required by the local integration fixture.
interface ITestTokenMetadata {
    /// @dev Returns the token decimal precision used by the fixture.
    function decimals() external view returns (uint8);
}

/// @dev Provides a configurable ERC-20 fixture for local protocol tests.
contract V1LocalERC20 is ERC20 {
    address public blockedRecipient;
    address public feeSender;
    uint16 public senderFeeBps;
    // Faults are opt-in and affect only integration tests.
    uint8 public transferMode;
    address public callbackTarget;
    bytes public callbackData;
    bool private inCallback;

    /// @dev Initializes the local token fixture with matching name and symbol.
    constructor(string memory n) ERC20(n, n) {}

    /// @dev Mints local test tokens to a recipient.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Configures whether the local token rejects transfers to a recipient.
    function setBlockedRecipient(address to) external {
        blockedRecipient = to;
    }

    /// @dev Configures the fee deducted from the sender by the local token.
    function setSenderFee(address sender, uint16 feeBps) external {
        require(feeBps <= 10_000);
        feeSender = sender;
        senderFeeBps = feeBps;
    }

    /// @dev 0=standard, 1=recipient tax, 2=false return, 3=short transfer, 4=no return data.
    function setTransferMode(uint8 mode) external {
        require(mode <= 4);
        transferMode = mode;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly { return(0, 0) }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, transferMode == 3 ? value - 1 : value);
        if (transferMode == 2) return false;
        if (transferMode == 4) assembly { return(0, 0) }
        return true;
    }

    /// @dev Applies the local token transfer behavior, including configured fees and restrictions.
    function _update(address from, address to, uint256 value) internal override {
        require(to == address(0) || to != blockedRecipient, "issuer blocked recipient");
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && transferMode == 1) {
            super._update(to, address(0), value / 100);
        }
        if (from != address(0) && to != address(0) && from == feeSender && senderFeeBps != 0) {
            uint256 fee = (value * senderFeeBps) / 10_000;
            if (fee != 0) super._update(from, address(this), fee);
        }
        if (from != address(0) && to != address(0) && callbackTarget != address(0) && !inCallback) {
            inCallback = true;
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            if (!ok) assembly { revert(add(result, 32), mload(result)) }
            inCallback = false;
        }
    }
}

/// @dev Provides configurable SBT pause and credential behavior for local tests.
contract V1LocalSBT {
    mapping(address => mapping(uint256 => bool)) public holds;
    bool private paused_;
    bool public failVerify;
    bool public failPaused;

    /// @dev Configures the holder and token identifier accepted by the local SBT fixture.
    function setHolder(address owner, uint256 tokenId, bool value) external {
        holds[owner][tokenId] = value;
    }

    /// @dev Configures the pause state reported by the local SBT fixture.
    function setPaused(bool value) external {
        paused_ = value;
    }

    /// @dev Configures whether SBT view calls revert in the local fixture.
    function setFailReads(bool verify_, bool pausedRead_) external {
        failVerify = verify_;
        failPaused = pausedRead_;
    }

    /// @dev Returns the pause state reported by the local SBT fixture.
    function paused() external view returns (bool) {
        require(!failPaused, "paused read failed");
        return paused_;
    }

    /// @dev Checks the configured participant credential in the local SBT fixture.
    function verify(address owner, uint256 tokenId) external view returns (bool) {
        require(!failVerify, "verify read failed");
        return holds[owner][tokenId];
    }
}

/// @dev Provides a contract-wallet participant for direct-call integration tests.
contract V1TestParticipantWallet {
    address public immutable admin;

    /// @dev Sets the account authorized to execute calls through the participant wallet.
    constructor(address admin_) {
        admin = admin_;
    }

    /// @dev Approves the Swap Router to transfer a selected input token.
    function approveToken(address token, address spender) external {
        require(msg.sender == admin);
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Runs an exact-input swap through the test participant wallet.
    function swapExactInput(TSVSwapRouterV1 router, V1TestExternalAdapter adapter, SwapRequest calldata request)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        require(msg.sender == admin);
        return adapter.swapExactInputDirect(router, request, address(this), address(this));
    }
}

/// @dev Routes a test swap through the Router's external Adapter entry.
contract V1TestExternalAdapter {
    /// @dev Approves the Router to pull the test Adapter's input Currency.
    function approveToken(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    /// @dev Executes a direct-settlement Router exact-input swap for the supplied participant.
    function swapExactInputDirect(
        TSVSwapRouterV1 router,
        SwapRequest calldata request,
        address participant,
        address recipient
    ) external returns (uint256 actualIn, uint256 actualOut) {
        return router.swapExactInputFromAdapterDirect(request, participant, recipient);
    }
}

/// @dev Precision fixture for settlement in pools whose currencies have different decimals.
contract V1LocalERC20Decimals is V1LocalERC20 {
    uint8 private immutable precision;

    constructor(string memory name_, uint8 decimals_) V1LocalERC20(name_) {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }
}
