# X-Ray Report

> TSV V1 | 3,000 nSLOC | 797e7b8 (`main`) | Foundry / Solidity 0.8.26 | 01/10/26

Source analysis reads the current working tree, including uncommitted changes; git-history signals are scoped to HEAD `797e7b8`.

---

## 1. Protocol Overview

**What it does:** TSV V1 operates a credential-gated Uniswap V4 venue for tokenized securities with per-security daily volume limits.

- **Users**: Participants with the configured SBT credential and liquidity providers who own non-transferable LP position receipts.
- **Core flow**: The router validates a one-pool swap, V4 invokes the Hook, the Ledger records actual deltas, and the participant settles both currencies directly.
- **Key mechanism**: Concentrated-liquidity V4 pools with a hook-enforced market state, credential check, and daily legal-share volume cap.
- **Token model**: Each pool has at most one security currency; adapters translate raw token amounts to legal-share units; currencies settle directly through PoolManager.
- **Admin model**: Governor-controlled business roles and parameters; ordinary upgrade calls go through a timelock; a separate controller supports allowlisted emergency upgrades and a Guardian freeze route.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Registry, hook, reports, and volume | `TSVRegistryV1`, `TSVHookV1`, `TSVDataInboxV1`, `TSVVolumeLedgerV1` | 1,073 | Admit assets and pools, enforce operational state, and account swap volume |
| Swap and liquidity entry | `TSVSwapRouterV1`, `TSVLPManagerV1` | 470 | Validate participant requests and settle V4 deltas |
| Governance and upgrades | `TSVBusinessAuthority`, `TSVEmergencyUpgradeController`, `TSVGovernanceAnchor`, `TSVGoverned`, `TSVUpgradeTimelock` | 710 | Administer roles, schedule upgrades, and coordinate emergency recovery |
| Legal-share and legacy adapters | Three legal-share adapters; `IssuerShareSettlementAdapter` | 340 | Snapshot conversion rates and support issuer-share settlement |
| Libraries | `LegalShareMath`, `ReportValidationLib`, `TSVDirectSettlementLib`, `TradeDayLib` | 193 | Math, report validation, settlement, and date calculations |
| Deployment | `TSVERC1967Proxy`, `TSVHookProxyFactoryV1` | 34 | Deploy proxies with V4 hook permission bits |
| Data types | `TSVTypes`, `TSVReports` | 148 | Pool, token, request, snapshot, and report structures |

The 3,000 nSLOC enumeration includes two interface files (32 nSLOC); they are excluded from the subsystem table.

### How It Fits Together

The core trick: V4 callbacks are accepted only while TSV's router or LP manager has installed matching operation context, so the Hook can tie pool deltas to a validated participant action.

### Swap settlement and volume

```text
Participant
└─ TSVSwapRouterV1.swapExactInput() / swapExactOutput()
   ├─ TSVRegistryV1.isEligible() + isTradable()   *credential, market, pool and pause gates*
   ├─ PoolManager.unlock()
   │  ├─ TSVHookV1.beforeSwap() → adapter.snapshot()
   │  ├─ PoolManager.swap()
   │  └─ TSVHookV1.afterSwap() → TSVVolumeLedgerV1.recordSwap()
   ├─ TSVDirectSettlementLib.settleFrom() / takeTo()   *exact payer, pool and recipient deltas*
   └─ TSVHookV1.assertCurrentAndClear()   *verify snapshots, clear operation state*
```

### LP position lifecycle

