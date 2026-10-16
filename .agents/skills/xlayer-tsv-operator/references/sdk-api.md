# SDK API reference

The package is in `sdk/python/tsv_xlayer_sdk` and requires Python 3.10+. Add `sdk/python` to `PYTHONPATH` or install it with `pip install -e sdk/python`.

## Foundry operations

`Target` enumerates the existing XLayer scripts: asset and pool inspection, quote registration, stock adapter creation and verification, stock registration, pool initialization, direct TSV trade, Registry and Ledger operations, Legal-share Adapter deployment, SBT issuance, and liquidity addition.

Create an immutable `Operation(target, label, inputs)` using script environment variables as `inputs`. Keep signing credentials out of `inputs`; the client reads `XLAYER_PRIVATE_KEY` from `script/xlayer/.env.xlayer` or the process environment and loads the fixed mainnet RPC/deployment values from `script/xlayer/deployment.json`. `XLAYER_RPC_URL` is an optional override.

```python
simulation = client.simulate(operation)
if simulation.result.succeeded:
    result = client.broadcast(simulation, "BROADCAST")
```

`broadcast` rejects read-only operations, failed simulations, any confirmation other than the exact word `BROADCAST`, and any operation/configuration change since simulation. It reruns the same allowlisted Forge script with `--broadcast`.

`PoolKey` validates nonzero sorted currencies, fee, tick spacing, and hook. `TradeRequest` validates raw input/minimum output/deadline and creates the `TSV_*` environment values for `Target.TRADE`.

## DexRouter + TSVAdapter route formatting

`DexRouterTradeRequest` returns the four ABI arguments for `IDexRouter.dagSwapTo`: order ID, receiver, `BaseRequest`, and one-entry `RouterPath[]`. It requires the TSVAdapter address, TSV Router, registered PoolKey, stock currency, both settlement currencies, side, raw amount, minimum return, absolute deadline, receiver, and ABI-encoded `MoreInfo(PoolKey, expectedMultiplier)`. The current external repository `main` does not sign `MoreInfo` and does not use `AUTH_SIGNER`.

The builder routes purchases with `assetTo = adapter` and sales with `assetTo = stock W`, so the DexRouter pre-transfers Q to the Adapter or U to W as required. The request builder does not approve user tokens or execute the DEX trade. Verify both Adapter allowlists and SBT/pool state first. See `docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md` for caller markers, settlement, quota, identity, and deployment requirements.

The local `testDexRouterAdapterBuy` and `testDexRouterAdapterSell` cases exercise the production TSVAdapter and TSV router through a test-only single-hop callback harness. A successful local run does not prove the XLayer DexRouter deployment is compatible or that a live adapter is configured.
