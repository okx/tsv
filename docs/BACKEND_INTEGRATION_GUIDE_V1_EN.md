# TSV V1 Backend Integration Guide

This guide follows the current `src/v1/` ABI. It does not describe ADTV reports, split-factor reports, configurable trade days, or a DataInbox; those are absent from the current contracts. Verify target-chain addresses, deployed ABIs, and roles before sending transactions.

## 1. Assets and pool identity

Every TSV pool is a V4 **W/Q** pool: W is a verified Permissions Adapter for a stock; Q is a separately registered quote token. Users settle the stock leg in U, the underlying token; the PoolManager settles W/Q. Multiple W adapters and pools for the same U share one `securityId`, legal-share adapter, and Ledger quota.

Useful reads:

| Read | Purpose |
| --- | --- |
| `registry.getCurrencyUnderlying(W)` | Resolve W to U; zero means the currency is not registered as W |
| `registry.getUnderlying(U)` | Read `securityId`, `legalShareAdapter`, decimals, and new-pool registration state |
| `registry.getQuoteToken(Q)` | Read Q decimals and new-pool registration state |
| `registry.getPool(poolId)` | Read the PoolKey, security ID, tier snapshot, lifecycle, and NFT count |
| `registry.isKnownPool(poolId)` / `getPoolLifeCycle(poolId)` | Check pool registration and lifecycle |
| `router.settlementCurrency(W)` | Resolve stock settlement to U; quote tokens resolve to themselves |

`poolId` is the Uniswap V4 hash of the complete PoolKey. Do not identify a pool using only its token pair, fee, or hook.

## 2. Participant permissions and DEX adapters

Both Router swap write methods require `msg.sender` to be in the Router adapter allowlist. End users do not call the Router directly:

- `swapExactInputFromContractDirect(request, payer, participant, recipient)` is called by an allowlisted adapter. For U input, `payer` must be zero and U must already be deposited in W; for Q input, `payer` must be the calling adapter. Output goes to `recipient`.
- `swapExactInputFromContract(request, participant)` is called by an allowlisted adapter; the calling adapter is both payer and output recipient.

For Q input, after `PoolManager.sync`, the Router transfers Q directly from the payer to PoolManager and then calls `settle`; the payer approves Q to the Router. U input is still transferred into W by the Router (or uses U already deposited in W on the Direct path), then W wraps it to PoolManager.

The Router checks `registry.isSbtAllowed(SWAP_ALLOWED, participant)`. W independently checks issuer permissions and `swappingEnabled`. Check both layers. For a DEX integration, follow the marker, signature caller set, nonce, and refund-field rules in the [external DEX adapter guide](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).

## 3. SwapRequest and execution limits

```solidity
struct SwapRequest {
    PoolKey key;
    bool zeroForOne;
    uint128 amountSpecified;
    uint128 limitAmount;
    uint64 deadline;
    uint256 expectedMultiplier;
}
```

- `amountSpecified` is exact input in raw settlement-token units; it must be nonzero and at most `int128.max`.
- `limitAmount` is minimum output in raw units and must be nonzero.
- `deadline` is Unix time in seconds.
- `expectedMultiplier` should come from `currentMultiplier(U)` on the canonical U adapter. The Hook checks it before the swap and again while accounting; a changed value reverts.
- The Router builds one exact-input V4 action, derives the price range from the direction, and requires actual input to equal requested input. Partial fill and exact-output are unsupported.

Success returns `(actualIn, actualOut)`. The Router emits no separate swap event; the Ledger emits `VolumeUsed(securityId, poolId, ESTDay, amount)`. Reconcile the V4 Swap event, Router return values, and Ledger event.

## 4. Lifecycle, pauses, and read gates

- `registry.isTradable(poolId)` checks registration, `LIST` lifecycle, and the security trade pause.
- `registry.isLPAllowed(poolId)` checks registration, non-`DELIST` lifecycle, and the security LP pause.
- `registry.isPaused()` reports the separate global emergency pause. The first two views do not include it.
- `SecurityPauseMode` writes a final value: `NONE`, `TRADE`, `LP`, or `ALL`.
- `PoolLifecycle.PAUSE` blocks swaps while allowing ordinary LP operations; `DELIST` requires the Registry's position NFT count to be zero.

Disabling an asset for future pool registration does not close its existing pools. A security can be delisted only after all associated pools are `DELIST`.

## 5. Volume Ledger

