# 🔐 Security Review — tsv

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/v1/periphery/TSVSwapRouterV1.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 6 records before this scan · 13 after · `9f696db` |

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Settlement trusts approved token behavior** — `TSVSwapRouterV1._settle` · seen in 1/3 runs · NEW — Code smells: exact settlement checks rely on the token's `balanceOf` and transfer behavior, while an approved proxy can change implementation without changing its runtime code hash. This remains an admission and issuer trust assumption; no unprivileged Router path was confirmed.
- **Callback trusts the configured PoolManager** — `TSVSwapRouterV1.initialize/unlockCallback` · seen in 2/3 runs · NEW — Code smells: `initialize` checks only that the configured PoolManager has code, and `unlockCallback` trusts decoded callback data without binding it to the request that Router validated. A custom manager could replace that request during an active unlock; intended deployment verifies a trusted manager code hash.
- **Swap mode appears in both the selector and request** — `TSVSwapRouterV1.swapExactInput/swapExactOutput` · seen in 1/3 runs · NEW — Code smells: the chosen endpoint sets the mode, then Router requires the same value in `SwapRequest.exactInput`. The duplicate field adds calldata and a mismatch path.
- **Callback returns a delta only used by the outer event** — `TSVSwapRouterV1.unlockCallback/_swap` · seen in 1/3 runs · NEW — Code smells: callback returns `actualIn`, `actualOut`, and `BalanceDelta`; the outer function needs the amounts for its return value and the delta for its event. Moving the event into the callback could remove the delta from the callback result, but changes the event's position within `unlock`.
- **The minimum signed input delta cannot be settled** — `TSVSwapRouterV1.unlockCallback` · seen in 1/3 runs · NEW — Code smells: an exact-output input delta of `type(int128).min` can satisfy a `uint128` limit, but PoolManager cannot cast its positive magnitude to `int128` in `settle()`. The full transaction reverts, and no valid pool state producing this boundary was confirmed.
- **Router reads the trade day twice** — `TSVSwapRouterV1._validate/_swap` · seen in 1/3 runs · NEW — Code smells: `_validate` queries `currentTradeDay()` before `unlock`, then `_swap` queries it again for the event; current Ledger code returns `true` or reverts. The preflight read adds cost without an independent rejection path.
- **Router repeats the PoolKey equality check** — `TSVSwapRouterV1._validate` · seen in 1/3 runs · NEW — Code smells: `PoolId` hashes the complete key, Registry stores by that ID, and Hook checks the exact key before swap. The Router's second full-key hash comparison duplicates those invariants.

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed. `.solidity-auditor/memory.tsv`._

| Scans | Kind | Location | Title |
|---|---|---|---|
| 1 | LEAD | `tsvdatainboxv1.accept` | A maximum report sequence can block later reports |
| 1 | FINDING | `tsvlpmanagerv1.settle` | A zero output bypasses the LP minimum |
| 2 | LEAD | `tsvregistryv1.registertoken` | Adapter proxy logic may change after registration |
| 1 | LEAD | `tsvregistryv1.registertoken` | Token proxy behavior may change after approval |
| 1 | LEAD | `tsvregistryv1.relistsecurity` | Relisting can reuse an old open market status |
| 2 | FINDING | `tsvregistryv1.replacelegalshareadapter` | Adapter replacement can mix legal-share units within the daily cap |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
