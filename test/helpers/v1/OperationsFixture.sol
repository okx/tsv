// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {MarketAction, PauseMode} from "tsv-v1/types/TSVTypes.sol";
import {MarketReport, AdtvReport, QuotaReport} from "tsv-v1/types/TSVReports.sol";
import {TSVDataInboxV1} from "tsv-v1/core/TSVDataInboxV1.sol";
import {FoundationFixture} from "./FoundationFixture.sol";

/// @dev Report builders and snapshots only. Success-path V4 tests use ProtocolFixture.
abstract contract OperationsFixture is FoundationFixture {
    struct ReportMetadata {
        uint64 timestamp;
        uint64 deadline;
        uint64 sequence;
        uint64 version;
        bytes32 id;
    }

    function _metadata(uint64 sequence, uint64 version, bytes32 id) internal view returns (ReportMetadata memory) {
        return ReportMetadata(uint64(block.timestamp), uint64(block.timestamp + 100), sequence, version, id);
    }

    function _reportPayload(uint8 kind, ReportMetadata memory m) internal view returns (bytes memory) {
        if (kind == 0) {
            MarketReport memory market =
                _market(m.version == 1 ? MarketAction.HALT : MarketAction.RESUME, m.sequence, m.id);
            market.mode = PauseMode.TRADE;
            market.sourceTimestamp = m.timestamp;
            market.submitDeadline = m.deadline;

            return abi.encodeCall(TSVDataInboxV1.submitMarketStatus, (market));
        }
        if (kind == 1) {
            AdtvReport memory adtv = _adtv(SECURITY, 1000e18, m.version, m.sequence, m.id);
            adtv.sourceTimestamp = m.timestamp;
            adtv.submitDeadline = m.deadline;

            return abi.encodeCall(TSVDataInboxV1.submitAdtv, (adtv));
        }
        QuotaReport memory quota = _quota(2e18, 1, m.version, m.sequence, m.id);
        quota.sourceTimestamp = m.timestamp;
        quota.submitDeadline = m.deadline;

        return abi.encodeCall(TSVDataInboxV1.submitQuota, (quota));
    }

    function _callInbox(bytes memory payload) internal {
        (bool ok, bytes memory result) = address(inbox).call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    function _reportState(bytes32 securityId, uint32 month, uint32 day, bytes32 candidateId)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        inbox.lastSequence(0, securityId),
                        inbox.lastSourceTimestamp(0, securityId),
                        inbox.lastSequence(1, securityId),
                        inbox.lastSourceTimestamp(1, securityId),
                        inbox.lastSequence(2, securityId),
                        inbox.lastSourceTimestamp(2, securityId),
                        inbox.reportIdUsed(candidateId)
                    )
                ),
                registry.getSecurity(securityId),
                registry.marketPauseMode(securityId),
                registry.marketSequence(securityId),
                ledger.adtvOf(securityId, month),
                ledger.quotaOf(securityId, day),
                ledger.used(securityId, day)
            )
        );
    }

    function _reportState(bytes32 candidateId) internal view returns (bytes32) {
        return _reportState(SECURITY, uint32(MONTH), DAY, candidateId);
    }

    /// @dev Unit-only Hook call: legal shares are explicit test inputs, independent of Adapter conversion.
    function _charge(uint256 shares) internal {
        bool stock0 = address(stock) == Currency.unwrap(key.currency0);
        ledger.recordSwap(
            poolId,
            stock0 ? -int128(1e18) : int128(1e6),
            stock0 ? int128(1e6) : -int128(1e18),
            stock0 ? shares : 0,
            stock0 ? 0 : shares
        );
    }
}
