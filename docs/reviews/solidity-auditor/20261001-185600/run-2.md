# Run 2 — solidity-auditor

<!--RUN pass=2 of=3 stamp=20261001-185600 sha=f597879 agents=12/12-->

Pass 2 of 3 · 2026-10-01 · `f597879` · 12/12 agents returned.

## Findings

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix conf=90 kind=FINDING agents=11-->

[90] **Adapter replacement mixes share units in the daily cap**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 90

**Description**
Traders can exceed the daily cap when an adapter changes units mid-day because the ledger combines charges from the old and new scales.

**Fix (Option A — trade-day boundary)**

```text
Require a security-wide pause until the next trade day and bind new ADTV reports to the replacement unit before swaps resume.
```

**Fix (Option B — convert accounting values)**

```text
Convert `usedWad`, ADTV, and quota values to the new share unit before the registry accepts the adapter replacement.
```

<!--/F-->

<!--F key=tsvlpmanagerv1|settle|zero-delta-min-output-bypass conf=90 kind=FINDING agents=10-->

[90] **A zero output bypasses the LP minimum**

`TSVLPManagerV1._settle` · Confidence: 90

**Description**
An attacker can move a pool outside an LP range, so the owner closes with zero of a token despite its positive minimum.

**Fix**

```diff
- if ((delta > 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+ if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
```

<!--/F-->


## Leads

<!--F key=tsvregistryv1|registertoken|mutable-adapter-implementation kind=LEAD agents=11-->

[Lead] **Adapter proxy logic may change after registration**

`TSVRegistryV1.registerToken`

**Code smells**
Registration checks the adapter proxy's runtime code hash, but later quota accounting trusts its live conversion logic. The audit did not verify whether any approved adapter is upgradeable.

<!--/F-->

<!--F key=tsvregistryv1|registertoken|mutable-token-implementation kind=LEAD agents=11-->

[Lead] **Token proxy behavior may change after approval**

`TSVRegistryV1.registerToken`

**Code smells**
The registry checks a token's runtime code hash but does not validate `poolImplementationHash`. The audit did not verify whether any approved token is upgradeable.

<!--/F-->

<!--F key=tsvregistryv1|relistsecurity|stale-market-status-on-relist kind=LEAD agents=8-->

[Lead] **Relisting can reuse an old open market status**

`TSVRegistryV1.relistSecurity`

**Code smells**
Relisting preserves the old market status, so a pool admin can enable trading without a fresh market report. The audit did not verify whether relisting requires a new report.

<!--/F-->

<!--F key=tsvdatainboxv1|accept|sequence-saturation-lock kind=LEAD agents=1-->

[Lead] **A maximum report sequence can block later reports**

`TSVDataInboxV1._accept`

**Code smells**
`_accept` accepts any larger `uint64` sequence. If a reporter submits `type(uint64).max`, validation rejects every later report for that security and report type.

<!--/F-->
