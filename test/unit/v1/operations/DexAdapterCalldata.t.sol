// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TradeDexRouterTSV} from "../../../../script/xlayer/TradeDexRouterTSV.s.sol";
import {ITSVDEXAdapter} from "tsv-v1/interfaces/external/ITSVDEXAdapter.sol";

contract DexAdapterCalldataHarness is TradeDexRouterTSV {
    function build(bool buy, ITSVDEXAdapter.MoreInfo memory info) external pure returns (bytes memory) {
        return _buildMoreInfo(buy, info);
    }
}

/// @dev Tests this repository's operator wire format, not the external adapter implementation.
contract DexAdapterCalldataTest is Test {
    function testBuyPayloadUsesTheLiveBalanceSentinelWithoutChangingThePool() public {
        _check(true, 0);
    }

    function testSalePayloadPreservesTheExactFundedAmount() public {
        _check(false, 123456);
    }

    function _check(bool buy, uint256 expected) private {
        ITSVDEXAdapter.PoolKey memory key = ITSVDEXAdapter.PoolKey(address(1), address(2), 2000, 10, address(3));
        bytes memory payload = new DexAdapterCalldataHarness().build(buy, ITSVDEXAdapter.MoreInfo(key, 1e18, 123456));
        assertEq(payload.length, 224);
        ITSVDEXAdapter.MoreInfo memory decoded = abi.decode(payload, (ITSVDEXAdapter.MoreInfo));
        assertEq(keccak256(abi.encode(decoded.key)), keccak256(abi.encode(key)));
        assertEq(decoded.expectedMultiplier, 1e18);
        assertEq(decoded.amountIn, expected);
    }
}
