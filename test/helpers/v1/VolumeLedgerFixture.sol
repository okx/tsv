// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVERC1967Proxy} from "tsv-v1/deployment/TSVERC1967Proxy.sol";
import {PoolRecord} from "tsv-v1/types/TSVTypes.sol";

/// @dev Real Registry and Ledger proxies; only Hook identity and pool-to-security lookup are mocked.
abstract contract VolumeLedgerFixture is Test {
    TSVRegistryV1 internal registry;
    TSVVolumeLedgerV1 internal ledger;
    bytes32 internal constant SECURITY = keccak256("security");
    bytes32 internal constant OTHER_SECURITY = keccak256("other-security");
    bytes32 internal constant POOL = keccak256("pool");
    bytes32 internal constant REASON = bytes32("CORRECTION");
    uint256 internal constant DAY = 20738;

    function setUp() public virtual {
        registry = TSVRegistryV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVRegistryV1()), abi.encodeCall(TSVRegistryV1.initialize, (address(this)))
                )
            )
        );
        ledger = TSVVolumeLedgerV1(
            address(
                new TSVERC1967Proxy(
                    address(new TSVVolumeLedgerV1()), abi.encodeCall(TSVVolumeLedgerV1.initialize, (address(registry)))
                )
            )
        );
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        vm.warp(1791781200);
        vm.mockCall(address(registry), abi.encodeCall(registry.hook, ()), abi.encode(address(this)));
        PoolRecord memory pool;
        pool.securityId = SECURITY;
        vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.getPool, (POOL)), abi.encode(pool));
    }

    function _value(uint256 day, uint256 amount) internal pure returns (TSVVolumeLedgerV1.DailyQuota[] memory values) {
        values = new TSVVolumeLedgerV1.DailyQuota[](1);
        values[0] = TSVVolumeLedgerV1.DailyQuota(day, amount);
    }

    function _swap(uint256 amount) internal {
        ledger.recordSwap(POOL, -1, 1, amount, 0);
    }
}
