# 合约测试架构

本文说明当前 Foundry 测试的组织方式、覆盖范围和运行入口。测试断言以仓库当前合约实现为准；历史功能已移除时，不应通过恢复旧测试来定义当前行为。

## 测试分层

| 层级 | 位置 | 内容 | 运行方式 |
| --- | --- | --- | --- |
| 单元测试 | `test/unit/` | Registry、交易账本、部署初始化、权限与升级、Adapter 等合约级行为 | `make test-unit` |
| 本地集成 | `test/integration/local/` | 使用本地 PoolManager 验证 Wrapped Swap、Direct 路由边界、LP Hook 等跨合约流程 | `make test-local` |
| X Layer | `test/integration/xlayer/` | 当前保留部署清单和说明，尚无可执行的 `.t.sol` fork 套件 | `make test-xlayer`（不构成链上验收） |

默认 Foundry profile 执行 `test/` 下测试并排除 X Layer 目录，因此 `make test` 运行单元测试、本地集成和 invariant。`unit`、`local`、`xlayer` profile 可单独选择对应目录。

## 按功能查找测试

| 功能 | 测试位置 | 主要覆盖 |
| --- | --- | --- |
| Registry 准入、配置与生命周期 | `test/unit/v1/registry/` | 组件绑定、Factory 检查、W/U/Q 关系、证券与池状态、tier 快照、converter、角色和暂停边界 |
| 使用量与额度 | `test/unit/v1/trading/VolumeLedger*.t.sol` | 额度写入、使用量更正、共享证券额度、UTC-5 日切、失败回滚与 Ledger invariant |
| Wrapped Swap 与交易策略 | `test/integration/local/trading/Wrapped*.t.sol` | 双向 exact-input 交易、完整成交、滑点和过期边界、余额保留、暂停、授权、重入及升级边界 |
| 外部 Adapter ABI / TSV Direct 边界 | `test/unit/v1/operations/DexAdapterCalldata.t.sol`、`test/integration/local/trading/ContractDirectSwap.t.sol` | 操作器编码、TSV 收款及授权边界；不验证外部实现 |
| LP Hook | `test/integration/local/deployment/LPHook.t.sol` | mint、increase、decrease、collect、burn、NFT 计数、普通操作门禁和授权退出 |
| LP 链接库与初始化 | `test/unit/v1/deployment/` | 代理初始化、链接库调用上下文、权限边界及 delta-funded action 拒绝 |
| 治理、角色与升级 | `test/unit/v1/governance/` | 初始化权限、业务角色、组件升级授权及升级后的状态保留 |
| 适配器换算 | `test/unit/v1/adapters/` | ERC-8056 multiplier、精度缩放、向下取整和输入校验 |

## Fixture 与测试替身

| Fixture / 套件 | 使用真实组件 | 测试替身及边界 |
| --- | --- | --- |
| `FoundationFixture` | Registry、Ledger、Factory、W | Registry 的 Hook/LP 调用身份由测试合约承担；适合验证基础组件交互，不代表真实部署角色配置 |
| `VolumeLedgerFixture` | Ledger 存储、额度和 oracle 授权逻辑 | Hook 身份及池到证券的查询使用 mock；不覆盖真实 Hook/池集成 |
| Wrapped 本地集成 | PoolManager、Factory、W、Registry、Hook、Ledger、Router 代理 | U/Q、发行方 multiplier/checker 和 SBT 使用替身；`V1WrappedLiquiditySeed` 只准备交易流动性 |
| `LPHook` 集成 | PoolManager 与生产 LP/Hook 路径 | LP 生命周期与 Wrapped 交易准备流程分开验证；零流动性 NFT 仍参与 NFT 计数断言 |
| `LPLinkedLibraries` 单元测试 | 被测 LP Manager 与链接库 | PoolManager 使用 mock，用于验证 delegatecall 上下文；不能代替真实 LP 集成 |

共享 fixture 和 mock 用于设置状态或替代外部依赖；它们不是独立测试套件。`Consumers` 中直接注入的 Hook delta 只验证账本转换回调，不代表完成了资金交换。

## 当前行为约定

- `isTradable` 与 `isLPAllowed` 返回池生命周期及证券暂停相关状态；全局暂停由 `isPaused()` 单独暴露。Router、Hook 和 LP 执行入口也会检查全局暂停。
- `setQuota` 不清空 `usedWad`。`setUsedWad` 可下调、归零或设置为高于额度；后续成交执行额度检查，因此不能假设使用量始终单调增加或永远不超过额度。
- 批量额度写入接受空数组、未排序日期和重复日期；重复日期按最后一次写入生效。证券与原因码仍要求非零。
- `tickCount` 统计 NFT 数量，不统计价格 tick 或流动性。全部 decrease 后，零流动性 NFT 仍计数；burn 后才减少。
- 关闭 quote/U 的新池注册不会关闭既有池；证券 relist 不自动恢复旧池；证券换 tier 不会改写既有池保存的 tier 快照。
- Router 使用 exact-input 并要求完整成交；部分成交整体回滚。LP Manager 禁止 `MINT_POSITION_FROM_DELTAS` 与 `INCREASE_LIQUIDITY_FROM_DELTAS` 两种 delta-funded action。
- 获授权 LP 退出可越过证券级 LP 暂停；全局暂停仍会阻止退出。普通 LP 操作和强制退出的门禁应分别理解。

## 运行命令

```sh
make test                 # 默认完整套件：单元、本地集成及 invariant
make test-unit            # 单元测试
make test-local           # 本地集成测试
make test-governance      # 治理测试
make test-trading         # 交易相关单元与本地集成测试
make test-liquidity       # LP / Hook 测试
make test-operations      # Registry 测试
make test-invariants      # Ledger invariant
make test-xlayer          # X Layer profile；当前没有可执行 fork 测试
make check                # 测试目录检查、forge fmt --check 和 git diff --check
make coverage             # coverage profile 汇总
```

普通 fuzz 默认运行 256 次；Ledger invariant 配置为 64 轮、每轮最多 32 步，并启用 `fail_on_revert`。via-IR 首次编译可能较慢。若调整 profile、fuzz 参数或测试路径，请同步更新本说明和 `Makefile`。

## 覆盖范围限制

测试验证仓库中的合约逻辑和本地集成，不证明生产发行方、生产 SBT、多签配置或任一链上部署已经验收。X Layer 目录当前没有可执行 fork 测试；税费代币等非标准 ERC-20 行为也不在 Wrapped 集成的正确性保证范围内。
