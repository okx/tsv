# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261001-185600 sha=f597879 agents=12/12-->

Pass 3 of 3 · 2026-10-01 · `f597879` · 12/12 agents returned.

## Findings

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix conf=95 kind=FINDING agents=11-->

[95] **Adapter replacement can mix legal-share units within the daily cap**

`TSVRegistryV1.replaceLegalShareAdapter` and `TSVVolumeLedgerV1._recordLeg` · Confidence: 95

**Description**
An authorized adapter replacement can change the legal-share unit while a security's daily usage still contains the old unit. The Registry accepts a token-only pause and has no on-chain next-day gate; after authorized roles clear the pause, a trader can add new-unit charges to old-unit usage and exceed the intended cap. The admission runbook requires a security-wide pause through the next trade day and matching reports, but the contract does not enforce that waiting period.

**Fix**

```text
Bind adapter/unit changes to a security-level unit epoch and prevent trading until the next trade day and matching ADTV/quota are active, or convert all affected daily usage and limits before trading resumes.
```

<!--/F-->

<!--F key=tsvlpmanagerv1|settle|zero-delta-min-output-bypass conf=95 kind=FINDING agents=11-->

[95] **A zero output bypasses the LP minimum**

`TSVLPManagerV1._settle` · Confidence: 95

**Description**
When a close or decrease returns zero for one currency, `_settle` skips that currency's positive minimum output. A pool price at the position boundary can therefore let `closePosition` burn a position without delivering the amount its owner required.

**Fix**

```diff
- if ((delta > 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+ if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
```

<!--/F-->

## Leads

<!--F key=tsvregistryv1|registertoken|mutable-adapter-implementation kind=LEAD agents=11-->

- **Adapter proxy logic may change after registration** — `TSVRegistryV1.registerToken` — Registration checks the adapter proxy's runtime code hash, but later quota accounting trusts its live conversion logic. The audit did not verify whether an approved adapter is upgradeable.

<!--/F-->

<!--F key=tsvregistryv1|registertoken|mutable-token-implementation kind=LEAD agents=10-->

- **Token proxy behavior may change after approval** — `TSVRegistryV1.registerToken` — The registry checks the token's runtime code hash but does not enforce `poolImplementationHash`. The audit did not verify whether an approved token is upgradeable.

<!--/F-->

<!--F key=tsvregistryv1|relistsecurity|stale-market-status-on-relist kind=LEAD agents=10-->

- **Relisting can reuse an old open market status** — `TSVRegistryV1.relistSecurity` — Relisting preserves the old market status, so a pool may be enabled without a fresh market report. The audit did not verify whether the reporting process requires a new report.

<!--/F-->

<!--F key=tsvdatainboxv1|accept|sequence-saturation-lock kind=LEAD agents=12-->

- **A maximum report sequence can block later reports** — `TSVDataInboxV1._accept` — The function accepts any larger `uint64` sequence. If a reporter submits `type(uint64).max`, validation rejects every later report for that key and report type. The trigger requires a trusted reporter role, so this remains a lead.

<!--/F-->