`currentESTDay()` returns `(block.timestamp - 5 hours) / 1 days`: an epoch day with a fixed 05:00 UTC boundary (UTC-5 year-round, without daylight-saving changes). Use the on-chain value as the day key.

An account with Registry `VOLUME_ORACLE_ROLE` writes direct quota and usage values:

```solidity
struct DailyQuota { uint256 ESTDay; uint256 amount; }

ledger.setQuota(securityId, amount, reasonCode);
ledger.setUsedWad(securityId, values, reasonCode);
```

- `amount` is legal-share WAD. There is no ADTV/tier-derived quota formula; each value is written directly.
- Each security has one daily quota that remains in effect until changed. Usage is stored separately for each `securityId` and `ESTDay`. All W adapters and pools for a security share that quota and usage.
- A missing quota defaults to zero, so positive-volume swaps require a quota first.
- `setQuota` does not reset `usedWad`. `setUsedWad` may lower usage, set it to zero, or set it above quota; later swaps enforce the resulting state.
- Both methods require nonzero `securityId` and `reasonCode`. `setQuota` takes effect immediately and cannot schedule a quota for a future day. For `setUsedWad`, empty arrays do nothing; unsorted dates are accepted; a repeated day is overwritten by the last array item.
- Events are `QuotaSet`, `UsedWadSet`, and `VolumeUsed`.

Read `Quota(securityId)`, `usedWad(securityId, ESTDay)`, and `currentESTDay()`. Confirm the capitalized `Quota` getter name in the deployed ABI.

## 6. Registry operations

| Operation | Registry method / role |
| --- | --- |
| Register W and a new security, or add W to one | `registerPermissionedCurrency(param, tierId, reasonCode)` / `SYMBOL_ADMIN_ROLE` |
| Register Q | `registerQuoteToken(quote, reasonCode)` / Symbol Admin |
| Disable U/Q for new pools | `disableUnderlyingPoolRegister` / `disableQuoteTokenPoolRegister` / Symbol Admin |
| Replace canonical legal-share adapter | `replaceUnderlyingLegalShareAdapter(u, adapter, reasonCode)` / Symbol Admin |
| Set final security pause mode | `applySecurityStatus(securityId, mode, reasonCode)` / `HALT_REPORTER_ROLE` |
| Enable/disable global pause | `setEmergencyPauseEnable(enabled, reasonCode)` / separate pauser and resumer roles |
| Change pool lifecycle | `updatePoolLifeCycle` / `batchUpdatePoolLifeCycle` / Symbol Admin |

All administrative write methods require a nonzero reason code. The `SecurityStatusChanged` event does not include that code even though the setter accepts it.

## 7. LP Manager

- `POOL_CREATOR_ROLE` calls `initializePool(key, sqrtPriceX96)` to register and initialize a V4 pool.
- Encode upstream V4 position actions in `modifyLiquidities(unlockData, deadline)` or `modifyLiquiditiesWithoutUnlock(actions, params)`. Use explicit `MINT_POSITION` and `INCREASE_LIQUIDITY`; the two `*_FROM_DELTAS` actions are rejected.
- Ordinary position actions check TSV `LIQUIDITY_ALLOWED` for both executor and position owner, then check the pool gate and issuer permissions.
- LP user payments go through immutable `TOKEN_APPROVE_PROXY.claimTokens`. Users approve `TOKEN_APPROVE_PROXY.tokenApprove()`, and deployment ops must allowlist the LP Manager proxy in TokenApproveProxy.
- `withdrawClaim` always reverts in the TSV LP Manager.
- `unwindPosition` is available to the owner of either verified permissioned pool currency; `unwindPositionByOkx` requires `FORCE_EXIT_ADMIN_ROLE`. Both perform a full exit to the original NFT owner. The global pause blocks both entry points.

Forced exit is not guaranteed for every asset or position: a quote can reject delivery, and the complete principal/fee delta can exceed V4's `int128` range. Do not describe it as unconditionally available.

## 8. Proxy and upgrade reads

`TSVERC1967Proxy.tsvImplementation()` returns the current implementation. Cross-check component addresses using proxy getters, Registry bindings, and implementation immutables. Registry is the AccessControl role root; components read upgrade permissions from it. Current code has no Governance Anchor, batch upgrade freeze, or legacy report entry point.

See the [deployment checklist](./DEPLOYMENT_CHECKLIST_V1.md) and [implementation boundary](./IMPLEMENTATION_STATUS_V1.md). The Chinese guide is [`BACKEND_INTEGRATION_GUIDE_V1.md`](./BACKEND_INTEGRATION_GUIDE_V1.md).
