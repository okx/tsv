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

## DexRouter + TSVAdapter

The SDK targets the unsigned three-field `MoreInfo(PoolKey key, uint256 expectedMultiplier, uint256 amountIn)` ABI, pinned by `lib/dex-adapters` at commit `80800d56`. Use a matching deployed Adapter and configure its DexRouter allowlist and the TSV Router Adapter allowlist. Previous signed deployments are incompatible.

`DexRouterTradeRequest.amount_in` / `TSV_DEX_AMOUNT_IN` is the positive outer DexRouter funding amount for both sides. Sales transfer U directly into W and encode that exact amount in MoreInfo, preserving surplus U. Purchases transfer Q to the Adapter, encode MoreInfo.amountIn = 0 and consume the live Q balance, including previous donations. No backend signature, nonce or authorization deadline is encoded. Remove `nonce` from Python request construction; the legacy `TSV_DEX_NONCE` and `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` settings are unnecessary.

`deadline_seconds` still controls the outer DexRouter transaction; `min_return` still protects output. The operator validates settlement mappings, balances and both allowlists. Approval and swap are separate transactions; a failed swap can leave the approved amount outstanding. Broadcast still requires a successful simulation and explicit `BROADCAST` confirmation.

Exact sale amounts do not prove ownership of prefunded U: the Adapter trusts the allowlisted DexRouter for amount and participant, and an identical payload can execute again if funds are available. The single-hop operator continues to require participant and receiver to be the trading wallet. See [integration details](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).

## Validation

```sh
python3 -m unittest discover -s sdk/python/tests -v
forge test --match-path test/integration/local/trading/DexAdapter.t.sol --skip SecuritizeTSVChecker.sol -vv
forge build script/xlayer/TradeDexRouterTSV.s.sol
```

Tests require no signer environment variable and do not broadcast transactions. Legacy signer values are still redacted from child-process output if present in an inherited environment.

Validation: 8 Python tests and 13 local integration tests passed; the trade script compiled. The integration command excludes the unrelated `src/v1/vendor/SecuritizeTSVChecker.sol`, whose relative imports are missing on the current main branch. This is not a full-repository build result.
