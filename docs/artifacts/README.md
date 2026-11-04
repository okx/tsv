# Generated ABI and storage-layout snapshots

These JSON files are generated from the current `src/v1/` contracts from Foundry build artifacts. They are source snapshots, not a substitute for the ABI/layout produced by the exact deployment build. Regenerate and review them whenever public contract signatures or proxy storage changes.

```sh
make artifacts        # full build, then regenerate ABI/layout snapshots and source hashes
make artifacts-check  # fail if checked-in snapshots differ from the current build
```

Storage snapshots support review; they do not prove upgrade compatibility. Compare layouts against the actual deployed implementation and the project's upgrade policy. These snapshots also do not record linked library addresses, constructor immutables, compiler metadata, deployed addresses, or target-chain state; preserve those in a release record separately.

`manifest.json` records compiler settings and source/artifact SHA-256 values. Historical production deployment ABIs are archived under `deployment/prod/contracts/` on `ops/deployment` at commit `298ee17bd657a7fb57106b19c3a0a24628226320`; they are not distributed with main or overwritten by this command.

Storage snapshots omit AST IDs and normalize compiler-assigned struct/enum/contract/value-type IDs so incremental compilation does not create irrelevant drift. Slot, offset, member, encoding, byte-size and type-shape information is retained.
