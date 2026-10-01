# TSV 文档导航

先看[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)，再按需要读目标规则或当前 ABI。**生产目标与当前源码仍有差距**：目标 V1 仅直接收付池内 Currency，Tesla 池只收付 wTSLAx；本地标准 `ERC8056TestToken(STDx)` 的直接动态计量路径、自动 UTC 日切、可选 quota、双边精确结算及治理根迁移已有代码与本地测试。真实 wTSLAx 代理、公司行动运营控制和目标链部署仍需留证。

最新额度与日切规则见[架构决策 D-33/D-34](./CONTRACT_ARCHITECTURE.md#0-决策记录与阅读方式)：每个 UTC 日期都有独立 TSV 计量日，按可配置 UTC 起点自动切分；无需日历报告。日配额报告仅在指定计量日需要覆盖时提交，缺省采用适用 ADTV 与 Tier 算出的硬上限。运行中修改起点只影响未来，并产生一个长于或短于 24 小时的过渡日。对应 ABI 与算法已在当前源码实现，测试及外部发布交付见[实现状态](./IMPLEMENTATION_STATUS_V1.md)和[编码规格 §7](./CODING_SPEC_V1.md#7-角色报告计量日和额度)。

| 阅读场景 | 文档 | 职责与效力 |
| --- | --- | --- |
| 查进度和发布阻断 | [实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md) | **当前代码与目标之间的状态索引**；分开列出实现缺口 GAP、规格缺口 SPEC、外部证据 EXT 和测试状态 |
| 理解系统与决策 | [系统架构](./CONTRACT_ARCHITECTURE.md) | 系统边界、组件、治理、资金与数据流；D-33/D-34/D-35 已编码，D-36 生产资产仍须逐实例审查 |
| 判断资产能否准入 | [代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md) | **目标资产规则的规范来源**：Currency 直接结算、计股与公司行动 |
| 实施 Tesla 实例 | [TSLAx / wTSLAx 实例](./TSLAX_INTEGRATION.md) | wTSLAx 唯一直结、发行方权益公式及准入证据；不得外推到所有 xStock |
| 讨论拆股/合股 | [拆股/合股计量设计讨论稿](./CORPORATE_ACTIONS_SPLIT_MERGE_V1.md) | 只讨论会改变交易量记账单位的正向拆股和反向拆股；包含多 Token 发行方不同步时的 Token 级就绪/暂停；其他公司行动标记为 V1 无需考虑 |
| 查 ABI 与迁移算法 | [V1 编码规格](./CODING_SPEC_V1.md) | 明确标注的当前 ABI、迁移前类型参考及 D-33～36 规则并存；调用现有合约时以 `src/v1/` 为准 |
| 实施验收 | [测试与验收规格](./TEST_SPEC_V1.md) | **目标测试清单**；当前本地通过记录见实现状态 |
| 全新部署 | [全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md) / [Manifest 模板](./DEPLOYMENT_MANIFEST_V1.example.json) | 六代理部署顺序、Hook/Router/LP 地址绑定、治理初始化、角色配置和发布后验收 |
| 治理根换址 | [治理根迁移清单](./GOVERNANCE_MIGRATION_RUNBOOK_V1.md) | Council/Guardian 双批准、候选三合约预配置、原子切换与旧根失权验证 |

专项缺口：[固定比例股票拆股后的计股更新缺口](./STATIC_RATIO_CORPORATE_ACTION_GAP.md)记录当前 Adapter 替换限制、额度单位风险及 D-36 的迁移方向；对应 GAP-03。

以下为**评审材料**。历史报告保留当时的发现和证据，不作为最新产品决策或 ABI 来源：

- [2026-10-01 全仓库复核](./reviews/COMPREHENSIVE_REVIEW_2026-10-01.md)：当前工作区的修复、验证和未满足的生产门禁。

- [三协议技术可行性评审](./reviews/PROTOCOL_FEASIBILITY_REVIEW.md)：针对早期 v0.3 架构的源码核查和后续处置记录。
- [全仓库静态安全评审](./reviews/SECURITY_REVIEW_2026-09-30.md)：当日代码快照的问题与限制。
- [人工 Review 工作台](./reviews/TSV_V1_MANUAL_REVIEW.html)：离线 HTML 检查表；以当前规格和实现状态核对其中的历史路径。

**术语与边界：**xStock 是发行方股票 Token 产品系列，TSLAx 是其中 Tesla 标的的一个实例；wTSLAx 是发行方为该实例提供的 Wrapped 份额。`securityId` 是底层证券 ID；`poolCurrency` 是 V4 实际持有、用户直接收付的 ERC-20。目标 `userToken` 若保留，必须等于 `poolCurrency`。`LegalShareAdapter` 将股票 Currency 的实际 V4 Swap 数量换算为经批准的法定股数。一个 TSV 平台下所有池按 `securityId` 共用日成交账本，股票 Currency 与股票 Currency 不得组成池。

修改文档时遵循单一来源：通用资产判据写准入标准，TSLAx 特有行为写实例文档，ABI/算法写编码规格，验收用例写测试规格，**实现证据与状态只写缺口清单**。架构文档解释规则如何协同；历史评审只保留当时证据，不覆盖现行目标。前端股数展示与换算是客户端职责，现有合约入口仍使用 raw 数量；参见[编码规格 §5～6](./CODING_SPEC_V1.md)。
