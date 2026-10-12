# TSV V1 源码实现边界

本文记录仓库当前 Solidity 源码所包含的能力，不代表已部署状态、生产验收或法律批准。判断当前行为请读 [`src/v1/`](../src/v1/) 与测试；部署地址和外部合约证据须另行提供。

## 当前源码包含

| 能力 | 实现位置 | 代码行为摘要 |
| --- | --- | --- |
| 证券、W/U/Q 与 Pool 注册 | `core/TSVRegistryV1.sol`、`libraries/PermissionedValidationLib.sol` | Registry 验证 Factory-created W、canonical U、legal-share Adapter、Q 和 W/Q PoolKey；支持 security listing、tier 容量、Pool lifecycle |
| SBT 操作资格 | `core/TSVRegistryV1.sol` | 按持有身份汇总 `SWAP_ALLOWED`/`LIQUIDITY_ALLOWED`；SBT paused 时有效权限为 NONE |
| V4 Hook 检查 | `core/TSVHookV1.sol` | 限定 PM、Router、LP Manager 和注册池；检查暂停及 multiplier 快照；对成交 delta 记账；不修改 swap/liquidity delta 或 fee |
| 单池 Swap | `periphery/TSVSwapRouterV1.sol` | Adapter allowlist、exact-input、全额输入、deadline、最小输出和 W/U—Q 结算 |
| LP position 管理 | `periphery/TSVLPManagerV1.sol`、`libraries/TSVLPManagerLib.sol` | 注册/初始化池、检查普通 LP action、跟踪 NFT 数量、限制退出回调；不接受 delta-funded mint/increase |
| 日成交额度 | `core/TSVVolumeLedgerV1.sol` | 直接设置 EST epoch-day quota、修正 usedWad、在 Hook 记账时执行额度检查 |
| 法律股数换算接口实现 | `adapters/ERC8056DirectLegalShareAdapter.sol` | 对绑定的 U 读取 `decimals()`/`uiMultiplier()` 并做整数向下取整 |
| Proxy 与 Hook 地址部署机制 | `deployment/TSVERC1967Proxy.sol`、`deployment/TSVHookProxyFactoryV1.sol` | 非空 initializer 的 ERC-1967 proxy 与满足 `0x3FFF` 权限位的 CREATE2 Hook proxy |

## 当前没有实现的模块或规则

- DataInbox、Report structs、报告去重/时效/序号或链上报告验证流程。
- ADTV × tier 计算硬上限、可选 quota 公式、可调整计量日或拆并股额度 checkpoint。
- Governance Anchor、Governor/Guardian/RecoveryCouncil、批量治理升级或 upgrade freeze。
- TSV Router 多跳、exact-output、原生币交易、delta-funded LP mint/increase、position `withdrawClaim`。
- 可执行的 X Layer fork `.t.sol` 套件。

如果其他文档将以上项目描述为当前功能，应将其更正或明确标记为历史设计。

## 代码路径和验证入口

- 单元测试：[`test/unit/`](../test/unit/)
- 本地 PoolManager 集成：[`test/integration/local/`](../test/integration/local/)
- X Layer 目录：[`test/integration/xlayer/`](../test/integration/xlayer/)，当前只有部署清单/说明
- 运行命令与 fixture 边界：[`test/README.md`](../test/README.md)
- Foundry 设置：[`foundry.toml`](../foundry.toml)

`make test` 不是目标链 fork 验收。请从 CI pipeline 或明确的本地运行日志引用测试通过数；不要把旧报告中的结果表述为当前提交结果。

## 部署和外部证据边界

仓库源码可以说明构造器、initializer、角色消费者及组件绑定要求，但当前 checkout 不包含完整的生产部署记录。以下状态不能仅凭 Solidity 单元测试推断：

- 目标链上的 PoolManager、Permissions Adapter Factory、Hook、Registry、Router、Ledger、LP Manager 和 SBT 地址正确且交叉绑定；
- 生产 W/U/Q 的转账语义、Factory provenance、issuer allowlist、SBT 规则和法律股数 multiplier 均符合准入决定；
- 角色已按最小权限分配，升级密钥和恢复流程已实际验证；
- 用户与 LP 在目标链真实代币上可完整结算和退出。

发布门禁和需要留存的证据见 [`DEPLOYMENT_CHECKLIST_V1.md`](./DEPLOYMENT_CHECKLIST_V1.md) 与 [`TOKEN_ADMISSION_STANDARD_V1.md`](./TOKEN_ADMISSION_STANDARD_V1.md)。
