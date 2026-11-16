# Source distribution

This repository contains TSV contracts, tests, parameterized scripts, the Python SDK, technical documentation and environment address catalogs. The public-tree check is part of `make check`; it validates first-party document references and dependency URLs while excluding complete upstream dependencies.

## Configuration

The CLI requires an explicit deployment JSON and the SDK requires `deployment_file`. The [template](../script/xlayer/deployment.example.json) contains placeholders rather than a live target. Address catalogs do not automatically become execution configurations. Simulate each intended operation and verify its target before broadcasting.

## Licensing

The TSV V1 core contracts use BUSL-1.1, a source-available license that is not an Open Source license during its BUSL period. See [licensing status](../LICENSING.md) for scope and Parameters. Third-party licenses and earlier grants remain unchanged; the [component notices](../THIRD_PARTY_NOTICES.md) include retained AGPL dependencies. Source distribution does not settle any outstanding license compatibility or redistribution review.

## Release references

Use a fixed release commit and its corresponding ABI, dependency versions and compiler settings. Check the target chain's implementation slots and configuration separately; source publication is not evidence of deployment or business acceptance.
