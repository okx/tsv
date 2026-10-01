# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20261001-185600 sha=f597879 agents=12/12-->

Pass 1 of 3 · 2026-10-01 · `f597879` · 12/12 agents returned.

## Findings

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix conf=95 kind=FINDING agents=10-->

[95] **1. Adapter replacement mixes share units in the daily cap**

`TSVRegistryV1.replaceLegalShareAdapter` · Confidence: 95

**Description**
An eligible trader exceeds the daily quota because the ledger adds charges from different adapter share units.

**Fix (Option A — convert accounting values)**

```diff
+ Convert `usedWad`, ADTV, and quota values to the new share unit before the registry accepts the adapter replacement.
```

**Fix (Option B — change at a day boundary)**

```diff
+ Require adapter replacement at a trade-day boundary, or convert the stored `usedWad` value into the new adapter's units before trading resumes.
```

<!--/F-->

<!--F key=tsvlpmanagerv1|settle|zero-delta-min-output-bypass conf=90 kind=FINDING agents=1-->

[90] **2. A zero output bypasses the LP minimum**

`TSVLPManagerV1._settle` · Confidence: 90

**Description**
An attacker can move the pool price outside an LP range, and the owner can receive zero tokens despite setting a positive minimum.

**Fix**

```diff
- if ((delta > 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+ if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
```

<!--/F-->

## Leads

<!--F key=tsvregistryv1|registertoken|mutable-adapter-implementation kind=LEAD agents=10-->

[Lead] **Adapter proxy logic may change after registration**

`TSVRegistryV1.registerToken`

**Code smells**
Registration checks an adapter address's runtime code hash, but runtime accounting trusts its conversion calls. The audit did not verify that a registered adapter can change its implementation.

<!--/F-->

<!--F key=tsvregistryv1|registertoken|mutable-token-implementation kind=LEAD agents=3-->

[Lead] **Token proxy behavior may change after approval**

`TSVRegistryV1.registerToken`

**Code smells**
The registry stores `poolImplementationHash` but does not read it. The audit did not verify whether a listed pool token uses an upgradeable proxy.

<!--/F-->

<!--F key=tsvregistryv1|relistsecurity|stale-market-status-on-relist kind=LEAD agents=1-->

[Lead] **Relisting can reuse an old open market status**

`TSVRegistryV1.relistSecurity`

**Code smells**
Relisting does not clear the previous market status, so pool enablement can rely on an old `OPEN` value. The audit did not verify whether relisting requires a fresh exchange report.

<!--/F-->