```text
Eligible owner
└─ TSVLPManagerV1.openPosition() / increaseLiquidity() / decreaseLiquidity()
   ├─ TSVRegistryV1.isEligible() + isTradable()
   ├─ PoolManager.unlock() → TSVHookV1 validates active LP context
   ├─ PoolManager.modifyLiquidity()
   ├─ TSVDirectSettlementLib settles exact currency deltas
   └─ TSVLPManagerV1 updates position state and non-transferable receipt
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX / AMM** with **governance** and **permissioned tokenized-asset** characteristics.

V4 swap and concentrated-liquidity operations dominate the code paths; role administration, timelocked execution, and root recovery add a governance trust boundary.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Eligible participant | Bounded (SBT credential and caller-bound requests) | Submit swaps and manage owned positions while pool and market gates pass |
| Governor | Trusted | Sets business configuration and roles directly; ordinary proxy upgrades use the timelock path |
| Guardian | Trusted | Cancels timelock operations, approves protected recovery, and freezes emergency upgrades |
| RecoveryCouncil | Trusted | Proposes protected identity recovery and governance-root migration |
| Executor | Trusted (configured address/role) | Executes ready timelock operations |
| `SYMBOL_ADMIN_ROLE` | Bounded | Lists securities, configures tokens/adapters, and enables or disables pools |
| `VOLUME_ORACLE_ROLE` / `HALT_REPORTER_ROLE` | Bounded | Submits quota/ADTV or market reports through DataInbox |
| `POOL_CREATOR_ROLE` | Bounded | Initializes registered pools through the LP manager |
| Emergency pause/resume roles | Bounded | Adds or clears scoped pauses |
| Force-exit roles | Bounded | Closes a stored position and directs output to its recorded owner |
| V4 PoolManager | External protocol dependency | Executes pool operations and invokes configured Hook callbacks |
| SBT and issuer token administrators | External trust assumption | Control credential state and issuer-token behavior outside TSV governance |

**Adversary Ranking** (ordered by protocol relevance):

1. **MEV searcher** — Can observe participant swaps and compete around V4 price movement.
2. **Compromised business-role holder or governor** — Can alter asset, market, cap, role, or pause configuration; only proxy upgrade paths have a separate timelock/controller boundary.
3. **Issuer-token or credential administrator** — Can change external token or SBT behavior without changing TSV's own governance state.
4. **Malicious or compromised report operator** — Can submit market, ADTV, or quota inputs while holding the corresponding role.

See [entry-points.md](entry-points.md) for the full permissionless and role-gated entry point map.

### Trust Boundaries

- **Business governance** — `TSVGoverned.onlyGovernor` and business roles operate directly; the timelock protects ordinary upgrade calls, while the emergency controller supports immediate upgrades for bound targets and can be frozen by the Guardian (`TSVGoverned.sol:53-58,92-94`; `TSVEmergencyUpgradeController.sol:58-110`).
- **Timelock delay** — `TSVUpgradeTimelock` is constructed with minimum delay `0`; each scheduled call supplies its own `delay`, so the source does not enforce a positive minimum (`TSVUpgradeTimelock.sol:34-52,122-154`).
- **Operational reports** — Report entry points require reporter roles and monotonic metadata, but source hashes are checked for nonzero presence rather than cryptographically verified content (`TSVDataInboxV1.sol:34-46,103-128`; `ReportValidationLib.sol:14-19`).
- **Participant credentials** — Registry calls the configured SBT's `paused()` and `verify()` methods; ordinary swaps and LP actions depend on that external state (`TSVRegistryV1.sol:131-157`).
- **Issuer currencies and adapters** — Token admission stores a runtime code hash and evidence; rate adapters expose versioned snapshots. Proxy implementation controls and legal meaning remain external assumptions (per spec: `docs/CODING_SPEC_V1.md:95-99`; `docs/SYSTEMS_OVERVIEW.md:715`).
- **Pool settlement** — Router/LP manager trust the configured V4 PoolManager for callback execution; `TSVDirectSettlementLib` checks exact ERC-20 balance changes around transfers (`TSVSwapRouterV1.sol:113-139`; `TSVDirectSettlementLib.sol:18-41`).

### Key Attack Surfaces

- **Swap request, callback, and currency settlement** &nbsp;&#91;[G-1](invariants.md#g-1), [G-5](invariants.md#g-5), [G-7](invariants.md#g-7), [G-8](invariants.md#g-8), [I-2](invariants.md#i-2), [X-1](invariants.md#x-1)&#93; — `TSVSwapRouterV1._validateAndConsume/unlockCallback` and `TSVDirectSettlementLib` bind caller, request bytes, V4 deltas, and payer/recipient balance changes; trace both exact-input and exact-output paths.

- **V4 swap snapshot and accounting lifecycle** &nbsp;&#91;[G-9](invariants.md#g-9), [G-10](invariants.md#g-10), [G-11](invariants.md#g-11), [I-3](invariants.md#i-3)&#93; — `TSVHookV1.beforeSwap/afterSwap/assertCurrentAndClear` stores rate snapshots across the PoolManager callback and calls the Ledger once.

- **Daily volume inputs and cap updates** &nbsp;&#91;[G-15](invariants.md#g-15), [I-8](invariants.md#i-8), [X-3](invariants.md#x-3), [E-1](invariants.md#e-1)&#93; — `TSVVolumeLedgerV1._hardCap/_consume` combines ADTV, Registry tier policy, and quota state; trace report corrections and tier changes against prior daily usage.

- **Issuer token behavior and implementation pinning** — `TokenConfig.poolImplementationHash` is declared but no bundled function reads it; Registry checks `poolRuntimeCodeHash` on token approval while an external proxy can retain the same runtime code across implementation changes (`TSVTypes.sol:49-61`; `TSVRegistryV1.sol:210-237,240-261`).

- **Participant eligibility and LP exit paths** &nbsp;&#91;[G-12](invariants.md#g-12), [G-13](invariants.md#g-13), [G-14](invariants.md#g-14), [I-4](invariants.md#i-4)&#93; — Ordinary LP changes re-check SBT eligibility and tradability; `forceExit` uses separate role checks and still settles to the stored owner (`TSVLPManagerV1.sol:139-186,297-322`).

- **Report admission and market-state transitions** &nbsp;&#91;[G-3](invariants.md#g-3), [I-5](invariants.md#i-5), [I-6](invariants.md#i-6)&#93; — DataInbox checks role, source-time, sequence, deadline, and unique ID before Registry/Ledger writes; trace report semantics and the identity of each reporter role.

- **Governance and upgrade authority** — Business configuration is immediately callable by Governor or operational roles; implementation upgrades pass through a zero-minimum-delay timelock or the allowlisted emergency controller (`TSVGoverned.sol:53-94`; `TSVUpgradeTimelock.sol:34-52`; `TSVEmergencyUpgradeController.sol:58-110`).

- **Pool creation and initial price** — `POOL_CREATOR_ROLE` supplies the initialization price and evidence during the PENDING → ACTIVE path (`TSVLPManagerV1.sol:88-97`; `TSVRegistryV1.sol:291-351`).

### Upgrade Architecture Concerns

- **Upgradeable governed proxies** — Implementations disable initialization in their constructors; proxy initializers bind the governance root, and `_authorizeUpgrade` accepts the anchor's timelock or emergency controller (`TSVGoverned.sol:25-39,92-94`).
- **Emergency upgrade scope** — The controller checks bound-proxy membership, allowlisting, implementation code, unique action ID, and incident evidence; the Guardian freeze path is separate (`TSVEmergencyUpgradeController.sol:58-110`).
- **Delay configuration** — The timelock's constructor minimum is zero, and the schedule caller provides the delay; there is no source-level mandatory waiting period (`TSVUpgradeTimelock.sol:34-52,122-154`).

### Protocol-Type Concerns

**As a DEX / AMM:**
- `TSVSwapRouterV1.unlockCallback:123-138` derives actual input/output from PoolManager deltas and enforces per-request bounds.
- `TSVDirectSettlementLib.sol:18-41` checks both sides' exact token balance movement; token behavior that violates these assumptions reverts settlement.

**As a governance-controlled venue:**
- `TSVDataInboxV1._accept:103-128` uses roles, unique report IDs, sequence, source timestamp, and deadline rather than reporter signatures.
- `TSVRegistryV1.replaceLegalShareAdapter:264-284` versions replacement adapters and gates replacement on no active pools or a relevant pause.

### Temporal Risk Profile

**Deployment & Initialization:**
- Hook deployment must produce the required low address bits, and the Hook initializer binds PoolManager, Registry, Ledger, Router, and LP manager (`TSVHookProxyFactoryV1.sol:14-26`; `TSVHookV1.sol:59-80`).
- Six proxy initializers are one-shot; the governance anchor binds the six business proxies once (`TSVGovernanceAnchor.sol:96-128`).

**Market Stress:**
- Market status and scoped emergency pauses feed `Registry.isTradable`; halted or paused pools fail swap and ordinary LP entry checks (`TSVRegistryV1.sol:383-429`).
- Adapter snapshots that become stale during a swap cause the callback path to revert before context is cleared (`TSVHookV1.sol:203-210,264-275`).

**Governance & Upgrade Windows:**
- Ordinary schedule delay is selected by the proposer and the timelock enforces a minimum of zero; emergency upgrade execution is immediate when target and freeze checks pass (`TSVUpgradeTimelock.sol:34-52,122-154`; `TSVEmergencyUpgradeController.sol:66-90`).

### Composability & Dependency Risks

- **V4 PoolManager** — Router and LP manager trust unlock/callback sequencing; configured callbacks check the PoolManager address and operation context (`TSVSwapRouterV1.sol:113-116`; `TSVLPManagerV1.sol:228-240`; `TSVHookV1.sol:82-85`).
- **SBT** — Registry depends on external `paused()` and `verify()` behavior; a pause affects all credential-gated operations (`TSVRegistryV1.sol:131-157`).
- **Issuer tokens** — Exact balance-delta checks reject fee-on-transfer behavior during direct settlement; blacklist, pause, or implementation changes remain issuer-level behavior (`TSVDirectSettlementLib.sol:18-41`; per spec: `docs/SYSTEMS_OVERVIEW.md:715`).
- **Legal-share adapters** — Hook snapshots adapter versions before swaps and Ledger checks currentness again when accounting; multiplier semantics originate from issuer token calls (`TSVHookV1.sol:264-275`; adapter implementations under `src/v1/adapters/`).

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> - **15 Enforced Guards** (`G-1` … `G-15`)
> - **8 Single-Contract Invariants** (`I-1` … `I-8`)
> - **3 Cross-Contract Invariants** (`X-1` … `X-3`)
> - **1 Economic Invariant** (`E-1`)
>
> The map distinguishes state transitions that are enforced from cap state that can change after prior volume has accumulated.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|-------|-------|
| README | Present | `README.md` |
| NatSpec | 22 tags across 19 source files | Includes notices, parameter/return docs, and design notes |
| Spec/Whitepaper | Present | Coding, test, architecture, systems overview, and feasibility documents |
| Inline Comments | Adequate | Comments explain hook permissions, snapshot semantics, and trade-day transitions; coverage varies by module |

Spec-derived properties are tagged `(per spec)`; source code takes precedence where it differs (`docs/README.md:3`).

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 7 | File scan |
| Test functions | 62 | File scan |
| Line coverage | 76.90% | `forge coverage` |
| Statement coverage | 74.66% | `forge coverage` |
| Branch coverage | 29.11% | `forge coverage` |
| Function coverage | 84.79% | `forge coverage` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 40 functions / 5 files | adapters, foundation, governance, hook factory, legacy adapter |
| Integration | 22 functions / 1 file | local TSV protocol flow |
| Stateless Fuzz | 1 | ERC8056 legal-share bounds |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna / Medusa) | 0 | no in-scope functions/configuration detected |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none detected |

### Gaps

- No Foundry stateful invariant tests, Echidna/Medusa campaign, or formal verification suite was detected.
- Coverage is strongest for statements and functions; branch coverage is 29.11%.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — six commits are visible on `main`, with four source-touching commits; all are dated 01/10/26. Git signals analyze HEAD `797e7b8`, not uncommitted source changes.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| zewei.lu | 6 | +4,057 / -423 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-developer history |
| Merge commits | 0 of 6 (0%) | No merge-commit review signal visible |
| Repo age | 01/10/26 → 01/10/26 | One-day history window |
| Recent source activity (30d) | 4 commits | All source history is recent |
| Test co-change rate | 100% | Each source-changing commit also changed test files; this measures file co-modification, not coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/v1/core/TSVDataInboxV1.sol` | 4 | Most frequently changed source file |
| `src/v1/core/TSVRegistryV1.sol` | 2 | Asset, pool, and market state |
| `src/v1/core/TSVVolumeLedgerV1.sol` | 2 | Report and cap accounting |
| `src/v1/core/TSVHookV1.sol` | 2 | V4 callback path |
| `src/v1/periphery/TSVLPManagerV1.sol` | 2 | Position lifecycle and settlement |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `797e7b8` | 01/10/26 | chore: sync TSV project updates | 10 | Large multi-domain source change with accounting and access-control edits |
| `868906e` | 01/10/26 | feat: remove report signature mechanism | 9 | Changed report authentication and accounting paths |
| `11171f1` | 01/10/26 | chore: establish TSV V1 repository baseline | 8 | Large source baseline with runtime guards and role controls |
| `2e5beb8` | 01/10/26 | feat: add batched monthly ADTV submissions | 5 | Added batched report entry path |

