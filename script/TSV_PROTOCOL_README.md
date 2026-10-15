# TSV / AA / SBT protocol operations

Run from the TSV repository root. The only address/config source is
`./dployment/XLAYER_MAINNET_SMOKE_20261014.json`. Signing uses `PK` from the local
ignored `.env` or the process environment. Never put private keys in the JSON.

`configuration.preserveProxies` is true for this deployment. `bootstrap` creates
AA infrastructure/account, issues the configured real SBT, and migrates SBT wiring
through the existing Registry proxy. All five TSV proxy addresses remain unchanged.
The Registry migration implementation adds no storage variables, disables the
previous issuer's identity permissions and permits the configured token ID.
The migration is a one-time `reinitializer(2)` and requires the existing default
admin and upgrade admin. The issuer must already have the SBT issuer role.

## Prepare AA artifacts

Use the private `okx-smart-wallet-dev` reference at commit
`78e2fcaa82c628f2ca6540f797b20d7bfe170c50` from `chore/scripts`:

```sh
# In the reference checkout: initialize its pinned submodules first.
git submodule update --init --recursive
# From TSV root:
python3 script/tsv-protocol.py prepare-aa --aa-repo /path/to/okx-smart-wallet-dev
```

This compiles SmartWalletEntry and SmartWalletFactory locally with metadata disabled,
stores creation bytecode only in ignored `dployment/aa/`, and records its hashes.
It uses one ECDSA owner derived from PK; it does not add the sample Passkey owner.
Set `aa.implementation` and `aa.factory` to zero to deploy new infrastructure;
existing instances may be provided through the JSON. Account salt is also in JSON.

## Existing deployment: preserve proxies and run AA operations

Commands default to a fork simulation. Simulation restores the JSON on exit.
Add `--broadcast` before the action to send mainnet transactions.

```sh
python3 script/tsv-protocol.py verify
python3 script/tsv-protocol.py bootstrap
python3 script/tsv-protocol.py --broadcast bootstrap

# Registry already upgraded by bootstrap; update the other four implementations.
python3 script/tsv-protocol.py --broadcast upgrade ledger
python3 script/tsv-protocol.py --broadcast upgrade router
python3 script/tsv-protocol.py --broadcast upgrade lpManager
python3 script/tsv-protocol.py --broadcast upgrade hook

# Raw token units: 0.01 mock 8056 (18 decimals), 0.011 USDT0 (6 decimals).
python3 script/tsv-protocol.py --broadcast fund-aa 10000000000000000 11000

# Entire AA test cycle; bounded amounts/minimum outputs are read from .smoke.
python3 script/tsv-protocol.py smoke
python3 script/tsv-protocol.py --broadcast smoke
```

`smoke` adds a position owned by the AA wallet, swaps, collects fees and removes
all liquidity. Each AA operation is a separate EntryPoint.handleOps transaction;
the EOA submits the operation, but the AA wallet is the token payer, participant,
position owner and recipient. ERC-20 approvals target the Router or LP Manager
proxy directly, with bounded amounts. Permit2 allowances are not used for these
TSV payments. Gas is funded by an explicit EntryPoint deposit from the signer.

Individual actions:

```sh
python3 script/tsv-protocol.py --broadcast swap quote-to-underlying 1000 983000000000000
python3 script/tsv-protocol.py --broadcast swap underlying-to-quote 500000000000000 490
python3 script/tsv-protocol.py --broadcast add 10000000000000000 10000 1
python3 script/tsv-protocol.py --broadcast collect POSITION_ID
python3 script/tsv-protocol.py --broadcast remove POSITION_ID AMOUNT0_MIN_RAW AMOUNT1_MIN_RAW
python3 script/tsv-protocol.py --broadcast issue-sbt
python3 script/tsv-protocol.py --broadcast migrate-sbt
```

Collect uses a zero-liquidity decrease followed by TAKE_PAIR. Remove requires
nonzero output minima and sends proceeds directly to the AA wallet. Liquidity
calculation uses the current onchain pool price and aligned ticks, not the initial
price. `.pool.rangeSpacings` controls the range width.

