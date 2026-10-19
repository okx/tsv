# XLayer TSV interactive operator

`operate.py` is the main entry point for XLayer Mainnet (`chainId 196`). It asks which operation to perform, collects that operation's parameters, runs a Forge simulation, then asks for the exact word `BROADCAST` before sending any write transactions.

## Start

Create the local environment file once, put your operator wallet key in it, then start the menu from the repository root:

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
# Edit script/xlayer/.env.xlayer and set XLAYER_PRIVATE_KEY.
# DexRouter + TSVAdapter swaps also need TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY.
python3 script/xlayer/operate.py
```

The operator automatically reads keys from `script/xlayer/.env.xlayer`. The X Layer Mainnet RPC and public deployment/inventory values are fixed in [`deployment.json`](deployment.json); an optional `XLAYER_RPC_URL` in the local environment can override the public default. `XLAYER_PRIVATE_KEY` is the operation wallet. `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` is only needed for DexRouter + TSVAdapter swaps and must match the deployed Adapter's `AUTH_SIGNER()` address.

The menu delegates Forge simulation and explicit broadcast to the repository-native Python SDK in [`sdk/python`](../../sdk/python/README.md). The menu remains the interactive parameter collector; the SDK owns the shared script allowlist, secret-safe subprocess handling, and confirmation gate.

Keep `.env.xlayer` local. Do not paste its contents into chat or commit it. Use a wallet with only the roles and funds needed for the operation. The deployment manifest says `sourceVerification=false` and includes smoke assets; confirm the target contracts before broadcasting.

## Menu

1. **Inspect U/W/Q and Security lists.** Defaults come from the deployment inventory; edit the counts or addresses at the prompts.
2. **Inspect one PoolKey.** Enter sorted currency addresses, fee, tick spacing, and hook.
3. **Register QuoteToken list.** Enter the list size, then each Q address and its own `reasonCode`. No Q registration address is preset in the environment.
4. **Create stock adapters.** For each stock U, enter the initial W owner and the stock's actual Allowlist Checker. The script creates the ERC8056 Legal-share Adapter and W via the Registry's Factory, then prints their addresses. Ask the token issuer to allowlist W before continuing.
5. **Verify W with the Factory.** Enter each new W/U and a raw-unit verification deposit. The deposit moves from the signer to W, so the signer needs enough U and the issuer must have allowlisted W.
6. **Register stock list.** Enter each Factory-verified W, its U, new Security ID, Legal-share Adapter, tier, and its own registration `reasonCode`. Existing smoke W/Security ID entries are already used and must not be reused.
7. **Initialize W/Q pool list.** Enter sorted currencies, fee, tick spacing, hook, and initial `sqrtPriceX96` for every pool. The current ABI has no reason-code argument for pool initialization.
8. **Execute one swap.** Enter one exact PoolKey, direction, raw input amount, minimum raw output, and deadline. The pool must already be initialized and tradable; the signer needs `SWAP_ALLOWED` and enough input balance.
9. **Registry/Router administration.** Select an action. The menu can grant or revoke `POOL_CREATOR_ROLE` and `VOLUME_ORACLE_ROLE`, or grant `SYMBOL_ADMIN_ROLE`; each reason-coded Registry action asks for its own `reasonCode`.
10. **Volume Ledger administration.** Select `SET_QUOTA` or `SET_USED_WAD`; each operation asks for its own `reasonCode`. Amounts use legal-share WAD and the signer needs `VOLUME_ORACLE_ROLE`.
11. **Deploy a Legal-share Adapter for an existing U.** This is for a Factory-verified W that already exists and avoids creating a second W.
12. **Issue the configured TSV SBT to the current operator.** The script checks the Registry SBT binding, `SWAP|LP` flags, issuer role, and existing credential first.
13. **Add liquidity to an initialized W/Q pool.** Enter the PoolKey and each currency's maximum raw input; the script resolves W deposits to the corresponding U and selects a tick range around the current pool tick.
14. **Trade through DexRouter + TSVAdapter.** Enter buy/sell direction, signed Adapter address, PoolKey, W/U, raw input, minimum output, quoted multiplier, sale nonce (only for sells), and transaction validity period. The route is single-hop; participant, Adapter `to`, and receiver default to the operator wallet. If the TokenApprove allowance is insufficient, the broadcast includes an exact-amount approval before the swap. Approval and swap are separate transactions, so a failed swap can leave that exact allowance in TokenApprove.

Read-only menu items 1 and 2 stop after simulation. Write items simulate first. If simulation succeeds, type `BROADCAST` exactly to rerun the operation with Forge's `--broadcast`; any other response exits without broadcasting.

## Important values

- The mainnet RPC, deployment addresses, and public inspection inventory are in [`deployment.json`](deployment.json). The default RPC is `https://rpc.xlayer.tech`, listed in the [official X Layer RPC documentation](https://web3.okx.com/onchainos/dev-docs/xlayer/developer/rpc-endpoints/rpc-endpoints).
- U, W, and Q are lists. The manifest's known U/W/Q entries are inventory defaults; they do not imply every asset is appropriate for a new production operation.
- `TSV_REASON_CODE` is not used. Each reason-coded operation prompts separately, and every row in a list has its own reason.
- Amounts are raw token units unless a prompt explicitly says legal-share WAD.
- Lower-level Forge scripts remain available in this folder, but the interactive operator is the supported entry point for collecting parameters and requiring an explicit broadcast confirmation.

## DexRouter adapter path

The X Layer `TSVAdapter` follows the signed-amount implementation pinned by `lib/dex-adapters`. Only stock sales require a `MoreInfo` signature, binding the exact input amount, PoolKey, direction, multiplier, participant, allowed caller, nonce, and deadline; recipient is not signed. Purchases require no auth signer key and encode zero/empty authorization fields. The request input amount remains positive for DexRouter funding; purchases swap the Adapter's live Q balance. Buys pre-transfer Q to the Adapter; sells pre-transfer U directly to W. The SDK simulates and can broadcast a single-hop `dagSwapTo` request. Both the Adapter's DexRouter allowlist and the TSV Router's Adapter allowlist must be configured. The old Adapter is immutable and cannot gain the new `AUTH_SIGNER` support by changing environment values; deploy the signed version and update `TSV_DEX_ADAPTER` before using menu item 14. See [`EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md`](../../docs/EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md).
