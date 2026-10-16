# XLayer TSV Python SDK

This repository-native SDK wraps the existing Foundry operator scripts and formats a thin external DEX route request. It does not store wallet credentials or execute an on-chain DEX router locally.

## Use

From the repository root, create the local key file once. The SDK reads it automatically:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Edit script/xlayer/.env.xlayer and set XLAYER_PRIVATE_KEY.
PYTHONPATH=sdk/python python3 - <<'PY'
from tsv_xlayer_sdk import ExecutionClient, Operation, Target, TradeRequest, PoolKey

# Replace these valid placeholders with the registered, address-sorted PoolKey.
pool = PoolKey(
    "0x0000000000000000000000000000000000000001",
    "0x0000000000000000000000000000000000000002",
    3000,
    60,
    "0x0000000000000000000000000000000000000003",
)
trade = TradeRequest(pool, zero_for_one=True, amount_in=100_000, min_amount_out=1)
client = ExecutionClient()
simulation = client.simulate(Operation(Target.TRADE, "Trade TSV", trade.env()))
print(simulation.result.stdout, end="")
if simulation.result.succeeded:
    typed = input("Type BROADCAST to send the simulated write: ")
    result = client.broadcast(simulation, typed)
    print(result.stdout, end="")
PY
```

Amounts are raw token units. The SDK loads `XLAYER_PRIVATE_KEY` from `script/xlayer/.env.xlayer` or the process environment; it never accepts credentials as operation inputs or prints them. The mainnet RPC defaults to the public endpoint and deployment inventory in `script/xlayer/deployment.json`. `XLAYER_RPC_URL` may be set as an optional override.

`Target` covers the inspect, registration, adapter deployment, pool, trade, liquidity, SBT, Registry, and Ledger scripts used by `script/xlayer/operate.py`. `operate.py` is the interactive front end; the SDK is its shared simulation/broadcast execution layer.

For an external DEX hop, `DexRouterTradeRequest` builds the `dagSwapTo` ABI arguments from a typed pool, direction, amount, receiver, and ABI-encoded `MoreInfo(PoolKey, expectedMultiplier)`. The current adapter `main` does not use `AUTH_SIGNER` or signed `MoreInfo`. The builder does not approve tokens or broadcast to DexRouter. Both the Adapter's DexRouter allowlist and the TSV Router's Adapter allowlist must be configured. It sends purchase Q to the Adapter and sale U directly to the stock W. See [the adapter integration note](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).

The two `DexAdapter.t.sol` buy/sell cases use a local single-hop DexRouter harness to exercise the current-main TSVAdapter and TSV router. They are local integration coverage; they do not certify the deployed XLayer DexRouter or submit live trades.
