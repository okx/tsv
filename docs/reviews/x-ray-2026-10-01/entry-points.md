# Entry Point Map

> TSV V1 | 84 state-changing declarations (including 6 initializers) | 2 permissionless | 51 role-gated | 25 admin-only

---

## Protocol Flow Paths

### Deployment and setup

`TSVHookProxyFactoryV1.deploy()` → proxy constructor with initialization data → six governed proxy `initialize()` functions → governance root and proxy binding → registry component binding → ledger writer binding → role grants and asset/SBT configuration.

### Pool creation

`SYMBOL_ADMIN_ROLE.registerToken()` → `SYMBOL_ADMIN_ROLE.listSecurity()` → `POOL_CREATOR_ROLE.initializePool()` → `TSVRegistryV1.registerPendingPool()` → `PoolManager.initialize()` → `TSVRegistryV1.markPoolActive()`.

### Participant swap

`SBT credential + approved token + listed security + open market + no matching pause + current ADTV` → `TSVSwapRouterV1.swapExactInput/Output()` → registry and ledger prechecks → `PoolManager.unlock()` → `TSVHookV1.beforeSwap()` snapshots adapters → `PoolManager.swap()` → `TSVHookV1.afterSwap()` records actual deltas → router settles both currencies and calls `assertCurrentAndClear()`.

### Liquidity position

`SBT credential + active tradable pool` → `TSVLPManagerV1.openPosition()` → PoolManager liquidity change → direct currency settlement → non-transferable position receipt. The recorded owner may increase, decrease, collect fees, or close while eligible and before the supplied deadline.

### Reports and daily limits

`HALT_REPORTER_ROLE.submitMarketStatus()` → DataInbox validation → Registry market-state transition.

`VOLUME_ORACLE_ROLE.submitAdtv()/submitAdtvBatch()` → DataInbox validation → Ledger ADTV write; `submitQuota()` follows the same path to the daily quota state.

### Governance and recovery

`Governor.schedule()/scheduleBatch()` → requested operation delay → `EXECUTOR_ROLE` executes. Recovery uses `RecoveryCouncil` proposal plus current `Guardian` approval; anyone can call `TSVGovernanceAnchor.executeRoot()` once its stored conditions are met.

---

## Permissionless

### `TSVHookProxyFactoryV1.deploy()`

| Aspect | Detail |
|--------|--------|
| Visibility | `external` |
| Caller | Any address |
| Parameters | `implementation`, `initData`, `salt` (caller-selected) |
| Call chain | `TSVHookProxyFactoryV1.deploy()` → `TSVERC1967Proxy` constructor |
| State modified | Creates a proxy at a CREATE2 address and emits `HookProxyDeployed` |
| Value flow | None |
| Reentrancy guard | No |

### `TSVGovernanceAnchor.executeRoot()`

| Aspect | Detail |
|--------|--------|
| Visibility | `external` |
| Caller | Any address after a current, active, Guardian-approved proposal |
| Parameters | `id` (protocol-derived proposal identifier) |
| Call chain | `TSVGovernanceAnchor.executeRoot()` → candidate `TSVUpgradeTimelock.activateGovernanceAnchor()` |
| State modified | Proposal lifecycle, governance root addresses, root epoch |
| Value flow | None |
| Reentrancy guard | No |

---

## Role-Gated

