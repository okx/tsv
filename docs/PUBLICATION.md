# Source publication boundaries

The public tree contains TSV contracts, tests, generic parameterized scripts, the SDK, public technical documentation and address catalogs. It excludes internal development skills, confidential source excerpts, operator records, live default execution configurations and session-specific deployment tools. The public-tree check is part of `make check`; it covers TSV-authored documents under lib/ as well as README, docs, script and sdk, while excluding complete upstream dependencies.

The source versions removed or sanitized in the 2026-11-04 cleanup are archived on `ops/deployment` at commit `73e18cc0a0c49932fe78bcc12a259e4e8f05c25e`. That branch contains the archive index at `docs/operations/PUBLICATION_ARCHIVE_20261104.md`. These internal archive paths are not dependencies of main or publication links to be followed by external readers.

## Configuration

The CLI requires an explicit deployment JSON and the SDK requires `deployment_file`. The [template](../script/xlayer/deployment.example.json) contains placeholders rather than a live target. Reviewed address catalogs do not automatically become execution configurations. The ordinary simulation and explicit broadcast confirmation remain required.

## License status

The TSV V1 core contracts use BUSL-1.1, a source-available license that is not an Open Source license during its BUSL period; other first-party code uses MIT. See [licensing status](../LICENSING.md) for the scope and Parameters. Third-party licenses and earlier grants remain unchanged; the [component notices](../THIRD_PARTY_NOTICES.md) explicitly include retained AGPL dependencies. Source cleanup does not settle any outstanding license compatibility or redistribution review.

## Deferred history work

This cleanup changes only the current tree. It neither rewrites history nor changes repository visibility. Removed records remain reachable in internal history and on the operations branch. A future public export must separately decide what history and refs to include; that work is intentionally deferred.