### Dangerous Area Evolution

| Security Area | Commits | Key TSV Files |
|--------------|--------:|---------------|
| access control | 4 | `TSVDataInboxV1.sol`, `TSVRegistryV1.sol`, `TSVGoverned.sol` |
| fund flows | 2 | `TSVLPManagerV1.sol`, `TSVSwapRouterV1.sol` |
| signatures / report authentication | 2 | `TSVDataInboxV1.sol`, `TSVReports.sol` |
| state machines | 2 | `TSVGovernanceAnchor.sol`, `TSVRegistryV1.sol` |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| TestToken | `lib/TestToken` | Unknown | Internalized | Not a submodule; upstream could not be identified by the scanner |
| v4-core | `lib/v4-core` | Unknown | Internalized | Not a submodule; contains multiple Solidity pragma versions |
| soul-bound-token-1155 | `lib/soul-bound-token-1155` | Unknown | Submodule | Scanner did not identify upstream metadata |

### Security Observations

- **Single-author history** — `zewei.lu` accounts for all scanned source additions (4,057 lines).
- **No merge commits** — no merge-based review signal appears in the six commits.
- **Short history window** — all six commits and four source commits fall on the same date.
- **Recent broad change** — HEAD touches 1,078 source lines across five security domains and changes tests.
- **Report path activity** — DataInbox is the highest-churn source file with four modifications.
- **Dependency provenance** — two large libraries are internalized rather than submodules; scanner could not identify their upstreams.

### Cross-Reference Synthesis

- **DataInbox history and report surfaces** — four source modifications plus a score-9 report-authentication commit align with the role-gated report path in Section 2.
- **Recent access-control changes and governance boundary** — access control appears in four source-touching commits while business configuration remains directly callable by authorized roles.
- **Adapter/token seams and external assumptions** — recent changes span token transfer, accounting, and authentication domains; current source relies on adapter snapshots and exact settlement checks.

---

## X-Ray Verdict

**ADEQUATE** — Unit and integration tests plus one stateless fuzz test exist; protocol specs, role boundaries, a timelock, and an emergency pause/upgrade path are present.

**Structural facts:**
1. 3,000 nSLOC across 25 Solidity source files and eight source subsystems.
2. Six governed upgradeable proxies share a fixed governance anchor.
3. Seven test files contain 62 test functions; one is stateless fuzz and no stateful invariant suite was detected.
4. `forge coverage` reports 76.90% line and 29.11% branch coverage.
5. Six commits by one contributor are visible in the one-day HEAD history window.
