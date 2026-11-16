# TSV 文档索引

## 规则来源

合约行为以当前 [`src/v1/`](../src/v1/) 为准，测试用于说明已验证的执行路径，配置入口见 [`foundry.toml`](../foundry.toml) 和 [`Makefile`](../Makefile)。本文档中的概览、规格和操作指南都应与这三类证据保持一致；若文档与源码不符，以源码为准并修正文档。

已部署地址、链上角色配置、真实发行方行为、SBT 行为和链上交易证据不能从本地源码推断。有关这些事项的文档必须明确区分“代码支持”与“已部署/已验收”。

## 当前代码说明

| 主题 | 文档 | 内容 |
| --- | --- | --- |
| 项目入口 | [`README.md`](../README.md) | W/U/Q 模型、合约职责、测试入口和部署边界 |
| 合约架构 | [`CONTRACT_ARCHITECTURE.md`](./CONTRACT_ARCHITECTURE.md) | 当前代码的组件边界、调用关系、权限模型和风险边界 |
| 架构与调用路径 | [`SYSTEMS_OVERVIEW.md`](./SYSTEMS_OVERVIEW.md) | Registry、Ledger、Hook、Router、LP Manager 的代码调用关系 |
| 接口与状态规则 | [`CODING_SPEC_V1.md`](./CODING_SPEC_V1.md) | 当前数据结构、公开入口、权限、配额及暂停语义 |
| Registry 准入 | [`PERMISSIONED_REGISTRY_V1.md`](./PERMISSIONED_REGISTRY_V1.md) | W/U/Q、证券、池、SBT 身份和 lifecycle |
| 市场开通 | [`OPENING_A_STOCK_MARKET_V1.md`](./OPENING_A_STOCK_MARKET_V1.md) | 按当前 Registry、Factory、PoolManager 和角色配置开通市场 |
| ABI / storage snapshot | [`artifacts/README.md`](./artifacts/README.md) | 当前源码生成的 ABI 与 storage-layout snapshots |
| 资产风险审查 | [`TOKEN_ADMISSION_STANDARD_V1.md`](./TOKEN_ADMISSION_STANDARD_V1.md) | 链上能校验的条件与必须链下核实的 Token 行为 |
| Router / LP / Ledger 接入 | [`BACKEND_INTEGRATION_GUIDE_V1.md`](./BACKEND_INTEGRATION_GUIDE_V1.md) · [English](./BACKEND_INTEGRATION_GUIDE_V1_EN.md) | 按当前 ABI 组装调用与读取状态 |
| 外部 DEX Adapter | [`EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md`](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) | Adapter 白名单、participant 身份和 exact-input 限制 |
| 环境合约地址 | [pre](../deployment/pre/addresses.json) · [prod](../deployment/prod/addresses.json) | 地址清单、实现、库、Factory 及资产 |
| 生产版本发布说明 | [V0.0.2（发布准备）](releases/V0.0.2.md) | 已上线核心版本、升级变化、交易及验证边界；Tag/Release 尚未创建 |
| 部署过程 | [公开部署说明](./deployments/README.md) | 发布与部署步骤；原始操作证据保留在运维分支 |
| 发布范围 | [PUBLICATION.md](./PUBLICATION.md) | 当前文件范围、显式配置、待完善许可及后续历史处理 |
| 分支维护 | [分支职责](./REPOSITORY_BRANCHES.md) | main、ops/deployment 和正式 release 的维护规则 |
| 部署准备 | [`DEPLOYMENT_CHECKLIST_V1.md`](./DEPLOYMENT_CHECKLIST_V1.md) | 构造参数、代理初始化、绑定、角色与尚缺的部署证据 |
| 部署记录模板 | [`DEPLOYMENT_MANIFEST_V1.example.json`](./DEPLOYMENT_MANIFEST_V1.example.json) | 当前五组件地址、外部依赖、角色、资产和发布证据字段 |
| 测试 | [`../test/README.md`](../test/README.md) | 可执行测试目录、fixture 边界和命令 |
| 测试覆盖记录 | [`TEST_COVERAGE_V1.md`](./TEST_COVERAGE_V1.md) | 当前测试文件与代码能力的映射 |
| 测试维护与验证边界 | [`TEST_SPEC_V1.md`](./TEST_SPEC_V1.md) · [`TEST_GAPS_V1.md`](./TEST_GAPS_V1.md) | 当前测试应保护的行为、外部验证缺口和运营测试位置 |
| 适配器实现 | [`TSV_ADAPTER_IMPLEMENTATION_V1.md`](./TSV_ADAPTER_IMPLEMENTATION_V1.md) | 仓库集成的 DEX Adapter 接口边界 |

## 设计稿与历史材料

下列文件记录设计过程或特定日期的评审，不定义当前合约接口或发布状态：

- [`POOL_LIFECYCLE_PAUSE_DESIGN.md`](./POOL_LIFECYCLE_PAUSE_DESIGN.md)
- [`REGISTRY_OBJECT_MODEL_DESIGN.md`](./REGISTRY_OBJECT_MODEL_DESIGN.md)
- [`TSV_REGISTRY_V1_OPTIMIZATION_DESIGN.md`](./TSV_REGISTRY_V1_OPTIMIZATION_DESIGN.md)
- [`TSV_CONTRACT_DESIGN_LP_V1.md`](./TSV_CONTRACT_DESIGN_LP_V1.md) · [English](./TSV_CONTRACT_DESIGN_LP_V1_EN.md)

历史材料应保留其日期和当时结论，不应被当作对当前源码的描述。若要引用其中的 ABI、状态机或测试结果，先在当前源码和测试中重新核对。

## 按工作查阅

- **理解合约流程：**从 [`SYSTEMS_OVERVIEW.md`](./SYSTEMS_OVERVIEW.md) 开始，再查对应源文件。
- **集成后端：**使用 [`BACKEND_INTEGRATION_GUIDE_V1.md`](./BACKEND_INTEGRATION_GUIDE_V1.md)，发送交易前按当前部署地址和链上状态进行模拟。
- **准入新资产：**阅读 [`PERMISSIONED_REGISTRY_V1.md`](./PERMISSIONED_REGISTRY_V1.md) 与 [`TOKEN_ADMISSION_STANDARD_V1.md`](./TOKEN_ADMISSION_STANDARD_V1.md)。
- **部署或升级：**使用 [`DEPLOYMENT_CHECKLIST_V1.md`](./DEPLOYMENT_CHECKLIST_V1.md)；该清单不替代发布审批或链上核验。
- **维护测试：**查看 [`../test/README.md`](../test/README.md) 和现有 `.t.sol` 测试。
