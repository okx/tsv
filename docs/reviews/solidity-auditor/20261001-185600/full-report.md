# 🔐 Security Review — tsv

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/v1/types/TSVReports.sol` · `src/v1/types/TSVTypes.sol` · `src/v1/core/TSVVolumeLedgerV1.sol`<br>`src/v1/core/TSVDataInboxV1.sol` · `src/v1/core/TSVHookV1.sol` · `src/v1/core/TSVRegistryV1.sol`<br>`src/v1/legacy/IssuerShareSettlementAdapter.sol` · `src/v1/legacy/IAssetSettlementAdapter.sol` · `src/v1/libraries/ReportValidationLib.sol`<br>`src/v1/libraries/TradeDayLib.sol` · `src/v1/libraries/LegalShareMath.sol` · `src/v1/libraries/TSVDirectSettlementLib.sol`<br>`src/v1/periphery/TSVSwapRouterV1.sol` · `src/v1/periphery/TSVLPManagerV1.sol` · `src/v1/adapters/ERC8056LegalShareAdapter.sol`<br>`src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol` · `src/v1/adapters/StaticLegalShareAdapter.sol` · `src/v1/deployment/TSVERC1967Proxy.sol`<br>`src/v1/deployment/TSVHookProxyFactoryV1.sol` · `src/v1/governance/TSVGovernanceAnchor.sol` · `src/v1/governance/TSVGoverned.sol`<br>`src/v1/governance/TSVUpgradeTimelock.sol` · `src/v1/governance/TSVEmergencyUpgradeController.sol` · `src/v1/governance/TSVBusinessAuthority.sol`<br>`script/DeployGovernanceV1.s.sol` · `script/VerifyDeploymentV1.s.sol` · `script/DeployCoreV1.s.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 2 records before this scan · 6 after · `f597879` |

---

## Findings

[95] **1. A zero output bypasses the LP minimum**

`TSVLPManagerV1._settle` · Confidence: 95 · seen in 3/3 runs · NEW

**Description**
When a close or decrease returns zero for one currency, `_settle` skips that currency's positive minimum output. A pool price at the position boundary can therefore let `closePosition` burn a position without delivering the amount its owner required.

**Fix**

```diff
- if ((delta > 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+ if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
```

---

[95] **2. Adapter replacement can mix legal-share units within the daily cap**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 95 · seen in 3/3 runs · KNOWN (2 scans)

**Description**
An authorized adapter replacement can change the legal-share unit while a security's daily usage still contains the old unit. The Registry accepts a token-only pause and has no on-chain next-day gate; after authorized roles clear the pause, a trader can add new-unit charges to old-unit usage and exceed the intended cap. The admission runbook requires a security-wide pause through the next trade day and matching reports, but the contract does not enforce that waiting period.

**Fix**

```text
Bind adapter/unit changes to a security-level unit epoch and prevent trading until the next trade day and matching ADTV/quota are active, or convert all affected daily usage and limits before trading resumes.
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | A zero output bypasses the LP minimum |
| 2 | [95] | Adapter replacement can mix legal-share units within the daily cap |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **A maximum report sequence can block later reports** — `TSVDataInboxV1._accept` · seen in 2/3 runs · NEW — The function accepts any larger `uint64` sequence. If a reporter submits `type(uint64).max`, validation rejects every later report for that key and report type. The trigger requires a trusted reporter role, so this remains a lead.
- **Adapter proxy logic may change after registration** — `TSVRegistryV1.registerToken` · seen in 3/3 runs · KNOWN (2 scans) — Registration checks the adapter proxy's runtime code hash, but later quota accounting trusts its live conversion logic. The audit did not verify whether an approved adapter is upgradeable.
- **Token proxy behavior may change after approval** — `TSVRegistryV1.registerToken` · seen in 3/3 runs · NEW — The registry checks the token's runtime code hash but does not enforce `poolImplementationHash`. The audit did not verify whether an approved token is upgradeable.
- **Relisting can reuse an old open market status** — `TSVRegistryV1.relistSecurity` · seen in 3/3 runs · NEW — Relisting preserves the old market status, so a pool may be enabled without a fresh market report. The audit did not verify whether the reporting process requires a new report.

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed. `.solidity-auditor/memory.tsv`._

_None — every record in the ledger was raised again by this scan._

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
