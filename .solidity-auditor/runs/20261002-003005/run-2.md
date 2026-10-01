# Run 2 — solidity-auditor

<!--RUN pass=2 of=3 stamp=20261002-003005 sha=9f696db agents=12/12-->

Pass 2 of 3 · 2026-10-02 · `9f696db` plus modified worktree · 12/12 agents returned.

## Findings

_None — this pass raised no findings._

## Leads

<!--F key=tsvswaprouterv1|initialize-unlockcallback|external-poolmanager-trust kind=LEAD agents=1-->

- **Callback trusts the configured PoolManager** — `TSVSwapRouterV1.initialize/unlockCallback` — Code smells: `initialize` checks only that the configured PoolManager has code, and `unlockCallback` trusts decoded callback data without binding it to the request that Router validated. A custom manager could replace that request during an active unlock; intended deployment verifies a trusted manager code hash.

<!--/F-->

<!--F key=tsvswaprouterv1|validate-swap|redundant-trade-day-read kind=LEAD agents=2-->

- **Router reads the trade day twice** — `TSVSwapRouterV1._validate/_swap` — Code smells: `_validate` queries `currentTradeDay()` before `unlock`, then `_swap` queries it again for the event; current Ledger code returns `true` or reverts. The preflight read adds cost without an independent rejection path.

<!--/F-->

<!--F key=tsvswaprouterv1|validate|redundant-pool-key-check kind=LEAD agents=1-->

- **Router repeats the PoolKey equality check** — `TSVSwapRouterV1._validate` — Code smells: `PoolId` hashes the complete key, Registry stores by that ID, and Hook checks the exact key before swap. The Router's second full-key hash comparison duplicates those invariants.

<!--/F-->

<!--F key=tsvswaprouterv1|swapexactinput-swapexactoutput|duplicated-swap-mode kind=LEAD agents=1-->

- **Swap mode appears in both the selector and request** — `TSVSwapRouterV1.swapExactInput/swapExactOutput` — Code smells: the chosen endpoint sets the mode, then Router requires the same value in `SwapRequest.exactInput`. The duplicate field adds calldata and a mismatch path.

<!--/F-->

<!--F key=tsvswaprouterv1|unlockcallback|signed-delta-settlement-boundary kind=LEAD agents=1-->

- **The minimum signed input delta cannot be settled** — `TSVSwapRouterV1.unlockCallback` — Code smells: an exact-output input delta of `type(int128).min` can satisfy a `uint128` limit, but PoolManager cannot cast its positive magnitude to `int128` in `settle()`. The full transaction reverts, and no valid pool state producing this boundary was confirmed.

<!--/F-->
