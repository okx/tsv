# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261002-003005 sha=9f696db agents=12/12-->

Pass 3 of 3 · 2026-10-02 · `9f696db` plus modified worktree · 12/12 agents returned.

## Findings

_None — this pass raised no findings._

## Leads

<!--F key=tsvswaprouterv1|unlockcallback-swap|redundant-callback-return-data kind=LEAD agents=1-->

- **Callback returns a delta only used by the outer event** — `TSVSwapRouterV1.unlockCallback/_swap` — Code smells: callback returns `actualIn`, `actualOut`, and `BalanceDelta`; the outer function needs the amounts for its return value and the delta for its event. Moving the event into the callback could remove the delta from the callback result, but changes the event's position within `unlock`.

<!--/F-->
