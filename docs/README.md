# TSV 文档导航

当前 Registry 和单池 Wrapped Swap 接口、实现证据优先查阅 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)及 [W/U/Q 运营流程](./OPENING_A_STOCK_MARKET_V1.md)。以下旧规格中的 DIRECT、DEX 与 LP 部分保留为历史设计；生产 Wrapped LP 待独立交付。

阅读主线：从[三系统总览](./SYSTEMS_OVERVIEW.md)了解交易、运营和治理流程，再按下表进入对应的权威文档。当前源码位于 `src/v1/`；若源码与说明冲突，以源码为准，并更新负责该主题的文档。

## 权威来源

| 主题 | 权威文档 | 维护内容 |
| --- | --- | --- |
| 当前 W/U/Q 接口与实现 | [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md) | Factory/checker、只读库、Swap 结算、测试与 ABI/layout 制品 |
| 历史系统流程与直接入口 | [三系统总览](./SYSTEMS_OVERVIEW.md) | 三系统边界、交互顺序、角色和业务入口索引 |
| 设计背景与取舍 | [架构决策](./CONTRACT_ARCHITECTURE.md) | 决策记录及选择这些边界的原因 |
| 历史合约类型、ABI 和算法 | [编码规格](./CODING_SPEC_V1.md) | 当前接口、字段、权限、状态和算法 |
| 资产与法律股数准入 | [代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md) | Currency 条件、计股依据、公司行动与实例审查 |
| 测试与验收 | [测试规格](./TEST_SPEC_V1.md) | 目标用例、覆盖层级与通过证据 |
| 剩余测试工作 | [测试缺口统一清单](./TEST_GAPS_V1.md) | 治理、交易/LP、运营及发布验收缺口去重、完成条件与推进顺序 |
| 运营测试完整度 | [运营测试 review](./OPERATIONS_TEST_REVIEW_V1.md) | 运营入口逐项覆盖、新增证据与生产/链下验收缺口 |
| 当前实现证据 | [实现状态](./IMPLEMENTATION_STATUS_V1.md) | 已实现范围、缺口、外部阻断及本地验证记录 |
| 部署与治理操作 | [部署清单](./DEPLOYMENT_CHECKLIST_V1.md) | 部署顺序、配置步骤、发布门禁、身份恢复与升级冻结 |
| 单只股票市场开通 | [Opening a Stock Market](./OPENING_A_STOCK_MARKET_V1.md) | 当前开通流程、流程图、函数参数与权限、首笔成交验收及持续运营 |
| 历史外部 DEX Router / Adapter 接入 | [外部 DEX Router 与 Adapter 接入 TSV](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) | 当前 Wrapped 入口拒绝 external Adapter；旧成功设计仅为历史参考 |
| 部署参数输入 | [Manifest 模板](./DEPLOYMENT_MANIFEST_V1.example.json) | 部署脚本所需字段的示例结构 |

## 按任务阅读

- **先理解系统：**三系统总览。
- **新增或改动合约接口：**编码规格、代币准入标准、测试规格。
- **判断是否达到发布条件：**实现状态、测试规格、部署清单。
- **安排后续测试工作：**[测试缺口统一清单](./TEST_GAPS_V1.md)，已执行证据见[覆盖矩阵](./TEST_COVERAGE_V1.md)。
- **开通一只新股票市场：**[Opening a Stock Market](./OPENING_A_STOCK_MARKET_V1.md)。
- **追溯当时的评审发现：**下方历史评审材料。

## 历史评审材料

这些材料保留各自评审时点的结论，不覆盖当前源码或权威规范。

- [2026-10-01 全仓库复核](./reviews/COMPREHENSIVE_REVIEW_2026-10-01.md)
- [三协议技术可行性评审](./reviews/PROTOCOL_FEASIBILITY_REVIEW.md)
- [2026-09-30 全仓库静态安全评审](./reviews/SECURITY_REVIEW_2026-09-30.md)
- [离线人工 Review 工作台](./reviews/TSV_V1_MANUAL_REVIEW.html)
- [2026-10-01 安全审计报告](./reviews/SECURITY_AUDIT_2026-10-01.md)
- [评审与审计归档索引](./reviews/README.md)

## 维护约定

一项规则只在其权威文档中完整定义：流程写总览，设计理由写架构决策，接口和算法写编码规格，准入政策写准入标准，测试条件写测试规格，当前状态写实现状态，执行步骤写部署清单。其他文档用链接指向权威来源；历史评审只保留历史证据。

拆/并股额度按未来计量日开始排期生效；报告 ABI、来源月基准与更正/取消规则见[编码规格 §7 D-37](./CODING_SPEC_V1.md#7-角色报告计量日和额度)，运营流程见[准入标准 §4](./TOKEN_ADMISSION_STANDARD_V1.md#4-公司行动与数据单位)。
