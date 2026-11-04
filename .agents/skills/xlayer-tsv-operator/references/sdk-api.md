# SDK API reference

The package is in `sdk/python/tsv_xlayer_sdk` and requires Python 3.10+. Add `sdk/python` to `PYTHONPATH` or install it with `pip install -e sdk/python`.

## Foundry operations

`Target` enumerates the XLayer scripts: asset and pool inspection, quote registration, stock adapter creation and verification, stock registration, pool initialization, direct TSV trade, Registry and Ledger operations (including the multi-step PermissionsAdapterFactory migration), Legal-share Adapter deployment, SBT issuance, liquidity addition, and unsigned DexRouter + TSVAdapter swaps.

Create an immutable `Operation(target, label, inputs)` using script environment variables as `inputs`. Keep signing credentials out of `inputs`; the client reads `XLAYER_PRIVATE_KEY` from `script/xlayer/.env.xlayer` or the process environment. Public mainnet RPC/deployment values load from `script/xlayer/deployment.json`. `XLAYER_RPC_URL` is an optional override.

```python
simulation = client.simulate(operation)
if simulation.result.succeeded:
    result = client.broadcast(simulation, "BROADCAST")
```

`broadcast` rejects read-only operations, failed simulations, any confirmation other than the exact word `BROADCAST`, and any operation/configuration change since simulation. It reruns the same allowlisted Forge script with `--broadcast`.

The `MIGRATE_PERMISSIONS_ADAPTER_FACTORY` Registry operation permanently grants the signer `EMERGENCY_PAUSER_ROLE` and `EMERGENCY_RESUMER_ROLE`, upgrades LP Manager, moves Router through an old-Factory bridge implementation to the new Factory implementation, pauses the Registry, upgrades Registry, replaces its Factory pointer, then resumes the Registry. It requires the configured securities to have no listed pools and asks for three distinct reason codes. A W not recognized by the replacement Factory will stop passing Factory validation.

`PermissionsAdapterFactoryMigrationRequest` formats the action, replacement Factory address, and distinct pause/replacement/resume reason codes for `Operation(Target.REGISTRY_OPERATION, ..., request.env())`. The security and W inventories remain in the public deployment configuration; signing keys are loaded separately by `ExecutionClient`.

`PoolKey` validates nonzero sorted currencies, fee, tick spacing, and hook. `TradeRequest` validates raw input/minimum output/deadline and creates the `TSV_*` environment values for `Target.TRADE`.

## DexRouter + unsigned external adapter

Use `DexRouterTradeRequest.env()` with the configured deployed adapter and DEX Router addresses. The supported MoreInfo is `(PoolKey, expectedMultiplier, amountIn)` and requires no backend signature or nonce. Stock sales encode the funded exact amount; purchases use amountIn = 0 as the external adapter's live-quote-balance sentinel. The outer transaction still has an output minimum and deadline.

The adapter implementation is outside this repository. See the [public ABI boundary](../../../../src/v1/interfaces/external/ITSVDEXAdapter.sol) and the repository's integration guide. Check addresses, code, ABI and both allowlists before simulation or broadcast.
