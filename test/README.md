# 测试目录与维护方式

当前版本使用 W/U/Q Registry 与单池 Wrapped Swap。最新执行证据与 ABI/layout 见 [Registry 与 Wrapped Swap](../docs/PERMISSIONED_REGISTRY_V1.md)；29 个历史 DIRECT/LP/DEX 文件按 [延期清单](./DEFERRED_PERMISSIONED.md)保留，不参与编译、不计为当前通过。

## 可执行套件

| 范围 | 文件 / 验证目标 |
| --- | --- |
| Wrapped 四条资金路径 | `integration/local/trading/WrappedSwap.t.sol`：U↔Q exact-in/exact-out、事件和 Ledger 一次计量、验证保证金、共享额度、LP/协议费、转账与库存故障、合约钱包、Adapter 拒绝。 |
| Wrapped U 余额基线 | `integration/local/trading/WrappedInventory.t.sol`：普通转入后四条路径保持 PM/Router 既有 U 余额不变；少付或交易中余额变化时整体回滚，并可重试。 |
| Wrapped 策略与身份 | `integration/local/trading/WrappedPolicy.t.sol`：owner/checker/wrapper/Hook/SBT/状态拒绝，支付回调变更导致整笔回滚，原始用户从首次资格读取可见，U 授权 Router，不可变 PM/R 初始化及升级。 |
| Wrapped 成交与回调边界 | `integration/local/trading/WrappedBoundaries.t.sol`：部分成交、exact-out 不足/超额拒绝、滑点、过期/畸形请求、单次回调与重入/重放、settle 支付一致性、18/6 精度与非 1:1 法律计股。 |
| Registry 与 Hook/Ledger 消费者 | `unit/v1/registry/`：真实 Factory/W、准入和三表、环境绑定、checker、状态/版本、owner/exitAdmin、U canonical Adapter、报价隔离；消费者注入 delta 仅用于计量验证。 |
| 治理、部署与升级 | `unit/v1/governance/`、`unit/v1/deployment/`：六代理/Anchor、角色、冻结/恢复、批量升级、CREATE2 Hook 地址及状态模型。 |
| 报告、额度与日历 | `unit/v1/reports/`：ADTV/quota/市场报告/拆并股、去重和更正、UTC 日切、随机运营模型。 |
| 单元边界与换算 | `unit/v1/trading/`、`unit/v1/adapters/`：初始化、额度、计量及法律股数接口。 |

新 `WrappedSwapFixture` 使用真实 PM、固定上游原版 Factory/PermissionsAdapter，以及真实 Registry/Hook/Ledger/Inbox/Router 代理。U/Q、issuer 换算和 SBT 为行为替身。test-only `V1WrappedLiquiditySeed` 绑定 Registry/Hook context 并注入真实资金；它的 wrapper 授权仅属于测试，不是生产 LP 交付。

成功交易均经过真实 PM 与 W。畸形/重复回调、settle 返回值错误、exact-out 超额返回的少量用例使用 VM 故障注入，断言拒绝、完整回滚与后续成功重试；不能把故障注入当作真实成功结算证据。gas 日志仅为本地 fixture 的四条路径观测，不代表生产 issuer 或目标链上限。

## 运行与维护

```sh
forge test -vv
forge test --match-path 'test/integration/local/trading/Wrapped*.t.sol' -vv
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary
forge build src --sizes
python3 script/check-test-layout.py
forge fmt --check
git diff --check
```

默认普通 fuzz 每项 256 次，治理/运营 invariant 每项 64 轮 × 32 步。完整 viaIR 首次编译耗时较长，后续复用缓存；旧交易/LP invariant 和 X Layer DEX fork 已延期，旧 make/fork 文档中的成功数量不能用于本批验收。

fixture 只准备环境和提供快照/断言工具，不包含 `test*` / `invariant*`；可执行套件只继承 fixture，避免继承另一测试套件导致重复执行。新用例按业务行为选择目录，一个用例聚焦一个成功或失败原因。先准备外部 getter、请求参数与新合约，再设置 prank/expectRevert，避免准备阶段消耗下一次调用的作弊码；跨时间操作使用当前区块时间。失败应比较资金、PM 状态、策略版本与 Ledger，并在修正条件后验证可以重试。

`GovernorExecutor` 只证明合约账户调用，不代表生产 Safe 门槛、模块或账户恢复已验证。真实候选实现仍需检查布局、升级身份与迁移参数；生产发行方资产、SBT、LP、目标链 gas、部署与报告服务证据另行验收。