| Role / caller condition | Contract functions | Parameters and state touched |
|-------------------------|--------------------|-----------------------------|
| Eligible participant; router binds participant, payer, recipient, and caller | `TSVSwapRouterV1.swapExactInput()`, `swapExactOutput()` | User request and slippage bounds; nonce, temporary operation context, pool deltas |
| Active position owner plus current eligibility | `TSVLPManagerV1.openPosition()`, `increaseLiquidity()`, `decreaseLiquidity()`, `collectFees()`, `closePosition()` | Pool key, ticks, liquidity, bounds; position liquidity and active state |
| `POOL_CREATOR_ROLE` | `TSVLPManagerV1.initializePool()` | Pool key, initial price, price-basis hash; Registry pool state and PoolManager pool |
| `HALT_REPORTER_ROLE` (checked inside `_accept`) | `TSVDataInboxV1.submitMarketStatus()` | Market report; report cursors and Registry market status |
| `VOLUME_ORACLE_ROLE` (checked inside `_accept`) | `TSVDataInboxV1.submitAdtv()`, `submitAdtvBatch()`, `submitQuota()` | ADTV/quota reports; report cursors and Ledger cap inputs |
| DataInbox component caller | `TSVVolumeLedgerV1.acceptAdtv()`, `acceptQuota()` | Validated reports; ADTV and quota state |
| `SYMBOL_ADMIN_ROLE` | `TSVRegistryV1.listSecurity()`, `relistSecurity()`, `setSecurityTier()`, `delistSecurity()`, `registerToken()`, `setTokenStatus()`, `replaceLegalShareAdapter()`, `disablePool()`, `enablePool()` | Evidence hashes, token/security/pool configuration |
| `EMERGENCY_PAUSER_ROLE` / `EMERGENCY_RESUMER_ROLE` | `TSVRegistryV1.addEmergencyPause()`, `clearEmergencyPause()` | Pause scope/target and reason; pause records and active counters |
| `FORCE_EXIT_ADMIN_ROLE`, or `REVOKE_EXIT_EXECUTOR_ROLE` if owner has no credential | `TSVLPManagerV1.forceExit()` | Position, minimum outputs, evidence; closes position and pays recorded owner |
| `PoolManager` callback | `TSVSwapRouterV1.unlockCallback()`, `TSVLPManagerV1.unlockCallback()`, `TSVHookV1.beforeSwap()`, `afterSwap()` | Active request/context hashes; swap state, deltas, and Ledger call |
| Router / LP Manager internal caller binding | `TSVHookV1.assertCurrentAndClear()`, `TSVRegistryV1.registerPendingPool()`, `markPoolActive()`, `TSVRegistryV1.applyMarketStatus()`, `TSVVolumeLedgerV1.recordSwap()` | Operation, pool, market, or swap data; component-owned state |
| Hook caller binding | `TSVVolumeLedgerV1.recordSwap()` | Pool deltas and two rate snapshots; per-security daily usage |
| Router or LP Manager active-asset context | `IssuerShareSettlementAdapter.pullAndWrap()`, `prepareReceive()`, `redeemAndDeliver()` | Owner, recipient, shares, bounds and operation ID; temporary preparation state and wrapper redemption |
| `Guardian` | `TSVGovernanceAnchor.approveRoot()`, `revokeRootApproval()`; `TSVUpgradeTimelock.approveRecovery()`, `revokeRecoveryApproval()`, `cancel()`; `TSVEmergencyUpgradeController.freezeEmergencyUpgrades()` | Recovery IDs or freeze evidence; approval, operation, and freeze state |
| `RecoveryCouncil` | `TSVGovernanceAnchor.proposeRoot()`, `cancelRoot()` | Candidate root and evidence; root proposal lifecycle |
| `Governor` / `RecoveryCouncil` proposer roles | `TSVUpgradeTimelock.schedule()`, `scheduleBatch()` | Targets, payloads, predecessor, salt and requested delay; pending operations |
| `EXECUTOR_ROLE` | `TSVUpgradeTimelock.execute()`, `executeBatch()` | Scheduled operation payload; executes target calls |
| Timelock self-call during recovery | `TSVGovernanceAnchor.syncGuardian()` | Old/new Guardian; guardian address and epoch |

---

## Admin-Only

| Contract | Function | Parameters | State modified |
|----------|----------|------------|----------------|
| `TSVRegistryV1` | `bindComponents()` | Hook, LP manager, DataInbox | Component addresses |
| `TSVRegistryV1` | `setTierPolicy()` | Tier basis points, listing limit, evidence | Tier configuration |
| `TSVRegistryV1` | `setSbtConfig()` | SBT, token ID, evidence | Participant credential source |
| `TSVVolumeLedgerV1` | `bindWriters()` | Hook, DataInbox | Authorized writer addresses |
| `TSVVolumeLedgerV1` | `scheduleDayStart()`, `cancelPendingDayStart()` | Offset/date/reason | Trade-day checkpoints |
| `TSVGovernanceAnchor` | `bindProxies()` | Six proxy addresses | One-time proxy binding |
| `TSVUpgradeTimelock` | `bindBusinessAuthority()`, `bindEmergencyController()`, `bindGovernanceAnchor()`, `activateGovernanceAnchor()`, `nominateGovernanceAnchor()`, `recoverAuthorities()` | Root contracts, candidate root, or recovered identities | Governance links and recovery addresses |
| `TSVEmergencyUpgradeController` | `setUpgradeTarget()`, `unfreezeEmergencyUpgrades()`, `setGovernor()`, `setGuardian()` | Proxy allowlist or recovery identities | Emergency-upgrade and authority state |
| `TSVEmergencyUpgradeController` | `executeEmergencyUpgrade()` | Proxy, implementation, incident, action, evidence | Used action ID and proxy implementation |
| `TSVBusinessAuthority` | `recoverGovernor()` | Expected and new governor, evidence | Governor address during active recovery |
| `TSVGoverned` proxy implementations | `grantRole()`, `revokeRole()`, `renounceRole()` | Role and account | Business-role membership; default-admin role is protected |
| `TSVGoverned` proxy implementations | `upgradeToAndCall()` | Implementation and initialization data | Proxy implementation and upgrade state |
| `TSVUpgradeTimelock` | `grantRole()`, `revokeRole()`, `renounceRole()` | Role and account | Timelock role membership, subject to protected-role checks |

## Initialization

Six one-time proxy initializers are present: `TSVRegistryV1.initialize()`, `TSVVolumeLedgerV1.initialize()`, `TSVDataInboxV1.initialize()`, `TSVHookV1.initialize()`, `TSVSwapRouterV1.initialize()`, and `TSVLPManagerV1.initialize()`. Each binds governance and protocol addresses; proxy implementations disable initialization in their constructors.
