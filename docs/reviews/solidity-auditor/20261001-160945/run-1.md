# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20261001-160945 sha=797e7b8 agents=12/12-->

Pass 1 of 3 · 2026-10-01 · `797e7b8` · 12/12 agents returned.

## Findings

## Leads

<!--F key=tsvregistryv1|replacelegalshareadapter|intra-day-unit-mix kind=LEAD agents=1-->

- **Same-day adapter replacement can mix quota units** — `TSVRegistryV1.replaceLegalShareAdapter` · INTRA-DAY-UNIT-MIX — Code smells: replacement requires only a token or global pause; the ledger retains `usedWad[securityId][day]`; and another token for the same security may remain tradable. — A trader can swap under a new adapter while the daily ledger still includes usage measured in the old share unit; quota impact remains unverified.

<!--/F-->
