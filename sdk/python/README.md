# XLayer TSV Python SDK

This repository-native SDK runs the allowlisted Foundry operations through a shared simulate-then-broadcast flow. Public X Layer addresses are fixed in `script/xlayer/deployment.json`; private keys stay in the local environment file.

## Use

Create the local key file once and set the operator key:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Edit script/xlayer/.env.xlayer and set XLAYER_PRIVATE_KEY.
python3 script/xlayer/operate.py
```

Amounts are raw token units. `XLAYER_PRIVATE_KEY` signs and pays for transactions; neither side requires a backend signer. `XLAYER_RPC_URL` is an optional override. Keys cannot be supplied through `Operation.inputs`.

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

The SDK targets the unsigned three-field `MoreInfo(PoolKey key, uint256 expectedMultiplier, uint256 amountIn)` ABI, described by `src/v1/interfaces/external/ITSVDEXAdapter.sol`. Use a matching deployed Adapter and configure its DexRouter allowlist and the TSV Router Adapter allowlist. Previous signed deployments are incompatible.

`DexRouterTradeRequest.amount_in` / `TSV_DEX_AMOUNT_IN` is the positive outer DexRouter funding amount for both sides. Sales transfer U directly into W and encode that exact amount in MoreInfo, preserving surplus U. Purchases transfer Q to the Adapter, encode MoreInfo.amountIn = 0 and consume the live Q balance, including previous donations. No backend signature, nonce or authorization deadline is encoded. Remove `nonce` from Python request construction; the legacy `TSV_DEX_NONCE` and `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` settings are unnecessary.

`deadline_seconds` still controls the outer DexRouter transaction; `min_return` still protects output. The operator validates settlement mappings, balances and both allowlists. Approval and swap are separate transactions; a failed swap can leave the approved amount outstanding. Broadcast still requires a successful simulation and explicit `BROADCAST` confirmation.

Exact sale amounts do not prove ownership of prefunded U: the Adapter trusts the allowlisted DexRouter for amount and participant, and an identical payload can execute again if funds are available. The single-hop operator continues to require participant and receiver to be the trading wallet. See [integration details](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).

## Validation

```sh
PYTHONPATH=sdk/python python3 -m unittest discover -s sdk/python/tests -v
forge test --match-path test/unit/v1/operations/DexAdapterCalldata.t.sol -vv
forge build script/xlayer/TradeDexRouterTSV.s.sol
```

The tests validate repository-owned operator encoding and TSV Router boundaries without a private adapter checkout. They do not execute or verify an external adapter implementation. Before a live operation, check the configured public contract addresses, code, ABI, router binding and both allowlists.
