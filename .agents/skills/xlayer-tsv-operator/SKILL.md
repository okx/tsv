---
name: xlayer-tsv-operator
description: Operate this repository's XLayer TSV contracts through its interactive Python SDK, collecting per-operation inputs and simulating writes before broadcast.
---

# XLayer TSV operator

Use this skill for requests to inspect or operate the TSV deployment on X Layer, or to use the repository's TSV operator SDK.

Use the local key file and run the interactive entry point from the repository root:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# The user fills XLAYER_PRIVATE_KEY in script/xlayer/.env.xlayer.
python3 script/xlayer/operate.py
```

The operator automatically loads the local key file. The mainnet RPC, deployment addresses, and public inventory are fixed in `script/xlayer/deployment.json`, so users only need to provide their own `XLAYER_PRIVATE_KEY`. The operator asks for action-specific inputs, simulates each write, and only broadcasts after the user types `BROADCAST`. Do not inspect, copy, print, or commit `script/xlayer/.env.xlayer`.

Use the typed programmatic API and its explicit `simulate` then `broadcast` flow when the user asks for SDK usage or automation. Read [the SDK API reference](references/sdk-api.md) for the operation targets and DEX request shape.

Ask for each operation's real parameters. U/W/Q assets and reason codes are per-operation lists or values; never assume a single QuoteToken or a reusable reason code. Amounts are raw units unless the prompt says legal-share WAD. Before a write, summarize the selected action, assets, direction, amounts, and limits for the user through the operator prompts. Do not reuse old test inputs for a new transaction without an explicit instruction.

For DexRouter + TSVAdapter requests, follow the external adapter repository's `main` version recorded by the submodule. Verify the Adapter's `isDexRouter` list and the TSV Router's `isAdapterAllowed` list independently. Current `MoreInfo` is ABI-encoded `(PoolKey, expectedMultiplier)` and has no `AUTH_SIGNER` signature. Confirm the pool, multiplier, direction, raw input, minimum return, deadline, participant SBT, and direction-specific funding (`Q -> adapter` for buys; `U -> W` for sells) before a mainnet route. The SDK formats a single-hop request; it does not approve tokens or broadcast the external DexRouter call. A local harness test is not evidence of a live XLayer route.

After any broadcast, report the transaction hash and verify its receipt and resulting balances/state. Record the transaction and its purpose in the user's [Lark transaction log](https://okg-block.sg.larksuite.com/docx/YU5JdyR8DokY8fxd3yclI2wIgId). Keep local test results and mainnet transaction evidence distinct.
