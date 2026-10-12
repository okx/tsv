# 当前合约测试与迁移记录

测试以当前合约实现为准。本次从历史版本恢复仍有效的业务场景，重写已变更接口的断言；已取消的机制保持移除。测试修复最初基于 `b8fb7a0fd32b2cd4482710ffb91072cb29d1cf23`，本 MR 对齐到 `643fb651020cc87fdcc304963d48aa7aeada11e2`，保留主分支中的非零 `reasonCode` 校验及已弃用 delta actions 拒绝逻辑。

## 可执行套件

| 范围 | 文件与验证目标 |
| --- | --- |
| Registry 准入与配置 | `unit/v1/registry/Admission.t.sol`、`Environment.t.sol`、`FactoryChecker.t.sol`、`Configuration.t.sol`：一次性四组件绑定、Factory 验证与 TSV 准入分离、W/U/Q 隔离、同 U 多 W 的 canonical converter、精度、tier 容量、发行方 owner/checker 轮换、SBT 持证与权限并集。 |
| Registry 状态与权限 | `unit/v1/registry/Lifecycle.t.sol`、`Pauses.t.sol`、`PauseBoundaries.t.sol`、`Permissions.t.sol`：LIST/PAUSE/DELIST、证券与池计数、历史池及 tier 快照、最终安全暂停模式、全局暂停标志、角色授予与撤销、固定 LP 调用者。 |
| 计股转换及回调 | `unit/v1/registry/AdapterChanges.t.sol`、`Consumers.t.sol`：替换 converter 后保留历史使用量、实际股票 delta 转换、`int128.min`、必填 multiplier 快照、零股数与非法回调拒绝、当前 `VolumeUsed` 事件。此处的 delta 是单元测试注入值。 |
| 直接额度与使用量更正 | `unit/v1/trading/VolumeLedgerAccounting.t.sol`、`VolumeLedgerSetUsedWad.t.sol`：oracle 角色、非零证券及原因码、任意日批量额度、重复日期最后写入生效、保留已用量、更正可归零或超过额度、跨池共享额度、失败回滚、multicall 原子性。 |
| 固定 EST 与状态序列 | `unit/v1/trading/VolumeLedgerAccounting.t.sol`、`VolumeLedgerInvariant.t.sol`：05:00 UTC 日切、全年固定 UTC-5、两证券/四池/三日的额度与更正模型、oracle 撤销、正常/超额成交及失败 multicall。 |
| 双向交易与余额 | `integration/local/trading/WrappedSwap.t.sol`、`WrappedInventory.t.sol`：U↔Q exact-input、完整成交、一次记账、W 供给与 PM 持有量一致、验证 dust/捐赠余额保留、共享额度、协议费提取、false-return 回滚与 no-return 支持、合约钱包、Adapter 白名单。 |
| 交易边界与策略 | `integration/local/trading/WrappedBoundaries.t.sol`、`WrappedPolicy.t.sol`：滑点、部分成交回滚、过期及非法请求、真实 PM 回调、重入锁、交易期间禁止升级、混合精度、发行方资格与 SBT、暂停、U 授权、Router immutable 依赖。 |
| DEX Adapter | `integration/local/trading/DexAdapter.t.sol`：真实上游 TSVAdapter、认证 trailer、签名重放/过期、签入 `expectedMultiplier` 与篡改/过期快照拒绝、双向收付、输出捐赠保留、独立收款人、部分成交整体回滚及 nonce/授权恢复。 |
| 真实 LP 与 Hook | `integration/local/deployment/LPHook.t.sol`：真实 PM 的 mint/increase/decrease/零 delta collect/burn、NFT 计数、普通操作门禁、获授权退出、全局暂停、失败退出回滚、可选 multiplier 快照。 |
| 初始化、链接库、升级 | `unit/v1/deployment/`、`unit/v1/governance/`、`unit/v1/trading/Initialization.t.sol`：Registry 角色、三组件升级权限与状态保留、LP 专属权限、代理初始化锁、UUPS 上下文、LP 库 delegatecall 状态/调用者、permit、订阅、支付与退出。 |
| 单元转换 | `unit/v1/adapters/ERC8056DirectLegalShareAdapter.t.sol`：实时 multiplier、精度缩放、向下取整及接口/币种校验。 |

## 已移除的旧假设及替代方式

