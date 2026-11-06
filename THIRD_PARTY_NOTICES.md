# Third-party components

The first-party BUSL-1.1 and MIT licenses do not replace third-party licenses.

| Component | Source/version | License and retained notices |
| --- | --- | --- |
| Vendored Uniswap v4-core | lib/v4-core | File-specific BUSL-1.1/MIT; licenses/ and copyright headers retained |
| Uniswap v4-periphery | Public gitlink in .gitmodules | MIT and file-specific notices; nested dependencies retain their licenses |
| OpenZeppelin | Soldeer 5.5.0 and pinned upstream copies | MIT notices retained |
| ERC721 compatibility base | src/v1/vendor/permissionedPools/base/ERC721.sol, OZ 5.0.2 dbb6104c | MIT; documented internal-field modification retained |
| Permissioned-pool and router vendor code | src/v1/vendor | Existing per-file notices retained; do not infer BUSL from the root license |
| Solmate ERC20 / SafeTransferLib | Pinned v4-core dependency | AGPL-3.0-only file headers and license retained; still used by PermissionsAdapter |
| Forge standard library | lib/v4-core/lib/forge-std | MIT/Apache-2.0 notices retained |
| Public issuer test contracts | lib/TestToken/backed-token-contract and securitize-dstoken | Their original licenses remain applicable |
| Test utilities with permissive file headers | lib/TestToken/erc8056 and securitize-disperse | Existing CC0-1.0 / Apache-2.0 headers retained |

Finalize license compatibility and any required authorizations before distribution. External SBT, DEX adapters and issuer checkers are integrated through contract addresses and ABI boundaries; their implementations are not relicensed or bundled as private dependencies.

Solmate dependencies remain in the issuer PermissionsAdapter path. Their AGPL-3.0-only notices remain applicable; the first-party licenses do not grant alternate terms for them. Independently sourced development skills are maintained on the operations branch rather than redistributed as TSV first-party code.
