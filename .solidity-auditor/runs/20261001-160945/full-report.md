# 🔐 Security Review — tsv

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./script/DeployGovernanceV1.s.sol` · `./script/VerifyDeploymentV1.s.sol` · `./script/DeployCoreV1.s.sol`<br>`./src/v1/types/TSVReports.sol` · `./src/v1/types/TSVTypes.sol` · `./src/v1/core/TSVVolumeLedgerV1.sol`<br>`./src/v1/core/TSVDataInboxV1.sol` · `./src/v1/core/TSVHookV1.sol` · `./src/v1/core/TSVRegistryV1.sol`<br>`./src/v1/legacy/IssuerShareSettlementAdapter.sol` · `./src/v1/legacy/IAssetSettlementAdapter.sol` · `./src/v1/libraries/ReportValidationLib.sol`<br>`./src/v1/libraries/TradeDayLib.sol` · `./src/v1/libraries/LegalShareMath.sol` · `./src/v1/libraries/TSVDirectSettlementLib.sol`<br>`./src/v1/periphery/TSVSwapRouterV1.sol` · `./src/v1/periphery/TSVLPManagerV1.sol` · `./src/v1/adapters/ERC8056LegalShareAdapter.sol`<br>`./src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol` · `./src/v1/adapters/StaticLegalShareAdapter.sol` · `./src/v1/deployment/TSVERC1967Proxy.sol`<br>`./src/v1/deployment/TSVHookProxyFactoryV1.sol` · `./src/v1/governance/TSVGovernanceAnchor.sol` · `./src/v1/governance/TSVGoverned.sol`<br>`./src/v1/governance/TSVUpgradeTimelock.sol` · `./src/v1/governance/TSVEmergencyUpgradeController.sol` · `./src/v1/governance/TSVBusinessAuthority.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 0 records before this scan · 2 after · `797e7b8` |

---

## Findings

[75] **1. Daily quota mixes old and new share units**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
After the adapter changes, a trader adds 10 new units to 90 old against cap 100; converted use is 19 against cap 10.

**Fix**

```diff
@@ replaceLegalShareAdapter
-                || newAdapter.code.length == 0 || evidenceHash == 0 || !_assetPausedForReplacement(currency)
+                || newAdapter.code.length == 0 || evidenceHash == 0
+                || !_assetPausedForReplacement(currency) || !_isPaused(PauseScope.SECURITY, config.securityId)
@@ security unit transition
+    // Keep every pool for this security paused until the next trade day.
+    // Convert the used volume, ADTV, and quota to the new share unit before reopening.
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Daily quota mixes old and new share units |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Upgradeable adapter can bypass the daily volume cap** — `TSVRegistryV1.registerToken` · seen in 2/3 runs · NEW — Code smells: Registration stores an adapter proxy's runtime code hash, but swaps check only its version and `isCurrent()`. A proxy admin can change `toLegalShares()` without changing the proxy hash; the deployment bundle does not show an approved adapter proxy.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
