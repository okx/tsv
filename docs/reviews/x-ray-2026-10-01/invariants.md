# Invariant Map

> TSV V1 | 15 guards | 7 single-contract | 3 cross-contract | 1 economic

---

## 1. Enforced Guards (Reference)

#### G-1
`request.participant == address(0) || request.participant != msg.sender || request.participant != request.payer || request.participant != request.recipient || request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max) || request.limitAmount == 0` · `TSVSwapRouterV1.sol:168-173` · Binds payment and receipt to the authenticated participant and keeps the signed V4 amount representable.

#### G-2
`!registry.isEligible(request.participant)` · `TSVSwapRouterV1.sol:174` · Requires the configured credential system to admit a participant before a swap.

#### G-3
`!registry.isTradable(poolId)` and `keccak256(abi.encode(pool.key)) != keccak256(abi.encode(request.key))` · `TSVSwapRouterV1.sol:175-178` · Restricts execution to the exact registered pool while its security and pause state permit trading.

#### G-4
`nonceUnavailable[request.participant][request.nonce]` · `TSVSwapRouterV1.sol:181-182` · Prevents reuse of a participant's successful swap nonce.

#### G-5
`msg.sender != address(poolManager) || active.operationId == 0 || keccak256(data) != active.requestHash` · `TSVSwapRouterV1.sol:113-116` · Binds the callback to the in-flight PoolManager unlock and exact request bytes.

#### G-6
`actualIn > request.amountSpecified || actualOut < request.limitAmount`; for exact-output: `actualOut != request.amountSpecified || actualIn > request.limitAmount` · `TSVSwapRouterV1.sol:129-132` · Enforces user-specified execution bounds against actual PoolManager deltas.

#### G-7
`payerAfter > payerBefore || payerBefore - payerAfter != amount || poolAfter < poolBefore || poolAfter - poolBefore != amount || poolManager.settle() != amount` · `TSVDirectSettlementLib.sol:24-27` · Requires exact payer debit, PoolManager credit, and settlement amount for incoming currencies.

#### G-8
`poolAfter > poolBefore || poolBefore - poolAfter != amount || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount` · `TSVDirectSettlementLib.sol:38-41` · Requires the PoolManager debit and recipient credit to match for outgoing currencies.

#### G-9
`activeId != poolId || participant == address(0) || swapStates[operationId].poolId != 0 || !registry.isTradable(poolId)` · `TSVHookV1.sol:172-176` · Requires a fresh hook state for a registered active router operation.

#### G-10
`state.poolId == 0 || state.poolId != PoolId.unwrap(key.toId()) || state.accounted` · `TSVHookV1.sol:194-200` · Allows a matching in-flight swap to be volume-accounted only once.

#### G-11
`!state.accounted || state.poolId == 0` · `TSVHookV1.sol:203-210` · Requires completed accounting before clearing a swap snapshot.

#### G-12
`!registry.isEligible(msg.sender) || !registry.isTradable(poolId)` · `TSVLPManagerV1.sol:297-300` · Applies participant and market eligibility to ordinary position changes.

#### G-13
`!p.active || p.liquidity == 0 || p.owner != msg.sender || ownerOf(positionId) != p.owner` · `TSVLPManagerV1.sol:302-307` · Restricts ordinary position operations to the live receipt owner.

#### G-14
`!hasRole(FORCE_EXIT_ADMIN_ROLE, msg.sender) && (!hasRole(REVOKE_EXIT_EXECUTOR_ROLE, msg.sender) || registry.hasCredential(p.owner))` · `TSVLPManagerV1.sol:170-175` · Limits forced removal to the exit administrators and the specified credential-revocation case.

