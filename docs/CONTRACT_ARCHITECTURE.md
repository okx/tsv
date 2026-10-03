# TSV V1 架构决策与设计理由

本文保存 V1 的关键决策及选择这些系统边界的原因，不重复当前流程、合约 ABI、资产准入条件、测试验收或部署步骤。阅读顺序建议为：[三系统总览](./SYSTEMS_OVERVIEW.md)了解流程；查看下表追溯决策；再按主题进入[编码规格](./CODING_SPEC_V1.md)、[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)、[测试规格](./TEST_SPEC_V1.md)和[部署清单](./DEPLOYMENT_CHECKLIST_V1.md)。实际实现状态以[实现状态](./IMPLEMENTATION_STATUS_V1.md)为准，源码位于 `src/v1/`。

依据：[TSV 合约系统 PRD 0.2](https://okg-block.sg.larksuite.com/docx/NsW1dF4VjoLRIyxJCALlGRVNg9f)。目标链为 X Layer，chainId 196。

## 决策记录

| 编号 | 决策 | 状态 |
| --- | --- | --- |
| D-01 | 已创建池的 Hook 保持原地址，逻辑可升级 | 已确认；升级权限与路径见编码规格 `9 |
| D-02 | 同一 Registry 下所有池共用证券成交账本 | 已确认 |
| D-03 | 禁止股票 Currency 与股票 Currency 配对 | 取代早期双股票池方案 |
| D-04 | 股票输入按含费总支出、输出按净到账计量 | 技术口径已选；法律口径待书面确认 |
| D-05 | 强退只向原 LP owner 交付；发行方拒转时整笔回滚 | 已确认 |
| D-06 | 本部署只有一个 TSV 交易平台 | 已确认；venue 定义见编码规格 `7 |
| D-07 | 不以美国常规交易时段作为链上交易门禁 | 已确认 |
| D-09 | 不在 PoolConfig 保存 venueId | 已确认 |
| D-10 | 旧 SIP 休市归属规则 | 已由 D-34 取代，仅保留决策历史 |
| D-11 | 初始池价格由 POOL_CREATOR 提交 | 已确认；合约校验 V4 价格范围并记录依据 |
| D-12 | Governor 在全局未冻结时单笔即时升级 | 已确认；具体权限见编码规格 `9 |
| D-13 | Governor 常规升级一笔完成，包括可选初始化 | 已实现；直接调用 UUPS upgradeToAndCall |
| D-14 | 移除 TimeLock 与升级排期 | 已实现；多代理可用 Anchor upgradeBatch 原子升级 |
| D-15 | 独立 Guardian 可冻结/解冻所有升级入口 | 已确认 |
| D-16 | Guardian 可撤回身份恢复批准 | 普通升级排期已移除；统一升级冻结保留，身份恢复不自动解冻 |
| D-17 | 独立 RecoveryCouncil 提议受保护的治理身份恢复 | 已确认；执行须当前 Guardian 批准 |
| D-18 | 业务管理员使用共享的非代理权限根 | 已确认；切换细节见编码规格 `9 |
| D-19 | 市场准入后默认开放，仅停复牌时提交报告 | 已确认；取消首次开市报告，状态从暂停模式推导，不要求定时心跳 |
| D-20 | 池内 Currency 须 raw 余额稳定且双侧转账精确 | 准入标准定义审查门槛 |
| D-21 | 开放的 LP 仓位必须保持正流动性 | 已确认 |
| D-22 | 拒绝 100% 费率和零输出 Swap | 已确认 |
| D-23 | ADTV 按适用月份提交；日配额仅作可选覆盖 | 已确认；取代日配额跨日必报规则 |
| D-24 | Tesla 候选计股按发行方显示份额公式 | 技术选择已确认；发行方与法务依据待核验 |
| D-25 | 旧 TSLAx 同笔包装/赎回路径 | 已由 D-31 取代，仅保留决策历史 |
| D-26 | V1 不自建 Wrapped 资产 | 已确认 |
| D-27 | 旧 TSLAx 用户路径的显示数量边界 | 已由 D-31 取代，仅保留决策历史 |
| D-28 | 结算准入与法律股数计量分别审查 | 已确认 |
| D-30 | 每笔 Swap 只经过一个池；已接受报告不按时间自动失效 | 已确认 |
| D-31 | 用户只直接收付池内 Currency；Tesla 候选池使用 wTSLAx | 目标已确认；生产资产仍待逐实例准入 |
| D-32 | Hook 代理地址预留 V4 回调与返回 delta 权限 | 已确认；V1 当前不启用非零 Hook delta |
| D-33 | 日配额报告是指定计量日的可选覆盖 | 已编码 |
| D-34 | 计量日按 UTC 日期和可配置起点计算，可排期调整未来起点 | 已编码；算法见编码规格 `7 |
| D-35 | 治理根迁移 | 已移除；固定 Anchor 直接保存治理身份，身份变更仅走 Council + Guardian 恢复 |
| D-36 | 股票 Currency 绑定直接换算 LegalShareAdapter，不保存 rate snapshot 或反算接口 | Backed AutoFee Adapter 已接入 Hook；真实发行方方法与法定股数口径待逐实例审查 |
| D-37 | 拆并股额度 | 保留上月日均 ADTV × Tier，独立精确系数仅在未来计量日开始自动生效；相对来源月单位、换月避免重复；最新待生效项可更正/取消，成交继续实时 Adapter 计股。见编码规格 §7。 |
| D-38 | Router 的多池路由能力缺口需结合 SBT 准入模型评估实际需求 | 能力差异已确认；业务需求与是否扩展待评估 |
| D-39 | LP Manager 需要支持一次请求内原子批量处理多个仓位动作 | 批处理需求已确认；动作范围及实现方案待设计 |
| D-40 | 证券及首个 Currency 原子准入，取消链上待审流程；ADTV 与建池保留独立角色 | 已编码并有本地回归；报价资产可复用，PENDING 仅用于同笔建池回调校验；本版按全新部署重构 |

## 关键设计理由

### 用户资格由 TSV 入口统一执行

用户必须经 Router 或 LP Manager 进入，Registry 为 Swap 和普通 LP 操作提供同一份 SBT 资格判断。若只在某条入口检查，直接进入其他执行路径可能绕开参与者身份、请求边界或额度约束。当前函数与调用约束见[三系统总览](./SYSTEMS_OVERVIEW.md)和[编码规格](./CODING_SPEC_V1.md)。

### Router 的多池路由需求须按 SBT 场景评估

当前 [TSVSwapRouterV1](../src/v1/periphery/TSVSwapRouterV1.sol) 提供用户直连的单池 exact-in/exact-out，以及供外部白名单 Adapter 调用的单池 exact-in 入口；TSV Router 本身不提供多跳路径或把多个 Swap 与结算动作编码到同一请求。外部 DexRouter 可通过其现有 Adapter 分发接口把 TSV 池作为路由中的一跳，Adapter 仍须把原始调用者身份带入 TSV 资格门禁。官方 [V4Router](../lib/v4-periphery/src/V4Router.sol) 提供 exact-in/exact-out 单池及多跳 action 处理逻辑，并可在一次 PoolManager unlock 中结算；它是抽象合约，需要具体入口合约承接交易。

这是已确认的能力差异，但是否构成 TSV 的业务缺口仍待评估。SBT 资格门禁可能意味着用户只需在获准的池中直接交易；若当前产品不需要中间资产路径，增加多跳的收益有限。若确有更优流动性或跨池路径需求，则每条路径都必须绑定发起用户的 SBT 资格，并逐跳检查 Registry 池状态及 Hook 约束。多跳还会改变 D-30“每笔 Swap 只经过一个池”的边界；扩展前须明确同一请求内每个证券 Swap 的额度记账口径，尤其是路径重复经过同一证券或池时如何避免错误计量。此记录确认能力缺口，不代表已批准开放多跳。

### LP Manager 需要原子批处理

当前 [TSVLPManagerV1](../src/v1/periphery/TSVLPManagerV1.sol) 将开仓、加仓、减仓、收取费用和关仓拆成独立入口；每个入口单独执行一次 PoolManager unlock，不能把多个仓位动作组合成一笔原子请求。用户因此无法在一个交易中组合例如收取费用后调整仓位，多个调用之间也不能共同回滚。批处理需求已确认。

官方 [PositionManager](../lib/v4-periphery/src/PositionManager.sol) 的 `modifyLiquidities` 通过 Actions 在一个 unlock 内组合 mint/increase/decrease/burn 与结算动作，可作为交互模型参考；这不意味着直接替换 TSV Manager。TSV 批处理仍须逐项执行调用者 SBT 资格、每个仓位的 Receipt owner、池可交易状态、tick/流动性与余额边界校验，并维持 Hook 对当前 LP 操作的授权上下文。应先定义允许的动作集合、同批是否允许跨池/跨仓位、单个调用者能否操作多个自有仓位，以及任何一步失败时整批回滚；管理员 `forceExit` 保持独立的恢复流程，不与普通用户批次混用。

### 池内资产与用户结算资产保持一致

Router 和 LP Manager 直接收付 PoolKey 中的 Currency，使用户余额变化、PoolManager 原始余额和 V4 结算 delta 使用同一资产单位。发行方包装或赎回留在 TSV 之外；能否入池与它代表多少法定股数是两项独立审查，具体门槛见[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)。

### 成交量以成功 Swap 的实际变化为准

额度账本从 V4 实际 Swap delta 计量并与 Swap 原子提交，避免依赖用户声明金额或链下事后修正。按证券聚合使同一平台的多个池共享限制；UTC 计量日和报告规则由[编码规格 `7](./CODING_SPEC_V1.md#7-角色报告计量日和额度)统一定义。

### 当前 Governor 管理业务与升级

日常角色、业务参数和代码升级由当前 Governor 管理；单代理升级与初始化在同一笔调用完成，多代理可通过 Anchor 批量原子升级。六个业务代理绑定唯一固定 Anchor，由其直接保存 Governor/Guardian/Council；更换负责人仅走受保护身份恢复，升级冻结状态保留；具体身份、批准和状态转换见[编码规格 `9](./CODING_SPEC_V1.md#9-代理角色和升级)及[部署清单 `9](./DEPLOYMENT_CHECKLIST_V1.md#9-治理身份恢复和升级)。

### 强退保留原 owner 的资产请求权

强退只能向仓位原 owner 交付。如果发行方或另一侧 Token 拒绝转账，整笔交易回滚并保留仓位可重试；管理员不能把资产改发给其他地址。此准入风险和验收用例分别见[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)和[测试规格](./TEST_SPEC_V1.md)。

## 规范来源

- 当前交易、运营和治理流程： [三系统总览](./SYSTEMS_OVERVIEW.md)
- 当前 ABI、字段、权限和算法： [编码规格](./CODING_SPEC_V1.md)
- Currency 与计股准入： [代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)
- 目标行为及其测试证据： [测试规格](./TEST_SPEC_V1.md)
- 当前实现和未闭合门禁： [实现状态](./IMPLEMENTATION_STATUS_V1.md)
- 部署顺序与生产配置： [部署清单](./DEPLOYMENT_CHECKLIST_V1.md)
