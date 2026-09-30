# TSV V1 contracts

The active Solidity implementation is in [`src/v1/`](src/v1/). Start with the [documentation map](docs/README.md), which separates target rules, the current ABI, acceptance tests, implementation status, and dated reviews. TSLAx is one instance of the xStock series. The V1 target accepts only direct ERC-20 settlement: the Tesla pool and its users pay and receive wTSLAx. The canonical local stock fixture is [`ERC8056TestToken`](lib/TestToken/erc8056/ERC8056TestToken.sol), exercised through `ERC8056LegalShareAdapter`; real wTSLAx admission remains gated by issuer and legal evidence. The earlier prototype contracts and prototype-only tests have been removed.

## Layout

```text
src/v1/
  core/        Registry, signed reports, volume ledger, V4 Hook
  periphery/   Swap Router, LP Manager, Receipt, SBT adapter
  adapters/    fixed and dynamic legal shares, issuer Wrapped legacy reference
  governance/  business authority, UUPS authorization, upgrade controls
  deployment/  ERC-1967 proxy and CREATE2 Hook proxy factory
  types/       shared requests, configuration, and report structs
  interfaces/  settlement and legal-share adapter boundaries
test/unit/v1/  V1 contract unit tests
test/integration/local/  real local V4 PoolManager integration tests
test/helpers/v1/  shared issuer token behavior mocks
```

Internal and test imports use the `tsv-v1/` remapping in [`foundry.toml`](foundry.toml), so files can move within these modules without long relative paths.

## Contracts

- `TSVRegistryV1`, `TSVDataInboxV1`, and `TSVVolumeLedgerV1` register assets and pools, accept role-authorized market/volume reports, and currently account for each security's UTC trade-day volume and optional quota. DataInbox reports are submitted directly by addresses holding the corresponding role; no report signature or relayer parameter is accepted. The accounting day is derived on chain from a configurable UTC start offset; no SIP calendar is used. See `docs/CONTRACT_ARCHITECTURE.md` and `docs/IMPLEMENTATION_STATUS_V1.md`.
- `TSVHookV1`, `TSVSwapRouterV1`, `TSVLPManagerV1`, and `TSVReceiptV1` handle one-pool V4 swaps, LP positions, settlement, and original-owner forced exit.
- `StaticLegalShareAdapter` covers fixed-ratio assets; `ERC8056LegalShareAdapter` is the canonical raw-stable UI Multiplier test path; `BackedAutoFeeLegalShareAdapter` is the issuer-formula dynamic candidate for a directly settled Wrapped Currency. `IssuerShareSettlementAdapter` remains a legacy wrapper/settlement reference and negative compatibility coverage, not the V1 user settlement path.
- `TSVSBTAdapterV1` checks `verify` and `paused` separately. The business authority, upgrade timelock, emergency upgrade controller, proxy, and Hook proxy factory provide governance and the reserved Hook address permissions (`0x3FFF`); V1 still returns zero hook deltas.

The current V1 suite uses the real local V4 PoolManager. The local integration suite uses `ERC8056TestToken(STDx)` plus an ordinary ERC-20 quote/failure fixture; SBT and issuer-token transaction paths use behavior mocks pending separate-version builds of the pinned external protocols and a fixed-block X Layer fork. See [implementation status](docs/IMPLEMENTATION_STATUS_V1.md) for the exact coverage and remaining production gates.

## Build and tests

Solidity `0.8.26`, Cancun, and 200 optimizer runs are configured in [`foundry.toml`](foundry.toml). External source lives under `lib/v4-core`, `lib/soul-bound-token-1155`, and `lib/TestToken/backed-token-contract`.

```sh
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary
FOUNDRY_PROFILE=unit forge build --skip test --sizes
```

The current test suite is local. Deployment scripts and fixed-block X Layer tests remain to be implemented. See the [test and acceptance specification](docs/TEST_SPEC_V1.md).

For a structured human review of this V1 candidate, open the offline [manual review workspace](docs/reviews/TSV_V1_MANUAL_REVIEW.html). It includes version capture, `ERC8056TestToken(STDx)` and wTSLAx direct-settlement paths, legacy TSLAx wrapper rejection, the R/D/S/L/G acceptance matrix, findings, and JSON export.
