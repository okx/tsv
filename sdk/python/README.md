# XLayer TSV Python SDK

This repository-native SDK runs the allowlisted Foundry operations through a shared simulate-then-broadcast flow. Public X Layer addresses are fixed in `script/xlayer/deployment.json`; private keys stay in the local environment file.

## Use

Create the local key file once and set the operator key:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Edit script/xlayer/.env.xlayer and set XLAYER_PRIVATE_KEY.
python3 script/xlayer/operate.py
```

Amounts are raw token units. `XLAYER_PRIVATE_KEY` signs and pays for operations. For DexRouter + TSVAdapter swaps, also set `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY`; its derived address must equal `AUTH_SIGNER()` on the signed-amount Adapter. The operator never accepts either key through `Operation.inputs`, and redacts both from Forge output. `XLAYER_RPC_URL` is an optional override.

`Target` covers the inspect, registration, adapter deployment, pool, direct trade, liquidity, SBT, Registry, Ledger, and DexRouter trade scripts. `operate.py` collects operation-specific values; the SDK owns the script allowlist, signing environment, simulation fingerprint, and explicit broadcast gate.

## DexRouter + TSVAdapter

`DexRouterTradeRequest` validates and formats a one-hop request for `Target.DEX_ROUTER_TRADE`. Its `env()` method returns only public operation inputs; the Solidity script builds the current signed `MoreInfo` using the local auth signer key, checks both TSV/Adapter allowlists and TokenApproveProxy wiring, then calls `IDexRouter.dagSwapTo`.

The route signs the exact input amount, PoolKey, direction, multiplier, participant, receiver, allowed caller, nonce, and deadline. Buys pre-transfer Q to the Adapter (`assetTo = adapter`); sells pre-transfer U directly to W (`assetTo = W`). If the TokenApprove allowance is below the trade amount, the script includes an exact-amount approval before the swap. Both writes are simulated first; the operator only broadcasts after `BROADCAST`.

The local callback integration fixture tracks the current upstream `MoreInfo` ABI. It does not certify live X Layer deployment state. See [the adapter integration note](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) for the signature, funding, deployment, and authorization requirements.
