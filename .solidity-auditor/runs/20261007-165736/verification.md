# Verification and fix status

Audited snapshot: MR !7 commit `fd3bcfc061b6d31a9b483e5b71c2b5cec9f92cce`.

Both findings are Medium availability issues with confidence 90. No fund-loss path was confirmed. Original source digest: `9d7003ffd9db96876a1369ad19d5ba26998fae7b6db7625d8eb9d9f20b891394`.

## Validation gates

- Execution: ALLOWS. Normal U transfers increase PM or Router U; the absolute-zero checks then reject before unlock or admission completion.
- Reachability: ALLOWS. Normal ERC20 holder transfers need no TSV role or SBT. The concrete Backed token hook enforces pause and sanctions, with no recipient allowlist.
- Trigger: ALLOWS. A holder needs one raw U unit plus gas; the victim trader or onboarding operator is a different account.
- Impact: ALLOWS. All four swap modes and all wrappers with the same U are blocked; PM donations also block first or additional W admission. No ordinary Router sweep exists. PM balances may also belong to unrelated pools.

## Repair

The operation captures existing PM and Router U in memory before unlock and requires equal balances after unlock. Stock pay/take also compare their local baselines. Exact payer/recipient movements, W collateral/supply/PM W changes, E conservation, policy snapshots and zero transient deltas remain enforced. Initial admission ignores aggregate PM U and retains the new W inventory and verification requirements.

Two independent read-only follow-up reviews (math and flow-gap) accepted this repair. Direct solc 0.8.26 standard-JSON storage-layout/ABI compilation confirms identical Registry (25 entries), Router (18 entries), and library (0 entries) storage layouts, and identical Registry/Router ABI entries. ABI ordering is not significant. A sweep alone does not prevent renewed donations and does not safely address shared PM balances.

## Tests

New regression tests fail on the original implementation: stock trading raises SettlementMismatch; first security and additional W admission raise InvalidPermissionedConfig. After the patch, the first targeted Wrapped run passes 29 tests (0 failures or skips). The final full run passes all 279 tests across 46 suites (0 failures or skips), including 30 Wrapped swap tests. Ordinary fuzz uses 256 runs and existing stateful invariants use 64 runs × 32 steps. Logs: `cache/registry-swap-prefunded-before.log`, `cache/registry-swap-review-full.log`. Registry runtime remains 23,851 bytes; Router is 23,816 bytes and the validation library is 15,410 bytes; all are below EIP-170.

Tests use real PoolManager and original Factory/W, with behavior fixtures for U/Q/SBT. Production Wrapped LP and issuer/target-chain acceptance remain outside this scan.


## Submitted repair

Fix commit: `3c2d42c47a6756a732039631edaf3b4215abeb95`. New MR: https://gitlab.okg.com/web3-dex/tsv/-/merge_requests/8. Target: `feat/tsv-permissioned-registry-wrapped-swap`. The original MR !7 branch remains at the audited commit. The original workspace index is unchanged.
