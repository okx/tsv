# TSV V1 运营测试完整度 review

更新：2026-10-04。范围依据[三系统总览的运营直接入口](./SYSTEMS_OVERVIEW.md#运营角色直接写入口总表)和[测试规格](./TEST_SPEC_V1.md)的 R01–R09、A02/A07/A09、D01–D13、暂停/强退、P03；配置入口还包括 Governor 控制的 Tier 和 SBT。本文 review 测试覆盖，不替代合约安全审计。

跨领域剩余工作及完成条件统一维护在[测试缺口清单](./TEST_GAPS_V1.md)；本文保留运营入口及覆盖率的复核证据。

## 结论

原有用例**不完备**：暂停模式与常规准入已有较好覆盖，报告元数据失败、ADTV 批次边界、Tier/额度更正、上下架容量和日切交错存在缺口。本轮补上这些明确的本地行为，并用真实 V4 验证配置变更后的成交、仓位和失败回滚。

仍不能声称“覆盖全部场景”。本地测试覆盖所列规则及有限随机模型；生产资产、真实 SBT/多签、链下报告和告警服务、链重组、数据口径审批、生产 gas 余量及运维演练是另外的验收对象，见末尾清单。

## 入口与用例对应

表中路径相对仓库根目录。原有交易/LP、治理和发行方故障用例继续保留，未为增加计数重复继承执行。

| 行为 / 规格 | review 发现的缺口 | 当前证据 |
| --- | --- | --- |
| 四个 Inbox 入口的角色 / D01–D02 | 原来只有市场报告的陌生 caller；未逐入口测试交叉角色、撤权和 renounce | `unit/v1/reports/Ingress.t.sol`：HALT 与 VOLUME 角色互不替代，单条/批量/Quota 撤权后拒绝，重授后可提交 |
| 通用报告元数据 / D02 | reportId/sourceHash 为零、来源时间回退/未来、截止过期、零/重复序号、时间相等和序号跳跃缺矩阵 | `Ingress.t.sol`：三类报告 × 九种拒绝输入，失败比较业务状态、ID、序号和来源时间；截止相等/来源相等/递增跳号成功 |
| 去重范围 / D02 | 缺跨类别、跨证券、批次内重复 ID | `Ingress.t.sol`、`AdtvBatch.t.sol`：ID 全局唯一；序号/来源时间按类别和证券独立，合法新 ID 可继续提交 |
| 报告业务字段 / D03/D06/D09 | 零/未知/下架标的、版本、月份、原因/来源、Quota action 和数值缺完整拒绝及重试证据 | `PayloadValidation.t.sol`：Market 六类、ADTV 十一类、Quota 十二类输入；失败不占用元数据，修正后使用同一 ID 提交；CLEAR 非零/重复清除拒绝 |
| ADTV 批次 / D02 | 原来只有两条成功和最后版本错误 | `AdtvBatch.t.sol`：0/1/100/101 条、零/重复/逆序标的、混月、重复 ID、三个位置的 ingress/业务错误 fuzz；100 条末项失败全回滚，修正后全部接受 |
| 版本与期间 / D06/D09 | 更正、跨月版本重启与来源序号继续递增缺证据 | `PayloadValidation.t.sol`：版本必须严格加一；新月份从版本 1 开始但来源序号不重置；新 ID/版本允许相同正 ADTV 值，数值相同不属于链上 replay 判定 |
| 硬上限、额度、即时更正 / D07/D09 | 原有 SET/CLEAR 只覆盖未成交状态，Tier/ADTV 更正与旧覆盖取 min 不足 | `CapCorrections.t.sol`、`Lifecycle.t.sol` 与 `local/operations/OperationsFlows.t.sol`：下调到低于 used 后拒绝新成交，上调仍受旧 quota 约束，CLEAR 不清零 used，换 Tier 即时改变 cap；舍入及恰好达到上限 fuzz |
| 报告有效性 / D06 | 提交截止与已接受值的生命周期易混淆 | `CapCorrections.t.sol`：提交 deadline 不让已接受 ADTV/Quota 过期；未来日额度不影响当前日，缺适用月份 ADTV fail-closed |
| Tier 与证券生命周期 / R03–R04 | 缺转 Tier、容量回滚、多 Currency 去重、最后活跃池、下架后符号保留 | `registry/Lifecycle.t.sol`、`Configuration.t.sol`：上下架/换 Tier 的版本与计数，满 Tier 后重上架回滚并可重试；同证券多 Currency/池仅占一上市名额；旧 symbol/securityId 不可重新登记 |
| Token 与 SBT 配置 / R02/R08/A09 | 缺 quote 股票元数据污染、部分 SBT selector 缺失、畸形返回及 tokenId 变更 | `Configuration.t.sol`：quote 元数据、decimals/codehash、无代码、SBT 单个 selector/读失败/短返回；错误配置保留旧值，tokenId 生效、paused 与资格区分；真实写路径读故障由原 `local/liquidity/ForceExit.t.sol` 验证 |
| Adapter 更换 / R03/A07 | 缺无活跃池路径、版本连续、错误暂停范围、配置字段保留 | `registry/AdapterChanges.t.sol`、原 `Pauses.t.sol` 和 `local/operations/OperationsFlows.t.sol`：无活跃池可换；活跃池只接受 GLOBAL/TOKEN 共同覆盖 TRADE+LP；版本 2→3、身份/接口/绑定错误；已有真实仓位、池键、费用和 used 保留 |
| 暂停审计及职责分离 | 已有 scope × mode 与叠加；缺证据/target、完整 record 元数据和撤权 | `PauseBoundaries.t.sol`、`Permissions.t.sol`：错误请求不分配 ID；清除不改旧审计字段、不复用 ID；pauser/resumer 不互代；市场/紧急恢复独立及暂停下强退复用原集成用例 |
| 所有 SYMBOL_ADMIN 写入口 / 角色 | 原来只专门检查 admit/register | `Permissions.t.sol`：九个入口拒绝无角色/撤权地址；Governor 未获该业务角色也被拒；业务角色不能改 Tier/SBT/日切；内部 LP/Hook/Inbox 写入只接受固定调用者 |
| 初始化与绑定 / R09 | Registry/Ledger 自身零依赖、Writer 绑定缺直接用例 | `reports/Bindings.t.sol`：零依赖、偏移 86400、逐组件无代码、越权及重复绑定回滚，正确绑定可完成；交叉绑定与部署清单继续由治理部署用例检查 |
| 建池 / R05–R06 | 缺真实 V4 参数边界和 POOL_CREATOR 撤权 | `local/operations/PoolCreationBoundaries.t.sol`、`OperationsFlows.t.sol`：十三类非法输入/重复初始化保持 Registry/V4/余额/计数；合法 fee/tick/price 边界；独立 creator 创建真实池、撤权后无 PENDING 残留 |
| 日期与排期 / D04–D05 | 原来仅一个 Gregorian 检查、28h 和部分取消；缺月末/年末/20h/一秒边界 | `CalendarBoundaries.t.sol`：独立 UTC 向量包含周末、月末、年末、闰日和 2100 非闰年；0–86399 偏移/秒数 fuzz；待生效重复、取消证据、锁定时点和三检查点历史查找 |
| 日切与跨月成交 / D04–D07 | 单元查询不能证明实际 used/资金回滚 | `local/operations/OperationsFlows.t.sol`：20/28h 日均只有完整一份 quota，边界前拒绝和边界后新用量；11 月缺 10 月 ADTV 拒绝 Swap 而 LP 继续，补报恢复，历史 used 不变 |
| 法律单位切换 / A02 | 缺完整运营动作示例；实现没有自动识别单位变化 | `OperationsFlows.t.sol`：暂停、批准的新单位 ADTV/下一日 quota、下一日恢复、当次换算、LP 关闭；旧 used 不重算。此用例不证明“同日提前恢复必被合约阻止” |
| 拆并股额度 / D10–D13 | 缺系数排期、自动生效及源月基准 | `SplitFactor.t.sol`、`SplitFactorBoundaries.t.sol`、`SplitFactorFlows.t.sol`：正/反拆、精确分数、按未来日切自动选因子、最新待生效项更正/取消、跨月不重复、报告/算术边界、真实 V4、升级状态保留；实际 Token 计股仍实时 Adapter |
| 报告/日切交错 / P03 | 原来只有单例/交易 Handler 的七日模型 | `reports/StatefulOperations.t.sol`、`helpers/v1/OperationsHandler.sol`：独立季度日历、四个月 ADTV、96 日 quota/used、来源序号/时间、全局 ID、角色撤授、偏移排期/取消、独立线性系数模型和成交记账模型（八类动作）；失败接受性及历史边界逐项比较 |

## 模型与断言范围

确定性拒绝测试比较相关状态快照，报告快照包括 Registry 市场/证券、Ledger ADTV/Quota/used、Inbox ID 与三类元数据；批次比较每个标的的状态。真实 V4 失败快照还包含池价格/流动性/费用、仓位/Receipt owner、参与者及三个结算合约余额。

运营随机模型固定一个证券、Tier 25 bps、本地 Hook 单元写入；覆盖 2026-10-01 至 2027-01-01 的时间推进、查询至 2027-01-04 的排期/额度，ADTV 来源月为 202609–202612。日历以独立 UTC 起点及明确月长计算，不调用 TSV 的日期函数生成预期边界。实际资金路径由真实 V4 集成补充。多证券/跨类别报告独立性、Tier 变更、市场与紧急暂停由确定性/交易模型分别验证，未宣称任意组合的穷举。

100 条批次成功说明代码边界和原子行为通过，不代表已经取得 X Layer 生产账户、编译产物和区块 gas 余量的发布证据。

报告的链上门禁校验字段格式、角色、次序、时间与非零摘要，不验证来源数据真实性或法务批准内容。有效格式的未来月份 ADTV 和历史日 Quota 可以被授权角色提交；模型按实际规则测试，并不把这种可提交性当成来源数据已合规的证据。

## 尚需验收的运营场景

| 场景 | 仍缺的证据 |
| --- | --- |
| 生产发行方、SBT、Governor/运营多签 | 真实 ABI/实现与配置、撤证/暂停/拒转写路径、签名门槛与真实账户操作演练；DEX fork 的股票/SBT mock 不能替代 |
| 报告生产与提交服务 | 数据源延迟/丢失/纠错/同月重试、持久化 ID/sequence、nonce 并发、交易失败重试、跨月补报与告警；当前仓库没有这些服务的可执行测试对象 |
| 链重组与索引服务 | 回滚未确认报告、去重状态回溯、事件重放、校对链上 cap/used 与业务报表；本地 EVM 测试未模拟服务端重组处理 |
| 法律单位变化与代理升级监控 | 发行方预告/法务审批、先暂停后跨日切换、漏告警/错误解除演练。合约无 unitEpoch，不能自动识别单位变化或审核摘要内容 |
| 生产发布性能与运行 | 75/100 标的批次、最坏 Adapter/强退、长期检查点的 gas 和区块余量；目标链真实角色/资产配置、监控与回滚预案演练 |
| 随机模型以外的组合 | 所有证券/Tier/Token 类型、任意长历史、SBT/发行方故障与升级/市场/暂停交错。有限 fuzz/invariant 增加证据，不是穷举证明 |

## 覆盖率与尚未触达的合约内分支

系数功能之前的历史全部不联网 coverage 运行为 **334 通过、0 失败、0 跳过**；使用 IR minimum，统计有源码映射限制。

| 合约 | 补齐前分支覆盖率 | 当前行覆盖率 | 当前分支覆盖率 | 当前函数覆盖率 |
| --- | --- | --- | --- | --- |
| DataInbox | 40.00% | 100% | 100% | 100% |
| Registry | 62.30% | 98.41% | 95.08% | 100% |
| VolumeLedger | 52.63% | 98.61% | 84.21% | 100% |
| ReportValidationLib | 50.00% | 100% | 100% | 100% |
| TradeDayLib | 42.86% | 100% | 71.43% | 100% |

LCOV 剩余位置不能统一归因于源码映射，也不能仅靠函数覆盖率称为全场景通过：

| 分类 | 具体位置与现状 |
| --- | --- |
| 尚未直接注入的防御输入 | Ledger 的零/同号 Swap delta、非股票腿传入非零 legal shares；当前 Handler 使用合法 delta、quote shares=0。真实 V4/Hook 正常路径不会产生这类值，已有权限拒绝用例不能替代这些授权 Hook 故障输入测试。 |
| 当前写入口约束不可达 | Ledger 股票元数据的 securityId/Adapter/版本异常要求 Registry 出现被当前准入/更换规则禁止的记录；MarketAction enum 越界会在 ABI 解码时拒绝，Registry 函数体最后的非法 action 分支不会执行；TradeDayLib 的 uint64 时间窄化溢出受公开日期范围限制。异常依赖/未来实现可另用故障替身验证。 |
| 当前时间模型范围外 | Unix epoch 首个计量日开始前、超出 9999 年的区块时间尚未通过 currentTradeDay 测试；当前 quarter 模型不生成这些时刻。非法日期参数已有独立拒绝用例，不能代替区块时间边界。 |
| 已执行但映射未计入 | Registry 的 SBT verify 配置校验、SbtConfigChanged 事件和运行门禁返回 true 位置仍有零计数；对应配置成功/故障、事件和实际允许交易均有通过断言。 |

上述剩余输入和生产/链下清单一起构成“不能声称全部场景已覆盖”的依据；它们没有被计成已完成测试。

## 运行

`make test-operations` 运行 Registry、报告与运营集成；`make test-invariants` 同时运行治理、交易/LP 和运营模型；`make test` 运行全部不联网回归。

系数功能之前的历史优化回归使用固定 seed `0x20261004`：**334 通过、0 失败、0 跳过**（unit 208、local 126，60 个不联网套件）。其中运营范围 **113 项 / 20 个套件** 全部通过；相比交易/LP 阶段新增 **64 项**，含两项运营 invariant，全库共有七项 invariant 和十二个具名 fuzz 用例。invariant 默认每项 64 轮 × 32 步，普通 fuzz 256 次。

复现本轮完整结果：`FOUNDRY_PROFILE=default forge test --fuzz-seed 0x20261004 --summary`。覆盖率及原始记录见[覆盖矩阵](./TEST_COVERAGE_V1.md)，不把未执行的生产场景计入通过数。
