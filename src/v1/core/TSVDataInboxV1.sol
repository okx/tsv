// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVGoverned} from "tsv-v1/governance/TSVGoverned.sol";
import {TSVRegistryV1} from "tsv-v1/core/TSVRegistryV1.sol";
import {TSVVolumeLedgerV1} from "tsv-v1/core/TSVVolumeLedgerV1.sol";

contract TSVDataInboxV1 is TSVGoverned, EIP712Upgradeable {
    error InvalidSignature();
    error InvalidReport();
    error Expired();

    /// @dev Bounded to keep a monthly report submission within block gas limits.
    uint256 public constant MAX_ADTV_BATCH_SIZE = 100;

    bytes32 public constant MARKET_TYPEHASH = keccak256(
        "MarketReport(address signer,bytes32 securityId,uint8 action,bytes32 reasonCode,bytes32 exchangeHash,uint64 sourceTimestamp,uint64 submitDeadline,uint64 sequence,bytes32 reportId,bytes32 sourceHash)"
    );
    bytes32 public constant ADTV_TYPEHASH = keccak256(
        "AdtvReport(address signer,bytes32 securityId,uint32 sourceMonth,uint256 adtvWad,uint64 sourceTimestamp,uint64 submitDeadline,uint64 version,uint64 sequence,bytes32 reportId,bytes32 sourceHash)"
    );
    bytes32 public constant QUOTA_TYPEHASH = keccak256(
        "QuotaReport(address signer,bytes32 securityId,uint32 tradeDayId,uint8 action,uint256 quotaWad,uint64 sourceTimestamp,uint64 submitDeadline,uint64 version,uint64 sequence,bytes32 reportId,bytes32 sourceHash)"
    );

    TSVRegistryV1 public registry;
    TSVVolumeLedgerV1 public ledger;
    mapping(bytes32 => bool) public reportIdUsed;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSequence;
    mapping(uint8 => mapping(bytes32 => uint64)) public lastSourceTimestamp;

    function initialize(address authority, address timelock, address controller, address registry_, address ledger_)
        external
        initializer
    {
        __TSVGoverned_init(authority, timelock, controller);
        if (registry_ == address(0) || ledger_ == address(0)) revert InvalidReport();
        __EIP712_init("TSVDataInbox", "2");
        registry = TSVRegistryV1(registry_);
        ledger = TSVVolumeLedgerV1(ledger_);
    }

    function submitMarketStatus(MarketReport calldata report, bytes calldata signature) external {
        _accept(
            0,
            report.securityId,
            report.signer,
            HALT_REPORTER_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash,
            _hashTypedDataV4(keccak256(abi.encode(MARKET_TYPEHASH, report))),
            signature
        );
        if (report.securityId == 0 || report.reasonCode == 0 || report.exchangeHash == 0) revert InvalidReport();
        registry.applyMarketStatus(report.securityId, report.action, report.sequence, report.reportId);
    }

    function submitAdtv(AdtvReport calldata report, bytes calldata signature) external {
        _submitAdtv(report, signature);
    }

    /// @notice Atomically accepts the monthly ADTV reports for multiple securities.
    /// @dev Reports must use the same source month and be sorted by unique securityId.
    ///      Each item keeps the existing AdtvReport EIP-712 signature format, so the
    ///      batch does not invalidate already deployed signing infrastructure.
    function submitAdtvBatch(AdtvReport[] calldata reports, bytes[] calldata signatures) external {
        if (reports.length == 0 || reports.length > MAX_ADTV_BATCH_SIZE || reports.length != signatures.length) {
            revert InvalidReport();
        }

        uint32 sourceMonth = reports[0].sourceMonth;
        bytes32 previousSecurityId;
        for (uint256 i; i < reports.length; i++) {
            AdtvReport calldata report = reports[i];
            if (
                report.securityId == 0 || report.sourceMonth != sourceMonth
                    || (i != 0 && uint256(report.securityId) <= uint256(previousSecurityId))
            ) {
                revert InvalidReport();
            }
            _submitAdtv(report, signatures[i]);
            previousSecurityId = report.securityId;
        }
    }

    function _submitAdtv(AdtvReport calldata report, bytes calldata signature) private {
        _accept(
            1,
            report.securityId,
            report.signer,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash,
            _hashTypedDataV4(keccak256(abi.encode(ADTV_TYPEHASH, report))),
            signature
        );
        ledger.acceptAdtv(report);
    }

    function submitQuota(QuotaReport calldata report, bytes calldata signature) external {
        _accept(
            2,
            report.securityId,
            report.signer,
            VOLUME_ORACLE_ROLE,
            report.sourceTimestamp,
            report.submitDeadline,
            report.sequence,
            report.reportId,
            report.sourceHash,
            _hashTypedDataV4(keccak256(abi.encode(QUOTA_TYPEHASH, report))),
            signature
        );
        ledger.acceptQuota(report);
    }

    function _accept(
        uint8 kind,
        bytes32 key,
        address signer,
        bytes32 role,
        uint64 sourceTimestamp,
        uint64 submitDeadline,
        uint64 sequence,
        bytes32 reportId,
        bytes32 sourceHash,
        bytes32 digest,
        bytes calldata signature
    ) private {
        if (
            signer == address(0) || reportId == 0 || sourceHash == 0 || reportIdUsed[reportId]
                || sequence <= lastSequence[kind][key] || sourceTimestamp < lastSourceTimestamp[kind][key]
        ) {
            revert InvalidReport();
        }
        if (sourceTimestamp > block.timestamp || block.timestamp > submitDeadline) revert Expired();
        if (!hasRole(role, signer) || !SignatureChecker.isValidSignatureNow(signer, digest, signature)) {
            revert InvalidSignature();
        }
        lastSequence[kind][key] = sequence;
        lastSourceTimestamp[kind][key] = sourceTimestamp;
        reportIdUsed[reportId] = true;
    }
}
