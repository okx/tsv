# XLayer TSV interactive operator

The operator runs parameterized Foundry scripts for an explicitly chosen TSV deployment on chain 196. No preproduction or production environment is selected by default.

## Configuration and use

Copy [deployment.example.json](deployment.example.json) to the ignored `script/xlayer/deployment.local.json` or a file outside the repository, replace every placeholder and review the target addresses. The SDK rejects unfilled placeholders. Use the public [address catalogs](../../deployment/README.md) only as references; confirm the intended release and live bindings before use. Historical live operator configurations and session-specific tools belong to `ops/deployment`.

```sh
python3 script/xlayer/operate.py --deployment /path/to/reviewed-deployment.json
```

For a local signer/RPC override file, supply `--env-file /path/to/local.env`; otherwise the ignored local `script/xlayer/.env.xlayer` is used. Its example documents the supported fields. Signing material stays in the local environment and is never written into the deployment JSON.

The menu supports inspection, quote/stock admission, adapter creation and verification, pool initialization, exact-input swaps, LP funding, SBT issuance and Registry/Ledger administration. Inputs and reason codes are collected for each operation. Amounts are raw units unless explicitly described as legal-share WAD.

Read-only operations stop after simulation. Writes simulate first and require the exact confirmation `BROADCAST`. Configuration selection is required even for read-only operations. Direct Foundry scripts remain parameterized tools; their successful compilation does not prove a deployed environment is ready.

## External DEX adapter

The operator targets the unsigned public ABI [ITSVDEXAdapter](../../src/v1/interfaces/external/ITSVDEXAdapter.sol), without a private adapter checkout or backend signing key. Both adapter allowlists, W/U settlement bindings and TokenApprove configuration must match the reviewed deployment. Funding and minimum-output rules are described in [adapter integration](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).
