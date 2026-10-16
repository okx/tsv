# DexRouter thin ABI

`IDexRouter.sol` contains the DAG ERC-20 route structs and `dagSwapTo` entry point used by the X Layer operator. It is intentionally a small ABI interface rather than a vendored router implementation. The deployed X Layer addresses are maintained in `script/xlayer/deployment.json`:

- `DEX_TOKEN_APPROVE`
- `DEX_TOKEN_APPROVE_PROXY`
- `DEX_ROUTER`

The local X Layer TSV operation uses the TokenApprove contract as the user's ERC-20 allowance spender. The proxy's `tokenApprove()` and `isAllowedProxy(dexRouter)` values are checked before simulation. The configured addresses must be reviewed against the intended deployment before any broadcast.

The TSVAdapter source is the `lib/dex-adapters` submodule. Its signed-amount `MoreInfo` is constructed by `script/xlayer/TradeDexRouterTSV.s.sol`; `test/helpers/v1/TSVAdapterFixture.sol` signs local callback payloads using the same ABI and digest fields.

Initialize the source dependency with `git submodule update --init lib/dex-adapters`. Do not store the operation key or `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY` in this folder; both belong in the local `script/xlayer/.env.xlayer` file.
