# TSV V1 实现与缺口清单

更新：2026-10-01。本文只判断**当前工作区源码**实现了什么、还缺什么；目标行为以[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)、[架构决策](./CONTRACT_ARCHITECTURE.md)和[编码规格](./CODING_SPEC_V1.md)中明确标注的目标段落为准。[测试规格](./TEST_SPEC_V1.md)是目标验收清单，不能把表中用例当作已通过证据。此前的[静态安全评审](./reviews/SECURITY_REVIEW_2026-09-30.md)保留原始发现，不随本文自动更新。

状态用语：**已编码**仅表示源码存在；**部分实现**表示目标行为已有部分代码但仍缺关键分支（历史源码路径不算生产能力）；**未实现**表示目标入口或状态机不存在；**外部阻断**表示仅凭 TSV 源码无法完成准入。下文不把历史测试通过数等同于当前验收结果。

## 1. 已编码的 V1 基线

| 范围 | 当前源码证据 | 边界 |
| --- | --- | --- |
| 单池 Swap、LP 和 V4 Hook | [Router](../src/v1/periphery/TSVSwapRouterV1.sol)、[LP Manager](../src/v1/periphery/TSVLPManagerV1.sol)、[Hook](../src/v1/core/TSVHookV1.sol)；Hook 工厂要求地址低位 `0x3FFF` | V1 所有返回 delta 为零；不等于未来非零 Hook delta 已可启用 |
| 合约数量与共享库 | 六个核心业务代理：Registry、VolumeLedger、DataInbox、Hook、Router、LP Manager；[共享库](../src/v1/libraries/)集中结算、股数、日期和报告校验；Registry 内置 SBT 策略，LP Manager 内置 Receipt ERC-721 | V1 明确采用全新实例组，不复用旧 Router/LP/SBT Adapter/Receipt 地址；部署顺序、Hook 循环地址和发布验收见[全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md) |
| 资产登记、池门禁 | [Registry](../src/v1/core/TSVRegistryV1.sol) 仅接受 `userToken == poolCurrency` 的直接结算组合，建池时拒绝两侧 `securityId` 同时非零；旧 TSLAx→wTSLAx 配置有负向回归 | 真实 wTSLAx 代理的生产准入仍需外部证据；本地标准股票使用 `ERC8056TestToken` |
| 股数与额度 | [股数接口](../src/v1/interfaces/ILegalShareAdapter.sol)提供正向计股和只读 raw 边界反算；`ERC8056LegalShareAdapter` 读取 `uiMultiplier()`；[Ledger](../src/v1/core/TSVVolumeLedgerV1.sol)按实际 V4 delta、自动 UTC 计量日和可选日额度记账 | V1 禁止日内法律股数单位切换，链上仍无自动识别；生产 wTSLAx 证据仍需补齐；Registry 不把静态比例作为新权威字段 |
| 报告、身份、治理 | [DataInbox](../src/v1/core/TSVDataInboxV1.sol)处理 Market/ADTV/Quota 三类角色直写报告；Router 保留 EIP-712/ERC-1271 用户授权；[GovernanceAnchor](../src/v1/governance/TSVGovernanceAnchor.sol)为六代理提供动态治理根 | Anchor 迁移已有本地双批准、六地址及旧根失权回归；目标链部署和独立审计仍未完成 |
| SBT 资格配置 | Registry 统一保存 SBT 地址/tokenId；`setSbtConfig` 配置时校验 `paused()`/`verify()`，未配置时资格读取回滚 `SbtNotConfigured()` | 真实 SBT 代理、tokenId、发行权限和 AA 钱包领证能力仍需外部证据；发布前不得开放用户 Swap/LP |
| 发行方资产结算 | 目标新路径只直接收付池内 Currency；Registry 拒绝旧 TSLAx→wTSLAx 登记。`IssuerShareSettlementAdapter` 和接口已隔离到 [`legacy/`](../src/v1/legacy/)，只由历史单元测试导入 | 生产 wTSLAx 仍需实际代理的精确转账、制裁、暂停和强退证据；本部署没有旧 LP 仓位，因此不设计旧仓位兼容分支 |

