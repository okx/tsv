// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapRequest} from "tsv-v1/types/TSVTypes.sol";
import {TSVSwapRouterV1} from "tsv-v1/periphery/TSVSwapRouterV1.sol";

/// @dev TEST ONLY: implements the actual DEX sellBase/sellQuote callback ABI.
///      The pinned v1.0.10 DEX appends two words; the last is ORIGIN_PAYER | original caller.
///      Eligibility comes from this authenticated marker, never tx.origin or a request field.
contract DexRouterTestAdapter {
    using SafeERC20 for IERC20;
    uint256 public constant ORIGIN_PAYER = 0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;
    address public immutable dexRouter;
    TSVSwapRouterV1 public immutable tsvRouter;
    address public lastParticipant;
    uint256 public lastActualIn;
    uint256 public lastActualOut;
    bool private entered;

    error UnauthorizedDex();
    error InvalidMarker(uint256 marker, uint256 calldataLength, uint256 expectedLength);
    error InvalidRoute();
    error Reentrancy();

    constructor(address dex, TSVSwapRouterV1 router) {
        require(dex.code.length != 0 && address(router).code.length != 0);
        dexRouter = dex;
        tsvRouter = router;
    }

    function sellBase(address to, address pool, bytes calldata moreInfo) external {
        _sell(to, pool, moreInfo, true);
    }

    function sellQuote(address to, address pool, bytes calldata moreInfo) external {
        _sell(to, pool, moreInfo, false);
    }

    function _sell(address to, address pool, bytes calldata moreInfo, bool direction) private {
        if (msg.sender != dexRouter) revert UnauthorizedDex();
        if (entered) revert Reentrancy();
        entered = true;
        uint256 marker;
        assembly ("memory-safe") { marker := calldataload(sub(calldatasize(), 32)) }
        if (
            msg.data.length != 196 + ((moreInfo.length + 31) / 32) * 32
                || (marker & ~uint256(type(uint160).max)) != ORIGIN_PAYER || address(uint160(marker)) == address(0)
        ) revert InvalidMarker(marker, msg.data.length, 196 + ((moreInfo.length + 31) / 32) * 32);
        address participant = address(uint160(marker));
        SwapRequest memory request = abi.decode(moreInfo, (SwapRequest));
        if (pool != address(tsvRouter) || to == address(0) || request.zeroForOne != direction) revert InvalidRoute();
        IERC20 input = IERC20(Currency.unwrap(direction ? request.key.currency0 : request.key.currency1));
        IERC20 output = IERC20(Currency.unwrap(direction ? request.key.currency1 : request.key.currency0));
        // This fixture consumes only the route's declared amount. Existing donations stay untouched.
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));
        require(inputBefore >= request.amountSpecified);
        input.forceApprove(address(tsvRouter), request.amountSpecified);
        (uint256 actualIn, uint256 actualOut) = tsvRouter.swapExactInputFromAdapter(request, participant);
        input.forceApprove(address(tsvRouter), 0);
        require(inputBefore - input.balanceOf(address(this)) == actualIn);
        require(output.balanceOf(address(this)) - outputBefore == actualOut);
        output.safeTransfer(to, actualOut);
        uint256 refund = uint256(request.amountSpecified) - actualIn;
        if (refund != 0) input.safeTransfer(participant, refund);
        lastParticipant = participant;
        lastActualIn = actualIn;
        lastActualOut = actualOut;
        entered = false;
    }
}

/// @dev A contract participant makes the DEX call itself; the controlling EOA is not the trader.
contract DexRouterTestWallet {
    address public immutable admin;

    constructor(address owner) {
        admin = owner;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == admin);
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(returned, 32), mload(returned)) }
        return returned;
    }
}
