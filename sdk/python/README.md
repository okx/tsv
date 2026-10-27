# XLayer TSV Python SDK

This repository-native SDK runs the allowlisted Foundry operations through a shared simulate-then-broadcast flow. Public X Layer addresses are fixed in `script/xlayer/deployment.json`; private keys stay in the local environment file.

## Use

Create the local key file once and set the operator key:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Edit script/xlayer/.env.xlayer and set XLAYER_PRIVATE_KEY.
python3 script/xlayer/operate.py
```

Amounts are raw token units. `XLAYER_PRIVATE_KEY` signs and pays for operations. For DexRouter + TSVAdapter stock sales only, also set `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY`; its derived address must equal `AUTH_SIGNER()` on the signed-amount Adapter. The operator never accepts either key through `Operation.inputs`, and redacts both from Forge output. `XLAYER_RPC_URL` is an optional override.

`Target` covers the inspect, registration, adapter deployment, pool, direct trade, liquidity, SBT, Registry, Ledger, and DexRouter trade scripts. `operate.py` collects operation-specific values; the SDK owns the script allowlist, signing environment, simulation fingerprint, and explicit broadcast gate.

`PermissionsAdapterFactoryMigrationRequest` formats the Registry action, replacement Factory, and three distinct reason codes for `Target.REGISTRY_OPERATION`:

```python
from tsv_xlayer_sdk import (
    ExecutionClient,
    Operation,
    PermissionsAdapterFactoryMigrationRequest,
    Target,
)

request = PermissionsAdapterFactoryMigrationRequest(
    new_factory="0x<replacement-factory-address>",
    pause_reason_code="pause-reason",
    replacement_reason_code="factory-replacement-reason",
    resume_reason_code="resume-reason",
)
operation = Operation(Target.REGISTRY_OPERATION, "Replace PermissionsAdapterFactory", request.env())
client = ExecutionClient()
simulation = client.simulate(operation)
if simulation.result.succeeded:
    result = client.broadcast(simulation, "BROADCAST")
```

The operation also requires the security inventory configured in `deployment.json` to have no listed pools, plus the operator's Registry admin and upgrade roles. It permanently grants the signer emergency pause/resume roles; any W unrecognized by the new Factory will fail Factory validation after the switch. Simulate before broadcast and use the exact `BROADCAST` confirmation.

## DexRouter + TSVAdapter

`DexRouterTradeRequest` validates and formats a one-hop request for `Target.DEX_ROUTER_TRADE`. Its `env()` method returns only public operation inputs; the Solidity script builds `MoreInfo`, checks both TSV/Adapter allowlists and TokenApproveProxy wiring, then calls `IDexRouter.dagSwapTo`. Stock sales require the local auth signer; purchases do not read it.

Stock sales sign the exact input amount, PoolKey, direction, multiplier, participant, allowed caller, nonce, and deadline. The Adapter receiver (`to`) is chosen by DexRouter at execution and is not signed. Buys pre-transfer Q to the Adapter (`assetTo = adapter`) and swap its live Q balance. Buy `MoreInfo` encodes `amountIn = nonce = deadline = 0`, `allowedCallers = []`, and `authSig = 0x`; the operator does not ask for a buy nonce. Sells pre-transfer U directly to W (`assetTo = W`) and consume only the signed amount, preserving surplus U. **The SDK request `amount_in` / `TSV_DEX_AMOUNT_IN` is still the positive DexRouter funding amount for either side, not the zero buy `MoreInfo.amountIn`.** `deadline_seconds` still controls the outer DexRouter transaction for purchases. If the TokenApprove allowance is below the trade amount, the script includes an exact-amount approval before the swap. Both writes are simulated first; the operator only broadcasts after `BROADCAST`.

The local callback integration fixture tracks the current upstream `MoreInfo` ABI. It does not certify live X Layer deployment state. See [the adapter integration note](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) for the signature, funding, deployment, and authorization requirements.

## Validation

```sh
python3 -m unittest discover -s sdk/python/tests -v
TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY="0x$(openssl rand -hex 32)" \
  forge test --match-path test/integration/local/trading/DexAdapter.t.sol -vv
```

The test key is ephemeral and is not used for live transactions. The Adapter submodule is pinned to `5be1e7f8963979c637adae9f21077a6c4100c5a8`; its OpenZeppelin 4 dependency uses a scoped remapping, leaving TSV's OpenZeppelin 5 dependency unchanged.
