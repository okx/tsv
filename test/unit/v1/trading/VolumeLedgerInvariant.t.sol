// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VolumeLedgerFixture, TSVRegistryV1, PoolRecord} from "../../../helpers/v1/VolumeLedgerFixture.sol";
import {VolumeLedgerHandler} from "../../../helpers/v1/VolumeLedgerHandler.sol";

contract TSVVolumeLedgerInvariantTest is VolumeLedgerFixture {
    VolumeLedgerHandler private handler;

    function setUp() public override {
        super.setUp();
        bytes32[2] memory securities = [SECURITY, OTHER_SECURITY];
        bytes32[4] memory pools = [
            keccak256("model-pool-0"), keccak256("model-pool-1"), keccak256("model-pool-2"), keccak256("model-pool-3")
        ];
        handler = new VolumeLedgerHandler(ledger, registry, DAY, securities, pools);
        vm.mockCall(address(registry), abi.encodeCall(registry.hook, ()), abi.encode(address(handler)));
        for (uint256 i; i < pools.length; ++i) {
            PoolRecord memory pool;
            pool.securityId = securities[i / 2];
            vm.mockCall(address(registry), abi.encodeCall(TSVRegistryV1.getPool, (pools[i])), abi.encode(pool));
        }
        registry.grantRole(bytes32(0), address(handler));
        registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VolumeLedgerHandler.setQuota.selector;
        selectors[1] = VolumeLedgerHandler.correctUsage.selector;
        selectors[2] = VolumeLedgerHandler.recordSwap.selector;
        selectors[3] = VolumeLedgerHandler.batchQuotaAndUsage.selector;
        selectors[4] = VolumeLedgerHandler.toggleOracle.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantQuotaAndUsageMatchModelAcrossSecuritiesPoolsAndDays() public view {
        for (uint256 security; security < 2; ++security) {
            bytes32 id = security == 0 ? SECURITY : OTHER_SECURITY;
            for (uint256 day; day < 3; ++day) {
                assertEq(ledger.Quota(id, DAY + day), handler.modelQuota(security, day));
                assertEq(ledger.usedWad(id, DAY + day), handler.modelUsed(security, day));
            }
        }
        assertEq(registry.hasRole(ledger.VOLUME_ORACLE_ROLE(), address(handler)), handler.oracleAllowed());
    }
}
