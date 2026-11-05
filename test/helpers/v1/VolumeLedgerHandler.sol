// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @dev Independent model of direct quotas, administrative corrections and accepted swap volume.
///      Targets two securities, two pools per security and three days, including role revocation.
contract VolumeLedgerHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    TSVVolumeLedgerV1 public immutable ledger;
    TSVRegistryV1 public immutable registry;
    uint256 public immutable firstDay;
    bytes32[2] private securities;
    bytes32[4] private pools;
    mapping(uint256 => uint256) public modelQuota;
    mapping(uint256 => mapping(uint256 => uint256)) public modelUsed;
    bool public oracleAllowed = true;
    uint256 public acceptedSwaps;
    uint256 public rejectedSwaps;

    constructor(
        TSVVolumeLedgerV1 ledger_,
        TSVRegistryV1 registry_,
        uint256 day_,
        bytes32[2] memory securities_,
        bytes32[4] memory pools_
    ) {
        ledger = ledger_;
        registry = registry_;
        firstDay = day_;
        securities = securities_;
        pools = pools_;
    }

    function setQuota(uint256 securitySeed, uint256 amountSeed) external {
        uint256 security = securitySeed % 2;
        uint256 amount = amountSeed % 1001;
        bytes memory callData = abi.encodeCall(ledger.setQuota, (securities[security], amount, bytes32("MODEL")));
        if (!oracleAllowed) {
            _expectRevert(callData, TSVVolumeLedgerV1.Unauthorized.selector);
            return;
        }
        ledger.setQuota(securities[security], amount, bytes32("MODEL"));
        modelQuota[security] = amount;
    }

    function correctUsage(uint256 securitySeed, uint256 daySeed, uint256 amountSeed) external {
        uint256 security = securitySeed % 2;
        uint256 day = daySeed % 3;
        uint256 amount = amountSeed % 1001;
        bytes memory callData =
            abi.encodeCall(ledger.setUsedWad, (securities[security], _value(day, amount), bytes32("MODEL")));
        if (!oracleAllowed) {
            _expectRevert(callData, TSVVolumeLedgerV1.Unauthorized.selector);
            return;
        }
        ledger.setUsedWad(securities[security], _value(day, amount), bytes32("MODEL"));
        modelUsed[security][day] = amount;
    }

    function recordSwap(uint256 poolSeed, uint256 daySeed, uint256 amountSeed) external {
        uint256 pool = poolSeed % 4;
        uint256 security = pool / 2;
        uint256 day = daySeed % 3;
        uint256 amount = amountSeed % 100 + 1;
        vm.warp((firstDay + day) * 1 days + 17 hours);
        uint256 nextUsed = modelUsed[security][day] + amount;
        bytes memory callData =
            abi.encodeCall(ledger.recordSwap, (pools[pool], int128(-1), int128(1), amount, uint256(0)));
        if (nextUsed > modelQuota[security]) {
            (bool ok, bytes memory reason) = address(ledger).call(callData);
            require(
                !ok
                    && keccak256(reason)
                        == keccak256(
                            abi.encodeWithSelector(
                                TSVVolumeLedgerV1.QuotaExceeded.selector, securities[security], firstDay + day
                            )
                        ),
                "quota failure mismatch"
            );
            ++rejectedSwaps;
            return;
        }
        ledger.recordSwap(pools[pool], -1, 1, amount, 0);
        modelUsed[security][day] = nextUsed;
        ++acceptedSwaps;
    }

    function batchQuotaAndUsage(uint256 securitySeed, uint256 daySeed, uint256 amountSeed, bool invalidReason)
        external
    {
        uint256 security = securitySeed % 2;
        uint256 day = daySeed % 3;
        uint256 quota = amountSeed % 1001;
        uint256 usage = quota / 2;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ledger.setQuota, (securities[security], quota, bytes32("MODEL")));
        calls[1] = abi.encodeCall(
            ledger.setUsedWad, (securities[security], _value(day, usage), invalidReason ? bytes32(0) : bytes32("MODEL"))
        );
        if (!oracleAllowed || invalidReason) {
            _expectRevert(
                abi.encodeCall(ledger.multicall, (calls)),
                !oracleAllowed ? TSVVolumeLedgerV1.Unauthorized.selector : TSVVolumeLedgerV1.InvalidConfig.selector
            );
            return;
        }
        ledger.multicall(calls);
        modelQuota[security] = quota;
        modelUsed[security][day] = usage;
    }

    function toggleOracle(bool allowed) external {
        if (allowed) registry.grantRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        else registry.revokeRole(ledger.VOLUME_ORACLE_ROLE(), address(this));
        oracleAllowed = allowed;
    }

    function _value(uint256 day, uint256 amount) private view returns (TSVVolumeLedgerV1.DailyQuota[] memory values) {
        values = new TSVVolumeLedgerV1.DailyQuota[](1);
        values[0] = TSVVolumeLedgerV1.DailyQuota(firstDay + day, amount);
    }

    function _expectRevert(bytes memory callData, bytes4 expected) private {
        (bool ok, bytes memory reason) = address(ledger).call(callData);
        require(!ok && reason.length >= 4 && bytes4(reason) == expected, "authorization or atomicity mismatch");
    }
}
