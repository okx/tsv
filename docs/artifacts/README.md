# Generated ABI and storage-layout snapshots

These JSON files are generated from the current `src/v1/` contracts with Foundry `forge inspect`. They are source snapshots, not a substitute for the ABI/layout produced by the exact deployment build. Regenerate and review them whenever public contract signatures or proxy storage changes.

```sh
forge inspect src/v1/core/TSVRegistryV1.sol:TSVRegistryV1 abi --json > docs/artifacts/TSVRegistryV1.abi.json
forge inspect src/v1/core/TSVRegistryV1.sol:TSVRegistryV1 storageLayout --json > docs/artifacts/TSVRegistryV1.storage-layout.json
forge inspect src/v1/core/TSVVolumeLedgerV1.sol:TSVVolumeLedgerV1 abi --json > docs/artifacts/TSVVolumeLedgerV1.abi.json
forge inspect src/v1/core/TSVVolumeLedgerV1.sol:TSVVolumeLedgerV1 storageLayout --json > docs/artifacts/TSVVolumeLedgerV1.storage-layout.json
forge inspect src/v1/core/TSVHookV1.sol:TSVHookV1 abi --json > docs/artifacts/TSVHookV1.abi.json
forge inspect src/v1/core/TSVHookV1.sol:TSVHookV1 storageLayout --json > docs/artifacts/TSVHookV1.storage-layout.json
forge inspect src/v1/periphery/TSVSwapRouterV1.sol:TSVSwapRouterV1 abi --json > docs/artifacts/TSVSwapRouterV1.abi.json
forge inspect src/v1/periphery/TSVSwapRouterV1.sol:TSVSwapRouterV1 storageLayout --json > docs/artifacts/TSVSwapRouterV1.storage-layout.json
forge inspect src/v1/periphery/TSVLPManagerV1.sol:TSVLPManagerV1 abi --json > docs/artifacts/TSVLPManagerV1.abi.json
forge inspect src/v1/periphery/TSVLPManagerV1.sol:TSVLPManagerV1 storageLayout --json > docs/artifacts/TSVLPManagerV1.storage-layout.json
forge inspect src/v1/interfaces/ITSVPermissionedRegistry.sol:ITSVPermissionedRegistry abi --json > docs/artifacts/ITSVPermissionedRegistry.abi.json
```

Storage snapshots support review; they do not prove upgrade compatibility. Compare layouts against the actual deployed implementation and the project's upgrade policy. These snapshots also do not record linked library addresses, constructor immutables, compiler metadata, deployed addresses, or target-chain state; preserve those in a release record separately.
