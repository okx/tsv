# TSV V1 当前测试覆盖索引

本矩阵映射可执行测试位置与当前合约能力，不记录未经当前提交验证的通过数。测试命令和 fixture 真实性边界以 [`../test/README.md`](../test/README.md)、Foundry 配置及对应 `.t.sol` 文件为准。

| 源码能力 | 测试位置 | 覆盖类型 |
| --- | --- | --- |
| Registry 组件绑定、W/U/Q 准入和证券容量 | `test/unit/v1/registry/` | 单元状态、角色、地址/metadata 边界、注册与生命周期 |
| SBT 身份权限及安全/全局暂停 | `test/unit/v1/registry/`、`test/integration/local/trading/WrappedPolicy.t.sol` | 权限并集、角色门禁、暂停和操作边界 |
| Ledger quota、usedWad 和 EST 日切 | `test/unit/v1/trading/VolumeLedgerAccounting.t.sol`、`VolumeLedgerSetUsedWad.t.sol`、`VolumeLedgerInvariant.t.sol` | 直接值覆盖、纠正、额度回滚和模型 invariant |
| ERC-8056 legal-share conversion | `test/unit/v1/adapters/ERC8056DirectLegalShareAdapter.t.sol`、Registry/Hook suites | multiplier、精度、取整与执行快照 |
| Router exact-input 与 W/U/Q 结算 | `test/integration/local/trading/WrappedSwap.t.sol`、`WrappedInventory.t.sol`、`WrappedBoundaries.t.sol` | 双向 Swap、完整成交、余额 delta、失败回滚及边界 |
| 外部 Adapter 边界 | `test/unit/v1/operations/DexAdapterCalldata.t.sol`、`test/integration/local/trading/ContractDirectSwap.t.sol` | 本仓库操作器编码和 TSV 路由边界，不覆盖外部实现 |
| LP Manager / Hook | `test/integration/local/deployment/LPHook.t.sol`、`test/unit/v1/deployment/LPLinkedLibraries.t.sol` | 真实本地 PM 的 LP 生命周期，以及 mock PM 下的链接库上下文/入口拒绝 |
| Proxy 初始化、权限和升级 | `test/unit/v1/deployment/`、`test/unit/v1/governance/`、交易初始化测试 | 初始化锁、UUPS 授权、升级前后状态及权限边界 |

## 执行入口

- `make test`：default profile 的 unit + local 测试和 invariant；排除 X Layer 目录。
- `make test-unit` / `make test-local`：分别运行单元和本地集成 profile。
- `make test-governance`、`make test-trading`、`make test-liquidity`、`make test-operations`、`make test-invariants`：按 Makefile selector 聚焦执行。
- `make test-xlayer`：X Layer profile；当前目录没有可执行 `.t.sol` fork suite，不是链上验收。

默认 invariant profile 配置为 64 轮、每轮深度 32、`fail_on_revert = true`。精确 fuzz invocation 参数见 [`foundry.toml`](../foundry.toml)。

## 解释范围

本地 Wrapped 交易测试使用真实本地 PoolManager、Factory/W 和 TSV 代理合约，但 U/Q、issuer checker、multiplier source、SBT 等依赖包含行为替身。部分 unit tests 直接调用 Ledger/Hook consumer 入口。LP 链接库测试中 PoolManager 为 mock，不等同于真实资金集成。

这些套件不证明目标链地址/角色配置、生产 SBT、发行方 token、quote 精确转账或强退收款行为已验收。对税费/rebase/恶意 receiver 等非标准 Token 行为的安全结论不能由当前 local tests 推出。任何测试通过数和 CI 状态应指向具体 commit/pipeline；不要把归档日志中的计数写成当前结果。
