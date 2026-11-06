// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";

/// @notice Sets or corrects one security's TSV daily legal-share quota data.
/// @dev Each action uses its own reason-code variable; calls are simulated unless --broadcast is passed.
contract VolumeLedgerOperations is Script {
    uint256 private constant XLAYER_MAINNET_CHAIN_ID = 196;

    function run() external {
        require(block.chainid == XLAYER_MAINNET_CHAIN_ID, "wrong chain: expected XLayer mainnet 196");

        uint256 privateKey = vm.envUint("XLAYER_PRIVATE_KEY");
        address operator = vm.addr(privateKey);
        TSVVolumeLedgerV1 ledger = TSVVolumeLedgerV1(vm.envAddress("TSV_LEDGER"));
        require(address(ledger).code.length != 0, "TSV_LEDGER has no code");
        TSVRegistryV1 registry = ledger.registry();
        require(registry.hasRole(ledger.VOLUME_ORACLE_ROLE(), operator), "signer lacks VOLUME_ORACLE_ROLE");

        string memory action = vm.envString("TSV_LEDGER_ACTION");
        bytes32 actionHash = keccak256(bytes(action));
        bytes32 securityId = vm.envBytes32("TSV_LEDGER_SECURITY_ID");
        require(securityId != bytes32(0), "security ID must be nonzero");
        require(registry.getSecurity(securityId).securityId != bytes32(0), "security ID is unknown");

        console2.log("XLayer chainId:", block.chainid);
        console2.log("Ledger:", address(ledger));
        console2.log("Operator:", operator);
        console2.log("Security ID:");
        console2.logBytes32(securityId);

        if (actionHash == keccak256("SET_QUOTA")) {
            uint256 amountWad = vm.envUint("TSV_QUOTA_AMOUNT_WAD");
            bytes32 reason = _reason("TSV_SET_QUOTA_REASON_CODE");
            console2.log("Previous quota WAD:", ledger.Quota(securityId));
            console2.log("New quota WAD:", amountWad);
            vm.startBroadcast(privateKey);
            ledger.setQuota(securityId, amountWad, reason);
            vm.stopBroadcast();
        } else if (actionHash == keccak256("SET_USED_WAD")) {
            uint256 count = vm.envUint("TSV_USED_WAD_COUNT");
            require(count != 0, "TSV_USED_WAD_COUNT is zero");
            bytes32 reason = _reason("TSV_SET_USED_WAD_REASON_CODE");
            TSVVolumeLedgerV1.DailyQuota[] memory values = new TSVVolumeLedgerV1.DailyQuota[](count);
            for (uint256 i; i < count; ++i) {
                string memory suffix = vm.toString(i);
                uint256 day = vm.envUint(string.concat("TSV_USED_WAD_EST_DAY_", suffix));
                uint256 amount = vm.envUint(string.concat("TSV_USED_WAD_AMOUNT_", suffix));
                for (uint256 j; j < i; ++j) {
                    require(values[j].ESTDay != day, "duplicate EST day in correction list");
                }
                values[i] = TSVVolumeLedgerV1.DailyQuota({ESTDay: day, amount: amount});
                console2.log("EST day:", day);
                console2.log("Corrected usedWad:", amount);
            }
            vm.startBroadcast(privateKey);
            ledger.setUsedWad(securityId, values, reason);
            vm.stopBroadcast();
        } else {
            revert("unknown TSV_LEDGER_ACTION");
        }
    }

    function _reason(string memory variableName) private view returns (bytes32 reason) {
        reason = vm.envBytes32(variableName);
        require(reason != bytes32(0), "operation reason code must be nonzero");
        console2.log("Operation reason:");
        console2.logBytes32(reason);
    }
}
