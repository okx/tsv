# TSV V1 实现状态

更新：2026-10-03。本文是当前工作区的状态看板：记录源码已实现什么、还缺哪些实现或外部证据。目标流程见[三系统总览](./SYSTEMS_OVERVIEW.md)，行为规范见[编码规格](./CODING_SPEC_V1.md)和[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)，目标验收条件见[测试规格](./TEST_SPEC_V1.md)。日期评审保留其当时结论，不自动代表当前实现。

**状态用语：**“已编码”表示源码存在；“部分实现”表示仍缺目标行为或自动防护；“外部阻断”表示须取得发行方、法务或目标链证据。测试规格是目标清单，不代表所有测试已执行。

## 1. 当前实现与缺口

| ID / 状态 | 当前实现 | 尚缺事项或限制 |
| --- | --- | --- |
| GAP-01 **已编码（本地）** | Registry、Router 和 LP Manager 只直接结算唯一池内 Currency；旧 TSLAx→wTSLAx 用户结算组合不在当前 ABI | 真实 wTSLAx 实例及法律计股依据仍待准入；本部署无旧仓位迁移，验收见 A05/A06 |
| GAP-02 **已编码（本地行为 mock）** | 唯一 `BackedAutoFeeLegalShareAdapter` 已接入 Hook；实际股票腿在 `afterSwap` 直接调用来源 Token `getUnderlyingAmountByShares(rawShares)`，本地 V4 集成覆盖两方向 Swap 与 LP | 本地来源/Wrapped mock 不构成真实发行方证据；真实代理、转换方法语义和法律计量仍须逐实例审查，验收见 A01/A04 |
| GAP-03 **部分实现** | 直接换算接口已取代 RateSnapshot、rateId 与反向 raw 换算；Hook 在 `afterSwap` 换算，Ledger 校验正/零 shares 与 Registry 元数据后记账；Adapter 可受控版本替换 | 成交事件只记 Adapter 版本，不记录实时发行方参数；链上没有 unitEpoch，也不能拦截未预告的法律股数单位变化。V1 要求暂停整个 securityId，至少跨到下一计量日并准备新单位报告后恢复；无足够预告期的资产不得准入。流程见[准入标准 §4](./TOKEN_ADMISSION_STANDARD_V1.md#4-公司行动与数据单位) |
| GAP-04 **已编码** | DataInbox 接受角色地址直写的 Market、ADTV 和可选 Quota；支持 quota SET/CLEAR、版本顺序和硬上限 | 生产报告服务、索引器与角色操作留证仍须准备；规则见[编码规格 `7](./CODING_SPEC_V1.md#7-角色报告计量日和额度) |
| GAP-05 **已编码** | VolumeLedger 按 UTC 与可配置起点自动生成计量日；支持未来排期、偏移边界、过渡日锁定和取消待生效配置 | 生产报告服务与索引器须采用同一日切规则；部署与验收见[部署清单](./DEPLOYMENT_CHECKLIST_V1.md)及 D04/D05/P03 |
| GAP-06 **已编码，本地回归通过** | 六个业务代理经固定 Anchor 读取当前 Authority、Timelock 与事故控制器；治理根迁移要求 Council 提案和当前 Guardian 批准，并原子更新六代理授权 | 目标链部署、三治理合约代码哈希、迁移前后存储布局和真实身份权限仍须独立核验；验收见 G09 |
| GAP-07 **已编码** | Router 和 LP Manager 对直接结算校验转出、PoolManager 和最终收款方的实际余额变化；非精确转账整笔回滚 | 真实发行方 Token 与目标链仍须执行 A03 及固定依赖验证；相关安全评审见 F-05 |
| GAP-08 **运营方案已定** | 不在链上自动监控发行方代理升级；监控发现后由运营暂停并复审 | 监控数据源、告警、暂停/复审 runbook 和升级证据留存仍待交付 |
| GAP-09 **已编码，本地回归通过** | GLOBAL/SECURITY/TOKEN/POOL 紧急暂停与市场 HALT 支持 TRADE/LP/ALL；市场按模式叠加/恢复，交易与普通 LP 门禁分离，授权强退继续可用 | 本版按首次部署更新暂停、MarketReport、事件及计数查询 ABI；无旧暂停状态迁移。生产报告服务和索引器须采用新模式字段 |
| DEPLOY-01 **脚本已编码，本地预测已测** | DeployGovernanceV1 与 DeployCoreV1 分阶段部署；六代理地址及 Hook 依赖 Router/LP Manager 地址的 CREATE/CREATE2 预测有回归 | 尚未在目标链广播；按[部署清单](./DEPLOYMENT_CHECKLIST_V1.md)完成绑定、SBT、角色及发布后快照 |

## 2. 规格与发布门禁

### 规格待闭合

| ID | 尚待确认 | 权威来源 |
| --- | --- | --- |
| SPEC-01 | 候选治理合约代码哈希、迁移演练和升级存储布局检查仍须作为发布证据完成 | [编码规格 `9](./CODING_SPEC_V1.md#9-代理角色和升级)、[部署清单 `9](./DEPLOYMENT_CHECKLIST_V1.md#9-治理根迁移) |
| SPEC-02 | 每个生产资产的发行方预告期、法律生效时间和可暂停性须确认；链上无法自动识别未预告的法律单位切换 | [准入标准 `4](./TOKEN_ADMISSION_STANDARD_V1.md#4-公司行动与数据单位) |

前端股数展示及换算使用发行方认可的持仓权益定义，并把结果换算为现有 raw Swap/LP 参数。逐笔 Adapter 的 `toLegalShares` 不能替代用户账户持仓权益读取；当前 Adapter ABI 也不提供从股数预算反算 raw 数量的方法；V1 不增加股数输入合约入口。

### 外部证据与交付

| ID | 尚待取得的证据或交付物 |
| --- | --- |
| EXT-01 | 发行方与法务确认 TSLAx/wTSLAx 的逐笔法定股数公式、账户权益定义、成交量费用口径、公司行动单位及拒转强退方案；批准前保持 UNREVIEWED |
| EXT-02 | 核验真实代理 ABI、管理员、制裁/暂停权限、wTSLAx 精确转账、`getUnderlyingAmountByShares` 调用 gas 与返回语义，并留存代理升级监控及暂停复审证据 |
| EXT-03 | 固定 V4 上游来源和可重现版本；分别构建并通过薄接口集成 SmartWalletSbt 与 Backed 产物 |
| EXT-04 | 完成固定区块 X Layer 核验、fuzz/invariant、存储布局升级回归、最坏 gas、Hook salt manifest、目标链部署演练及监控留证 |
| EXT-05 | 补充仓库内 lib/v4-core 的上游来源/版本证明和固定构建记录；Git 基线及报告 ABI 变更记录已建立 |

## 3. 本地验证记录

2026-10-01 旧 Swap Adapter/状态设计下的历史完整套件记录为 **62 个通过、0 个失败、0 个跳过**，包含已删除的 ERC-8056 反算测试，不作为当前实现的验证。2026-10-02 直接换算 Adapter 和 Hook 流程变更后，`FOUNDRY_PROFILE=unit forge test --summary` 为 **38 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --summary` 为 **23 通过、0 失败、0 跳过**；`FOUNDRY_PROFILE=unit forge build --skip test --sizes` 编译成功。本次覆盖 Backed Adapter 的 source/currency/零值校验及接入真实 V4 的两向 Swap、LP raw 结算。合约未部署，因此当前 Router/Hook 布局按新实现直接定义，不保留旧 Swap 专用槽。

2026-10-03 三种暂停模式实现后，`FOUNDRY_PROFILE=unit forge test --offline` 为 **51 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --offline` 为 **82 通过、0 失败、0 跳过**；local 包含 Position ID 测试继承执行的集成用例。`forge build --offline --sizes --skip test` 编译成功，Registry 运行时代码为 **18,434 字节**。回归覆盖四种 scope × 三种 mode、紧急记录叠加/逐条清除、市场部分恢复与无变化请求回滚、新事件模式字段、直接及 Adapter Swap、五种普通 LP 操作、暂停期间强退、建池和 Adapter 替换门槛；Position ID 的 8 项验证继续通过。

这些记录证明当时本地源码的执行结果，不替代真实 wTSLAx、SBT、发行方代理、固定区块 fork、目标链部署和独立审计。当前测试命令及每项目标覆盖见[测试规格](./TEST_SPEC_V1.md)。