## 2. 目标行为与未实现内容

| ID / 状态 | 目标与当前差异 | 所需实现及验收入口 |
| --- | --- | --- |
| GAP-01 **已编码（本地）** | Registry/Router/LP 的新路径按 `userToken == poolCurrency` 直接结算；旧 TSLAx→wTSLAx 配置在本地回归中被拒绝 | 真实 wTSLAx 生产接入、实际代理和法律股数公式仍需外部证据；不增加路径选择或 LP 路径字段。由于没有历史旧仓位，不实现旧仓位兼容分支。验收 A05/A06 |
| GAP-02 **已编码（本地标准夹具）** | `ERC8056TestToken + ERC8056LegalShareAdapter` 已覆盖 `DIRECT_ERC20 + ONCHAIN_DYNAMIC`、multiplier 更新、双向 Swap 和 LP 原始结算 | 真实发行方 Token 仍需逐实例审查；仅有 UI getter 不足以准入。验收 A01/A04 |
| GAP-03 **部分实现** | Registry 不重复保存静态比例；计股 Adapter 提供同一快照下的正向计账和只读 raw 反算；Adapter 可在资产暂停、无活跃池时换版并记录权益依据 | V1 发布规则已收紧为法律股数单位切换前暂停整个 `securityId`，至少等到下一计量日且新单位 ADTV/quota 就绪；链上仍无 unitEpoch 或对发行方无预告日内变化的自动拦截，故此类资产不得准入。前端读取发行方持仓权益及 Adapter 报价，构造现有 raw Swap/LP 参数；**不新增股数输入合约入口**。验收 A02、S08/S09；详见[静态比例缺口](./STATIC_RATIO_CORPORATE_ACTION_GAP.md) |
| GAP-04 **已编码** | D-33：Quota 支持 SET/CLEAR、逐日版本和可选覆盖；无覆盖时使用 ADTV/Tier 硬上限，CLEAR 不重置已用量；报告由持有对应角色的地址直接提交 | 同步 ABI、角色运营流程和索引器；验收 D06/D07/D09 |
| GAP-05 **已编码** | D-34：每个 UTC 日期自动形成 TSV 计量日；日切起点支持未来排期、最多 ±4 小时调整、过渡日锁定和可取消的待生效配置 | 同步部署清单、ABI、索引器及报告服务；本部署无旧 SIP 日账，不实现历史额度迁移。验收 D04/D05/P03 |
| GAP-06 **已编码、本地测试** | 六代理仅保存固定 Anchor，动态读取当前 Authority/Timelock/事故控制器；Council 提议、当前 Guardian 批准，六代理升级目标预配置后原子切换；Council 身份恢复也须 Guardian 对具体排期批准 | 目标链部署顺序、迁移前后存储布局及真实多签/Guardian/Council 权限仍须独立验收；见 G09 |
| GAP-07 **已编码** | Router 和 LP Manager 对直接结算的输入、输出同时校验发送方扣除与接收方增加的精确余额变化 | 本地故障代币覆盖发送方额外扣费并验证整笔回滚；仍需按 A03 在固定依赖/目标网络完成验收，见安全评审 F-05 |
| GAP-08 **运营方案已定** | 发行方代理升级不由链上自动检查；由链下监控发现后触发暂停和复审 | 交付监控数据源、告警、暂停/复审 runbook，并留存升级证据；链上不读取外部代理实现地址或 codehash。 |
| DEPLOY-01 **脚本已编码、本地预测已测试** | V1 是全新六代理实例组；`DeployGovernanceV1` 与 `DeployCoreV1` 分阶段部署，Hook/Router/LP 循环地址经本地真实 CREATE/CREATE2 回归 | 按[全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md)完成治理绑定、SBT 配置、角色配置和发布后状态快照；脚本尚未在目标链广播，后续 UUPS 升级仍执行存储布局检查 |

## 3. 文档尚未闭合的编码决策

