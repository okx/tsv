# Run 2 — solidity-auditor

<!--RUN pass=2 of=3 stamp=20261001-160945 sha=797e7b8 agents=12/12-->

Pass 2 of 3 · 2026-10-01 · `797e7b8` · 12/12 agents returned.

## Findings

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix conf=75 kind=FINDING agents=12-->

[75] **1. Daily quota mixes old and new share units**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 75

**Description**
A symbol admin can change one adapter mid-day while another pool stays open, letting traders exceed the shared quota with mixed share units.

**Fix**

```diff
@@ replaceLegalShareAdapter
-                || newAdapter.code.length == 0 || evidenceHash == 0 || !_assetPausedForReplacement(currency)
+                || newAdapter.code.length == 0 || evidenceHash == 0
+                || !_assetPausedForReplacement(currency) || !_isPaused(PauseScope.SECURITY, config.securityId)
@@ state and replaceLegalShareAdapter
+    mapping(bytes32 => uint64) private adapterUnitChangedAt;
+        adapterUnitChangedAt[config.securityId] = uint64(block.timestamp);
@@ isTradable
+        if (pool.securityId0 != 0 && adapterUnitChangedAt[pool.securityId0] != 0
+            && block.timestamp < uint256(adapterUnitChangedAt[pool.securityId0]) + 28 hours) return false;
+        if (pool.securityId1 != 0 && adapterUnitChangedAt[pool.securityId1] != 0
+            && block.timestamp < uint256(adapterUnitChangedAt[pool.securityId1]) + 28 hours) return false;
```

<!--/F-->

## Leads

<!--F key=tsvregistryv1|registertoken|mutable-adapter-implementation kind=LEAD agents=1-->

- **Upgradeable adapter can bypass the daily volume cap** — `TSVRegistryV1.registerToken` · MUTABLE-ADAPTER-IMPLEMENTATION — Code smells: registration records the adapter proxy's runtime code hash; Hook and Ledger check its reported version and `isCurrent()` but do not check implementation code. A proxy implementation could return zero from `toLegalShares` while preserving the interface. — An adapter proxy admin can change its conversion after registration while runtime hash and version checks still pass, so later swaps may bypass caps; the deployment configuration remains unverified.

<!--/F-->
