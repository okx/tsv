# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261001-160945 sha=797e7b8 agents=12/12-->

Pass 3 of 3 · 2026-10-01 · `797e7b8` · 12/12 agents returned.

## Findings

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix conf=75 kind=FINDING agents=12-->

[75] **Daily quota mixes old and new share units**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 75

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

<!--/F-->

## Leads

<!--F key=tsvregistryv1|registertoken|mutable-adapter-implementation kind=LEAD agents=12-->

- **Upgradeable adapter can bypass the daily volume cap** — `TSVRegistryV1.registerToken` · MUTABLE-ADAPTER-IMPLEMENTATION · NEW — Code smells: Registration stores an adapter proxy's runtime code hash, but swaps check only its version and `isCurrent()`. A proxy admin can change `toLegalShares()` without changing the proxy hash; the deployment bundle does not show an approved adapter proxy.

<!--/F-->
