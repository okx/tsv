# Test token sources

This directory keeps third-party token implementations used as development and fork-test references. External source repositories are pinned as Git submodules; do not copy mutable upstream branches into this directory.

## Tesla xStock on X Layer

The two addresses in the original links were associated with the wrong token types. The current OKLink pages identify them as:

| Token | Symbol | X Layer address | Source |
|---|---|---|---|
| Tesla xStock | `TSLAx` | `0x8ad3c73f833d3f9a523ab01476625f269aeb7cf0` | [OKLink token page](https://www.oklink.com/zh-hans/x-layer/evm/token/0x8ad3c73f833d3f9a523ab01476625f269aeb7cf0) |
| Wrapped Tesla xStock | `wTSLAx` | `0xc3fdbe3a68ee5de461d30415a8165cf9aefe1171` | [OKLink token page](https://www.oklink.com/zh-hans/x-layer/evm/token/0xc3fdbe3a68ee5de461d30415a8165cf9aefe1171) |

Both are on X Layer mainnet (chain ID `196`). `TSLAx` is the underlying Backed token; `wTSLAx` is the DeFi-oriented wrapper. The contract sources are managed in [`backed-token-contract`](backed-token-contract), pinned at commit `35859e8c755698eeeef96ef15beef5fcd6b978cc`:

- Underlying token implementation: `contracts/BackedAutoFeeTokenImplementation.sol` and its base `contracts/BackedTokenImplementation.sol`.
- Wrapper implementation: `contracts/WrappedBackedTokenImplementation.sol`.

The upstream repository is published by Backed Finance under the MIT license. The pinned source is a code reference; this mapping alone does not prove that either live proxy currently uses this exact implementation. Before relying on implementation details in a fork test or deployment, compare each live proxy's implementation and code hash with this pinned source.

The machine-readable address map is [`addresses/xlayer-mainnet.json`](addresses/xlayer-mainnet.json).

## Securitize SECZ on Avalanche C-Chain

| Token | Symbol | Chain ID | Proxy address | Implementation |
|---|---|---:|---|---|
| Securitize Corp. | `SECZ` | `43114` | `0x5954fF4099ac47C4d6D098A9216f3278BB8C9506` | `DSToken` at `0x18295407744efA5c3FeD0318c1F37aBe8a5e2d45` |

The source is pinned in [`securitize-dstoken`](securitize-dstoken) at commit `d7cf3858c371def66e5b37ed0949aa991d0a0234` from [Securitize's DSToken repository](https://github.com/securitize-io/dstoken). The verified `DSToken` and its 19 non-OpenZeppelin imported source files match that revision after ignoring formatting and comments. Snowtrace identifies the SECZ address as an ERC-1967 proxy and reports the implementation address above; see [`addresses/secz-avalanche.json`](addresses/secz-avalanche.json).

This is a source reference for admission and compliance-token testing. `DSToken` depends on Securitize DS services, including registry, compliance, lock-manager, and rebasing-provider contracts, so using it in local deployment tests requires the corresponding service setup. The pinned reference source does not by itself prove what implementation a live proxy uses after a later upgrade.

## ERC-8056 本地测试代币

| 代币 | 说明 | 来源 |
|---|---|---|
| [`ERC8056TestToken`](erc8056/ERC8056TestToken.sol) | 本地 Solidity 测试实现，供 TSV 开发和集成测试使用；没有部署地址 | [ERC-8056 规范与参考实现](https://eips.ethereum.org/EIPS/eip-8056) |

ERC-8056 是代币接口标准，不是某个特定代币或源码仓库。这个本地测试代币按规范的参考行为实现：ERC-20 的 `balanceOf`、`totalSupply`、`transfer` 和 `transferFrom` 使用 raw 数量；独立的 UI multiplier 与换算/余额接口只用于显示。multiplier 更新由 owner 排期，并公开待生效值和生效时间。合约另含仅供测试准备使用的 owner mint，因此不是生产实现，也不能证明任何已部署代币符合准入条件。

该 EIP 目前仍为 Draft。通过本地测试代币的接口检查，不能证明发行方 multiplier 是经批准的法律股数公式；该标准本身也不保证转账两侧余额变化精确或发行方权限安全。此合约没有部署，因此没有链上地址映射。

当前本地 TSV 集成测试位于 [test/integration/local/trading/](../../test/integration/local/trading/)，使用可配置的发行方、Underlying 和 SBT 测试替身。测试结果不代表任何真实发行方资产已通过准入。

生产资产的法律股数换算与准入边界见 [Token 准入标准](../../docs/TOKEN_ADMISSION_STANDARD_V1.md) 和 [ERC8056DirectLegalShareAdapter](../../src/v1/adapters/ERC8056DirectLegalShareAdapter.sol)。
