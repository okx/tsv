---
name: xlayer-tsv-operator
description: Operate this repository's XLayer TSV contracts through its interactive Python SDK, collecting per-operation inputs and simulating writes before broadcast.
---

# XLayer TSV operator

Use this skill for requests to inspect or operate the TSV deployment on X Layer, or to use the repository's TSV operator SDK.

Use the local key file and run the interactive entry point from the repository root:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Fill XLAYER_PRIVATE_KEY; DexRouter + TSVAdapter swaps also need TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY.
python3 script/xlayer/operate.py
```

The operator automatically loads the local key file. The mainnet RPC, deployment addresses, and public inventory are fixed in `script/xlayer/deployment.json`. `XLAYER_PRIVATE_KEY` is the operation wallet. `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` is only needed for DexRouter + TSVAdapter swaps; its derived address must match the deployed Adapter's `AUTH_SIGNER()`. The operator asks for action-specific inputs, simulates each write, and only broadcasts after the user types `BROADCAST`. Do not inspect, copy, print, or commit `script/xlayer/.env.xlayer`.

Use the typed programmatic API and its explicit `simulate` then `broadcast` flow when the user asks for SDK usage or automation. Read [the SDK API reference](references/sdk-api.md) for operation targets and the signed DEX request shape.

Ask for each operation's real parameters. U/W/Q assets and reason codes are per-operation lists or values; never assume a single QuoteToken or a reusable reason code. Amounts are raw units unless the prompt says legal-share WAD. Before a write, summarize the selected action, assets, direction, amounts, and limits for the user through the operator prompts. Do not reuse old test inputs for a new transaction without an explicit instruction.

For a PermissionsAdapterFactory migration, check that every configured security has zero listed pools and that the replacement Factory uses the Registry's PoolManager. Explain that the operation permanently grants the signer `EMERGENCY_PAUSER_ROLE` and `EMERGENCY_RESUMER_ROLE`, upgrades LP Manager, moves Router through the old-Factory bridge, pauses and upgrades Registry, replaces its Factory pointer, and resumes it. Confirm the user accepts any old W that the replacement Factory does not recognize becoming invalid for Factory validation. Collect three distinct reason codes, simulate the complete sequence, and broadcast only after the user types `BROADCAST`.

For DexRouter + TSVAdapter requests, follow the external adapter repository's pinned `main` version in the submodule. The current `MoreInfo` ABI has PoolKey, multiplier, exact `amountIn`, allowed callers, nonce, deadline, and a 64-byte EIP-2098 signature. Verify the deployed adapter's `AUTH_SIGNER()`, its `isDexRouter` list, and the TSV Router's `isAdapterAllowed` list independently. Confirm the pool, multiplier, direction, raw input, minimum return, deadline, participant SBT, and funding (`Q -> adapter` for buys; `U -> W` for sells). The interactive action constructs the signed one-hop route, checks the fixed DexRouter/TokenApprove configuration, simulates it, and only broadcasts after `BROADCAST`. A local harness test is not evidence of a live X Layer route. Old Adapter deployments are immutable and cannot accept the signed ABI.

After any broadcast, report the transaction hash and verify its receipt and resulting balances/state. Record the transaction and its purpose in the user's [Lark transaction log](https://okg-block.sg.larksuite.com/docx/YU5JdyR8DokY8fxd3yclI2wIgId). Keep local test results and mainnet transaction evidence distinct.