## Upgrades

```sh
python3 script/tsv-protocol.py --broadcast upgrade router
python3 script/tsv-protocol.py --broadcast upgrade registry --migration 0x...
python3 script/tsv-protocol.py --broadcast upgrade-all
```

Upgrade checks the old EIP-1967 implementation against the JSON, admin role,
Registry pause state, and core bindings. The new Router preserves PoolManager and
PermissionsAdapterFactory immutables. The new LP Manager copies all immutable
integration settings from the existing implementation. No proxy is recreated.
`upgrade-all` uses empty migration calldata and is suitable only for compatible
layouts. For future layout changes compare storage layouts and supply the reviewed
migration calldata for the affected component. The supplied SBT migration has
identical Registry storage layout and retains all proxy/factory addresses.

## First deployment on an empty topology

Set `configuration.preserveProxies=false` and all five `.proxies` entries to zero.
Configure existing Uniswap dependencies in `.dependencies`, real SBT in `.sbt`,
underlying/quote assets, issuer checker and the initial price in JSON.

```sh
python3 script/tsv-protocol.py --broadcast deploy
```

`deploy` creates a NEW PermissionsAdapterFactory and HookProxyFactory, legal-share
adapter and verified permissioned wrapper, all five implementation/proxy pairs,
then saves addresses to JSON and reads them back before binding/configuring them.
Hook deployment mines the required low address bits. Asset registration, SBT flags,
quota and pool initialization are included. PoolManager, Permit2, WOKB, descriptor,
issuer checker and real SBT are external prerequisites; they are not silently
replaced. New factories are not substituted into an existing topology because its
Router and Registry dependencies are fixed.

For a fresh mock underlying, set `configuration.deployMockUnderlying=true` for
fresh bootstrap, or run `deploy-mock`. Standalone fresh `deploy` uses the token
address already recorded in the JSON.

## Confirmation and source handling

Use the Python entry point for broadcast. It archives the preceding manifest in
ignored `dployment/history/`, checks every mined receipt and every emitted
UserOperationEvent.success, verifies bindings/implementation slots, and then marks
the JSON confirmed. An interrupted/failed broadcast remains pending, so subsequent
trading/upgrade actions cannot consume an unconfirmed manifest. Inspect receipts
and restore/repair the manifest before resuming a partial broadcast; never rerun
blindly. The wrapper also compares protocol proxy addresses before/after actions.

There are no source verification, source upload, or publication steps. Both TSV
and AA deployment commands disable Solidity metadata. `sourceVerification` remains
false. ABI inputs, signed UserOperations and keys are not copied into the manifest;
only public addresses, operation hashes and receipt results are saved, including
failed UserOperations. An outer receipt with success does not mean the AA call succeeded.

## Offline signing with a separate RPC transport

`tsv-offline-transaction.py` signs a transaction locally with explicit EOA nonce,
chain 196, bounded gas and fees. `tsv-aa-offline.py` encodes and signs add, swap,
reverse, collect or remove with chain state supplied by the operator. Both read
addresses from the same relative JSON. Their stdout contains signed data: capture
it directly into the RPC broadcast client; do not log it or save it in the manifest.
Before broadcasting, verify the current EOA and EntryPoint nonce, balances,
SBT permissions, pool state and position ownership; compare the encoded user-op
hash with EntryPoint.getUserOpHash. After mining, check UserOperationEvent.success
and read back the resulting balances and position liquidity. These helpers do
not automatically broadcast or mark the deployment confirmed.

### Completed mainnet AA cycle (2026-10-14)

The new AA wallet owns position 2. Add, forward swap, reverse swap, collect and
full remove all emitted successful UserOperationEvents; remaining liquidity is 0.
The first forward swap reverted on its output minimum and is retained under
`operations.receipts`. A retry succeeded after updating the minimum using the
observed pool output. Current transaction hashes are in `transactions`; the
earlier EOA smoke test is preserved in `historicalSmoke`.
