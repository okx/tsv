// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ITSVLPRegistry} from "tsv-v1/interfaces/ITSVLPRegistry.sol";
import {ITSVPermissionedRegistry} from "tsv-v1/interfaces/ITSVPermissionedRegistry.sol";
import {PoolKey, Currency, IHooks} from "v4-core/types/PoolKey.sol";
import {PoolKey as LPPoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency as LPCurrency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks as LPHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

contract LPRegistryABITest is Test {
    function testFuzzPinnedPoolKeysHaveIdenticalRegistryCalldata(uint24 fee, int24 spacing, int256 delta) public pure {
        PoolKey memory venue =
            PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), fee, spacing, IHooks(address(3)));
        LPPoolKey memory lp =
            LPPoolKey(LPCurrency.wrap(address(1)), LPCurrency.wrap(address(2)), fee, spacing, LPHooks(address(3)));
        assertEq(
            abi.encodeCall(ITSVLPRegistry.registerPool, (lp)),
            abi.encodeCall(ITSVPermissionedRegistry.registerPool, (venue))
        );
        assertEq(
            abi.encodeCall(ITSVLPRegistry.updatePoolTickCount, (lp, delta)),
            abi.encodeCall(ITSVPermissionedRegistry.updatePoolTickCount, (venue, delta))
        );
    }
}