| 历史测试内容 | 当前处理 |
| --- | --- |
| Inbox 报告时效、报告 ID 去重、报告分发 | Inbox 已删除；不恢复 `Ingress`、`PayloadValidation`、`Reports` 及旧报告构造器。以直接 setter 权限、事件和 multicall 原子性替代仍有效部分。 |
| ADTV 月报、tierBps 推导上限、hard cap、更正下限 | 不恢复 `AdtvBatch`、`CapCorrections`。额度直接写入，不从 ADTV/tier 计算，不要求新额度大于已用量。 |
| 拆并股报告、拆股分子分母、Backed adapter | 不恢复 `SplitFactor`、`SplitFactorBoundaries` 和旧 fixture。当前使用实时 ERC-8056 multiplier 与报价快照。 |
| YYYYMMDD、可调整 UTC offset、日历 checkpoint、DST | 不恢复 `TradeDay`、`CalendarBoundaries`。以 EST epoch day、05:00 UTC 边界及固定偏移 fuzz 替代。 |
| 旧报告/日历 stateful 模型 | 不恢复旧 `StatefulOperations`/`OperationsHandler`；改用 `VolumeLedgerHandler` 与当前直接额度 invariant。 |
| Ledger.bindWriters、Inbox/offset 初始化 | 删除旧绑定断言；Ledger 初始化仅传 Registry，Hook 授权实时读取 `registry.hook()`。Registry 绑定及各代理初始化仍有测试。 |
| HALT/RESUME 按位累加或清除 | `applySecurityStatus` 直接赋予最终 NONE/TRADE/LP/ALL 模式；重写暂停事件、角色和状态断言。 |
| 证券级 LP 暂停禁止所有强制退出 | 改为普通 LP 操作被阻止，获授权退出仍可执行；全局暂停阻止两种退出，零流动性 NFT 同样检查。 |
| exact-output、成功的部分成交退款 | 当前 Router 仅 exact-input 且要求全部输入成交。部分成交应整体回滚；DEX prefunding、nonce、授权与池/Ledger 状态不得改变。 |
| `MINT_POSITION_FROM_DELTAS`、`INCREASE_LIQUIDITY_FROM_DELTAS` | 两个 delta-funded action 已由 LP Manager 禁止；主分支的 `LPLinkedLibraries.t.sol` 验证两种入口均拒绝。流动性 mint/increase 使用显式 liquidity 的 action。 |
| SwapAccounted 和旧 Ledger 资产错误码 | 改查 `VolumeUsed`、`InvalidInput` 等当前事件/错误；W/U/Q 身份由 Registry 准入及 Hook 选腿覆盖，不恢复已删除的 Ledger 独立 U.securityId 校验断言。 |
| 税费代币、额外 sender fee、交易中库存快照强制拒绝 | 当前实现已取消相应余额快照检查，删除旧拒绝断言。保留标准代币的余额保留、显式转账失败回滚与 no-return 路径；这些测试不证明税费代币的业务正确性。 |
| 单纯 gas 输出用例 | 移除没有业务断言的 gas 日志测试。需要性能基准时另行建立固定环境。 |

## 容易误读的当前行为

- `isTradable`、`isLPAllowed` 返回池 lifecycle 与证券暂停的结果；全局暂停单独通过 `isPaused()` 暴露。Router、Hook、LP 的执行入口另外检查全局暂停，不能用两个 view 推断全局是否可操作。
- `setQuota` 不清空 `usedWad`。`setUsedWad` 可以降低使用量、归零或写到额度以上；因此不能断言“所有时刻使用量单调递增”或“所有时刻 used≤quota”。后续成交才执行额度检查。
- 额度批量允许空数组、未排序日期、重复日期、过去/未来日期及超过旧报告的 100 项限制；非零证券与非零原因码依然必需。
- `tickCount` 计 NFT，不计价格 tick，也不等同于流动性。全部 decrease 后的零流动性 NFT 仍占一个计数，burn 才减少计数。
- 关闭 quote/U 的新池注册不关闭既有池；证券 relist 不自动恢复旧池 LIST；证券换 tier 不修改旧池注册时的 tier 快照。

## 运行

```sh
make test                 # 全部离线单元/本地集成测试及 invariant
make test-unit            # unit profile
make test-local           # local profile
make test-governance
make test-trading
make test-liquidity        # 当前 LP/Hook 套件
make test-operations       # Registry 套件
make test-invariants      # 当前 Ledger invariant
python3 script/check-test-layout.py
git diff --check
```

默认每个普通 fuzz 用例运行 256 次；Ledger invariant 运行 64 轮 × 32 步。共享 helpers 不包含 `test*`/`invariant*`；套件不继承另一可执行套件，避免重复统计。viaIR 首次编译耗时较长。

`FoundationFixture` 使用真实 Registry/Ledger/Factory/W，Registry 的 Hook/LP 身份由测试合约承担；`VolumeLedgerFixture` 仅 mock Hook 身份和池到证券的查询，oracle 角色和 Ledger 存储是真实合约。`Consumers` 中的 Hook delta 注入用于单元验证，不代表资金完成交换。

Wrapped 集成使用真实 PM、Factory/W、Registry/Hook/Ledger/Router 代理及上游 TSVAdapter，U/Q、发行方 multiplier/checker、SBT 为行为替身。`V1WrappedLiquiditySeed` 仅准备交易流动性；生产 LP 行为单独由 `LPHook` 的真实 LPManager 验证。LPLinked 单元测试使用 mock PM 验证链接库上下文；不能与真实资金集成测试互相替代。

X Layer 当前没有可执行 fork 套件，目录只保留历史部署清单，不计入通过数。测试不证明生产发行方、生产 SBT、多签或链上部署已验收。

## 本次执行记录（2026-10-12）

- `make test`：30 个套件，221 项通过，0 失败、0 跳过；包括 10 项普通 fuzz（每项 256 次）和 1 项 Ledger invariant（64 轮、2048 次 handler 调用、0 非预期 revert）。
- `make test-liquidity`：52 项通过，0 失败；`make test-invariants`：1 项通过，实际命中 Ledger 模型。
- 测试目录结构检查、改动测试 Solidity 文件的 `forge fmt --check` 与 `git diff --check` 通过。
- 以上结果来自当前工作区，包括已有的 `setUsedWad` 原因码校验；未运行 X Layer fork 测试。
