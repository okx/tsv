---
name: xlayer-tsv-operator
description: Operate this repository's XLayer TSV contracts through its interactive Python SDK, collecting per-operation inputs and simulating writes before broadcast.
---

# XLayer TSV operator

Use this skill for requests to inspect or operate the TSV deployment on X Layer, or to use the repository's TSV operator SDK.

Use the local key file and run the interactive entry point from the repository root:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Fill XLAYER_PRIVATE_KEY for authorized transactions only.
python3 script/xlayer/operate.py
```

The operator automatically loads the local key file. The mainnet RPC, deployment addresses, and public inventory are fixed in `script/xlayer/deployment.json`. `XLAYER_PRIVATE_KEY` is the operation wallet. The operator asks for action-specific inputs, simulates each write, and only broadcasts after the user types `BROADCAST`. Do not inspect, copy, print, or commit `script/xlayer/.env.xlayer`.

Use the typed programmatic API and its explicit `simulate` then `broadcast` flow when the user asks for SDK usage or automation. Read [the SDK API reference](references/sdk-api.md) for operation targets and the unsigned DEX request shape.

Ask for each operation's real parameters. U/W/Q assets and reason codes are per-operation lists or values; never assume a single QuoteToken or a reusable reason code. Amounts are raw units unless the prompt says legal-share WAD. Before a write, summarize the selected action, assets, direction, amounts, and limits for the user through the operator prompts. Do not reuse old test inputs for a new transaction without an explicit instruction.

For a PermissionsAdapterFactory migration, check that every configured security has zero listed pools and that the replacement Factory uses the Registry's PoolManager. Explain that the operation permanently grants the signer `EMERGENCY_PAUSER_ROLE` and `EMERGENCY_RESUMER_ROLE`, upgrades LP Manager, moves Router through the old-Factory bridge, pauses and upgrades Registry, replaces its Factory pointer, and resumes it. Confirm the user accepts any old W that the replacement Factory does not recognize becoming invalid for Factory validation. Collect three distinct reason codes, simulate the complete sequence, and broadcast only after the user types `BROADCAST`.

For DexRouter + TSVAdapter requests, use the public ABI at `src/v1/interfaces/external/ITSVDEXAdapter.sol` and a reviewed deployment address. The unsigned MoreInfo has PoolKey, expectedMultiplier and amountIn. Verify adapter TSV_ROUTER, isDexRouter, Router isAdapterAllowed and settlement mappings independently. Neither a private source checkout nor a backend signing key is required. Do not claim local ABI tests validate the deployed adapter implementation.

After any broadcast, report the transaction hash and verify its receipt and resulting balances/state. Record the transaction and its purpose in the operator's chosen audit log. Keep local test results and mainnet transaction evidence distinct.
