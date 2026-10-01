# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20261002-003005 sha=9f696db agents=12/12-->

Pass 1 of 3 · 2026-10-02 · `9f696db` plus modified worktree · 12/12 agents returned.

## Findings

_None — this pass raised no findings._

## Leads

<!--F key=tsvswaprouterv1|initialize-unlockcallback|external-poolmanager-trust kind=LEAD agents=1-->

- **Callback trusts the configured PoolManager** — `TSVSwapRouterV1.initialize/unlockCallback` — Code smells: `initialize` checks only that the configured PoolManager has code, and `unlockCallback` trusts decoded callback data without binding it to the request that Router validated. A custom manager could replace that request during an active unlock; intended deployment verifies a trusted manager code hash.

<!--/F-->

<!--F key=tsvswaprouterv1|_settle|mutable-token-implementation kind=LEAD agents=1-->

- **Settlement trusts approved token behavior** — `TSVSwapRouterV1._settle` — Code smells: exact settlement checks rely on the token's `balanceOf` and transfer behavior, while an approved proxy can change implementation without changing its runtime code hash. This remains an admission and issuer trust assumption; no unprivileged Router path was confirmed.

<!--/F-->