#### G-15
`next > _effectiveCap(securityId, day, hardCap)` · `TSVVolumeLedgerV1.sol:302-308` · Prevents a new volume charge from exceeding the currently computed daily cap.

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Category` · On-chain: **Yes**

> A participant/nonce pair is consumed at most once by a committed swap.

**Derivation** — State-machine edge: `false@TSVSwapRouterV1.sol:181 → true@TSVSwapRouterV1.sol:182`; the sole write is after the unused check and there is no reset path.

**If violated** — The same participant nonce could authorize multiple router swaps.

#### I-2

`Category` · On-chain: **Yes**

> Router swap context is installed for the unlock call and deleted after successful completion.

**Derivation** — State-machine edge: empty `active` → populated at `TSVSwapRouterV1.sol:145-154` → deleted at `:163`; a revert rolls back the transaction.

**If violated** — A later callback could observe stale request context.

#### I-3

`Category` · On-chain: **Yes**

> Each hook swap state moves from empty to accounted once, then is cleared after the rate-current checks.

**Derivation** — State-machine edges at `TSVHookV1.sol:178-181`, `:198-200`, and `:203-210`; `accounted` blocks a second ledger call.

**If violated** — A swap could be counted more than once or a later operation could encounter stale snapshot data.

#### I-4

`Category` · On-chain: **Yes**

> A position ID transitions from active to closed and has no reopen path.

**Derivation** — State-machine edge: `active=true@TSVLPManagerV1.sol:109-118 → active=false@TSVLPManagerV1.sol:317-322`; close also burns the receipt.

**If violated** — A closed position identifier could be reused against stale ownership or liquidity state.

#### I-5

`Category` · On-chain: **Yes**

> Registry pools progress from absent to pending to active, then may move between active and disabled.

**Derivation** — State-machine edges: `TSVRegistryV1.sol:291-306`, `:309-319`, `:322-331`, and `:334-351`; no delete-to-absent path appears in scope.

**If violated** — Pool admission and active-pool counters could diverge from the stored pool lifecycle.

#### I-6

`Category` · On-chain: **Yes**

> Accepted report IDs are one-shot, and each report cursor advances to a strictly higher sequence with nondecreasing source time.

**Derivation** — State-machine/guard: `TSVDataInboxV1.sol:114-127`; `ReportValidationLib.sol:14-19` checks `reportIdUsed`, `sequence > previousSequence`, and `sourceTimestamp >= previousSourceTimestamp` before the sole writes.

**If violated** — A report could be replayed or an older sequence replace current operational state.

#### I-7

`Category` · On-chain: **Yes**

> Trade-day checkpoints remain strictly increasing by effective day, and a change cannot be scheduled after the transition day has started.

**Derivation** — Guard-lift plus write-site enumeration: `TSVVolumeLedgerV1.sol:180-192` is the only checkpoint append; `:198-206` removes only the pending checkpoint before its transition boundary.

**If violated** — Current and historical usage could be assigned to inconsistent UTC trade-day boundaries.

#### I-8

`Category` · On-chain: **Yes at each usage write**

> A `usedWad` increment is written only when the resulting value is at or below that call's effective cap; later report or tier changes can make historical usage exceed the new cap.

**Derivation** — Guard-lift plus write-site enumeration: `TSVVolumeLedgerV1.sol:305-308` is the only `usedWad` write; it checks the next value against `_effectiveCap` immediately before assignment.

**If violated** — A single accepted swap could consume more than the cap applied to that trade.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes**

> Hook swap callbacks rely on a router context installed for the same operation ID and pool.

**Caller side** — `TSVHookV1.sol:169-176` — Hook reads `TSVSwapRouterV1.activeSwapOperation()` and compares pool ID and participant before creating its snapshot.

**Callee side** — `TSVSwapRouterV1.sol:141-155` — Router writes operation ID, request hash, pool ID, and participant before calling `PoolManager.unlock()`; it deletes that context after the unlock returns at `:163`.

**If violated** — Callback data could be detached from the request and pool whose deltas are being processed.

#### X-2

On-chain: **Yes**

> Hook liquidity callbacks rely on the LP Manager's active context matching the PoolManager parameters.

**Caller side** — `TSVHookV1.sol:231-250` — Hook reads `activeLPContext()` and compares pool ID, salt, ticks, and liquidity delta.

**Callee side** — `TSVLPManagerV1.sol:259-275` — LP Manager writes active context and request hash before `PoolManager.unlock()` and deletes them after return.

**If violated** — Hook authorization could apply to a different position operation than the manager initiated.

#### X-3

On-chain: **No, across cap changes**

> Ledger consumption uses Registry tier and security state, while Registry policy setters do not compare a lower resulting cap with prior `usedWad`.

**Caller side** — `TSVVolumeLedgerV1.sol:302-321` — `_consume()` checks each new charge against `_hardCap()` and the effective quota; `_hardCap()` reads security tier and tier basis points from Registry.

**Callee side** — `TSVRegistryV1.sol:117-124,183-194` — `setTierPolicy()` and `setSecurityTier()` write cap inputs without reading Ledger usage.

**If violated** — Historical usage can remain above a newly lowered cap; subsequent swap charges are checked against that lower value.

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes at each consumed swap**

> For a security and trade day, new legal-share volume is admitted only while resulting usage is at most `min(previous-month ADTV × tier basis points / 10,000, active quota)`.

**Follows from** — `I-8` + `X-3`

**If violated** — A successful swap could exceed its then-current per-security daily volume limit.