这几项有方向性设计，但**不能直接按现有文字生成完整目标合约**。实现前须在对应规范冻结精确类型、状态迁移、失败语义和升级兼容性。

| ID | 尚缺的规格 | 应补入的规范 |
| --- | --- | --- |
| SPEC-01 | Anchor ABI 和状态机已按双批准方案编码；部署/迁移 runbook、候选三合约代码哈希审查和升级存储布局仍需发布验收 | [编码规格 §9](./CODING_SPEC_V1.md)和[架构 §2.3](./CONTRACT_ARCHITECTURE.md) |
| SPEC-02 | V1 已决定不在一个计量日混用法律股数单位；仍需确认每只生产资产的发行方预告期、法律生效时间与暂停可达性。链上没有自动识别无预告单位变化的机制 | [固定比例缺口](./STATIC_RATIO_CORPORATE_ACTION_GAP.md)和[准入标准 §4](./TOKEN_ADMISSION_STANDARD_V1.md) |

前端股数展示/换算不要求新合约入口；但每种资产的**账户持仓权益函数**仍须在发行方准入清单中给出。逐笔 `toLegalShares(raw)` 不能自动充当用户钱包的精确持仓读数。

## 4. 外部准入与发布阻断

这些项目不是再添加一个 Solidity 函数就能证明完成。

| ID | 待取得的证据或交付物 |
| --- | --- |
| EXT-01 | 发行方和法务确认 TSLAx/wTSLAx 的**逐笔法定股数公式**、账户持仓权益、手续费计量口径、公司行动单位及拒收强退的方案 A；批准前保持 `UNREVIEWED` |
| EXT-02 | 实际 TSLAx/wTSLAx 代理 ABI、管理员、制裁、wTSLAx 精确转账、`getCurrentMultiplier()` 的有界 gas 与恢复能力；发行方代理升级由链下监控发现，监控告警后的暂停和复审流程须留证；安全评审 F-01 的条件风险未被真实实例排除 |
| EXT-03 | 锁定 `lib/v4-core` 的可重现版本；独立构建并集成固定的 SmartWalletSbt 与 Backed 源码。当前本地集成使用真实 V4 PoolManager，但 SBT 与发行方资产仍用行为 mock |
| EXT-04 | 固定区块 X Layer 只读/受控路径、Router EOA 独立 EIP-712 向量、fuzz/invariant、存储布局升级回归、最坏 gas、目标链部署/Hook salt manifest 和监控；本地 ERC-1271 授权与真实六代理 CREATE/CREATE2 地址预测已有回归，仍需逐项按[测试规格](./TEST_SPEC_V1.md)留证 |
| EXT-05 | 已建立 Git 基线提交 `11171f1`，并在 `868906e` 固化报告直写 ABI；提交冻结当前 `src/`、`test/`、`docs/`、配置、测试夹具、三项 Git 子模块指针及仓库内 `lib/v4-core` 源码快照；`lib/v4-core` 仍不是上游 Git 子模块，后续需补充上游来源/版本证明和固定构建证据，本文不能代替线上部署审计 |

## 5. 验证状态与执行顺序

当前 `test/unit/v1/`、`test/unit/legacy/` 和 `test/integration/local/` 有确定性测试源码。2026-10-01 本地完整套件为 **60 个通过、0 个失败、0 个跳过**；新增 ERC-1271 授权绑定/nonce、双侧异常扣费回滚、SBT 故障与 ABI 拒绝，以及真实六代理 CREATE/CREATE2 地址预测、Anchor 双批准迁移和旧根失权回归，以及 256 组 ERC-8056 反算 fuzz。via-IR 构建将 Registry 压至 EIP-170 限制以内。结果只证明本地源码，不替代固定区块真实 wTSLAx、SBT、发行方代理、真实多签与部署核验。GAP-03 的链上 unitEpoch/自动暂停仍未实现，GAP-08 及 EXT-01～05 仍需交付或留证；没有旧链上状态，不需要旧 LP 或旧 SIP 账本迁移。
