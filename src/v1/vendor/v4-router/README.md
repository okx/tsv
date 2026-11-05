# TSV V4 Router compatibility source

Source: `lib/v4-periphery/src` at commit `9969eec44cfdf07e24b41de47f40276a58401976`.
Original SPDX headers and relative directory layout are preserved. This 14-file closure supports TSV's proxy Router without changing the upstream Factory or PermissionsAdapter.

Changes are limited to:

- All core imports resolve to TSV's `v4-core/` source, including `IPoolManager.SwapParams`.
- `BaseActionsRouter._unlockCallback`, `PermissionedV4Router._validatePoolKey` and `DeltaResolver._settle` remain `virtual` so TSV can add operation binding and exact settlement checks.
- The permissioned interfaces and flags import the original upstream definitions, preserving shared Solidity type identities and the upstream OZ scope.

The immutable PM/Factory interface, SafeCallback external `onlyPoolManager` gate, action dispatch, swap arithmetic, W authorization and wrap/unwrap behavior retain upstream semantics. TSV constructs only a single swap followed by SETTLE_ALL and TAKE_ALL; no public action execution entry is exposed.

A complete per-file source diff is saved in `docs/artifacts/v4-router-compatibility.diff` as a zero-context unified diff.
