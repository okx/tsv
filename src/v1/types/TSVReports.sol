// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketAction} from "tsv-v1/types/TSVTypes.sol";

struct MarketReport {
    bytes32 securityId;
    MarketAction action;
    bytes32 reasonCode;
    bytes32 exchangeHash;
    uint64 sourceTimestamp;
    uint64 submitDeadline;
    uint64 sequence;
    bytes32 reportId;
    bytes32 sourceHash;
}

struct AdtvReport {
    bytes32 securityId;
    uint32 sourceMonth;
    uint256 adtvWad;
    uint64 sourceTimestamp;
    uint64 submitDeadline;
    uint64 version;
    uint64 sequence;
    bytes32 reportId;
    bytes32 sourceHash;
}

struct QuotaReport {
    bytes32 securityId;
    uint32 tradeDayId;
    uint8 action;
    uint256 quotaWad;
    uint64 sourceTimestamp;
    uint64 submitDeadline;
    uint64 version;
    uint64 sequence;
    bytes32 reportId;
    bytes32 sourceHash;
}
