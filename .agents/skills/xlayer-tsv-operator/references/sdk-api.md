# SDK API reference

The package is in `sdk/python/tsv_xlayer_sdk` and requires Python 3.10+. Add `sdk/python` to `PYTHONPATH` or install it with `pip install -e sdk/python`.

## Foundry operations

`Target` enumerates the XLayer scripts: asset and pool inspection, quote registration, stock adapter creation and verification, stock registration, pool initialization, direct TSV trade, Registry and Ledger operations (including the multi-step PermissionsAdapterFactory migration), Legal-share Adapter deployment, SBT issuance, liquidity addition, and signed DexRouter + TSVAdapter swaps.

Create an immutable `Operation(target, label, inputs)` using script environment variables as `inputs`. Keep signing credentials out of `inputs`; the client reads `XLAYER_PRIVATE_KEY` and, for DexRouter swaps, `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` from `script/xlayer/.env.xlayer` or the process environment. Public mainnet RPC/deployment values load from `script/xlayer/deployment.json`. `XLAYER_RPC_URL` is an optional override.

```python
simulation = client.simulate(operation)
if simulation.result.succeeded:
    result = client.broadcast(simulation, "BROADCAST")
```

`broadcast` rejects read-only operations, failed simulations, any confirmation other than the exact word `BROADCAST`, and any operation/configuration change since simulation. It reruns the same allowlisted Forge script with `--broadcast`.

The `MIGRATE_PERMISSIONS_ADAPTER_FACTORY` Registry operation permanently grants the signer `EMERGENCY_PAUSER_ROLE` and `EMERGENCY_RESUMER_ROLE`, upgrades LP Manager, moves Router through an old-Factory bridge implementation to the new Factory implementation, pauses the Registry, upgrades Registry, replaces its Factory pointer, then resumes the Registry. It requires the configured securities to have no listed pools and asks for three distinct reason codes. A W not recognized by the replacement Factory will stop passing Factory validation.

`PermissionsAdapterFactoryMigrationRequest` formats the action, replacement Factory address, and distinct pause/replacement/resume reason codes for `Operation(Target.REGISTRY_OPERATION, ..., request.env())`. The security and W inventories remain in the public deployment configuration; signing keys are loaded separately by `ExecutionClient`.

`PoolKey` validates nonzero sorted currencies, fee, tick spacing, and hook. `TradeRequest` validates raw input/minimum output/deadline and creates the `TSV_*` environment values for `Target.TRADE`.

## DexRouter + signed TSVAdapter trade

`DexRouterTradeRequest.env()` returns operation inputs for `Target.DEX_ROUTER_TRADE`; the Foundry script builds the `dagSwapTo` ABI arguments and signs `MoreInfo` from the local auth signer key. The request requires the configured Adapter, DEX Router, TSV Router, PoolKey, stock W and underlying U, buy/sell side, raw `amountIn`, minimum return, expected multiplier, nonce, and validity period. The participant and receiver default to the `XLAYER_PRIVATE_KEY` wallet; an explicit override must match that wallet for this one-hop script.

The signed MoreInfo order is `(key, expectedMultiplier, amountIn, allowedCallers, nonce, deadline, authSig)`. `authSig` is a 64-byte EIP-2098 personal-sign signature over the pool, multiplier, exact amount, direction, participant, `to`, deadline, Adapter address, allowed callers, nonce, and chain ID. The signer key must derive the deployed Adapter's `AUTH_SIGNER()` address. The operation wallet is the participant and receiver for this single-hop route.

The route pre-funds Q to the Adapter for buys and U to W for sells. Before simulation/broadcast, the script checks Adapter `isDexRouter`, TSV Router `isAdapterAllowed`, TokenApproveProxy wiring, the Adapter's `AUTH_SIGNER()`, and `isNonceUsed`. If TokenApprove allowance is insufficient, the broadcast includes an exact-amount approval before the swap. The new constructor is incompatible with old immutable Adapter deployments; replace the address in `deployment.json` only after a signed Adapter has been deployed and both allowlists are configured. See `docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md` for full constraints.
