# TSV V1 contracts

TSV V1 is a set of Uniswap V4 contracts for permissioned single-pool swaps, liquidity positions, security-level volume controls, and upgrade governance. The active Solidity implementation is in [src/v1/](src/v1/).

Start with the [three-systems overview](docs/SYSTEMS_OVERVIEW.md), then use the [documentation map](docs/README.md) to find the authoritative specification for a topic. The overview explains trade, operations, and governance flows; the other documents own admission policy, ABI and algorithms, acceptance tests, implementation status, and deployment steps.

## Repository layout

```text
src/v1/
  core/        Registry, reports, volume ledger, V4 Hook
  periphery/   Swap Router and LP Manager with Receipt ERC-721
  adapters/    legal-share conversion adapters
  libraries/   settlement, share math, trade-day and report validation
  legacy/      isolated historical settlement reference
  governance/  business authority and upgrade controls
  deployment/  ERC-1967 proxy and CREATE2 Hook factory
  types/       shared requests, configuration, and reports
  interfaces/  adapter and protocol boundaries
test/unit/v1/            unit tests
test/integration/local/   local V4 PoolManager integration tests
test/helpers/v1/          shared issuer-token fixtures
script/                   staged governance and core deployment scripts
```

Internal and test imports use the tsv-v1 remapping in [foundry.toml](foundry.toml).

## Build and tests

Solidity 0.8.26, Cancun, 200 optimizer runs, and via-IR compilation are configured in [foundry.toml](foundry.toml). External source is under lib/v4-core, lib/soul-bound-token-1155, and lib/TestToken/backed-token-contract.

```sh
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary
FOUNDRY_PROFILE=unit forge build --skip test --sizes
```

Use the [test specification](docs/TEST_SPEC_V1.md) for target acceptance criteria and [implementation status](docs/IMPLEMENTATION_STATUS_V1.md) for current evidence and production gates. No production deployment has been broadcast; the fresh deployment sequence and required manifest inputs are in the [deployment checklist](docs/DEPLOYMENT_CHECKLIST_V1.md).

For a dated review snapshot, see the [offline manual review workspace](docs/reviews/TSV_V1_MANUAL_REVIEW.html) and the [review archive](docs/reviews/).
