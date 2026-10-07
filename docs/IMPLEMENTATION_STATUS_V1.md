# TSV V1 实现状态

> **2026-10-07 Wrapped Swap ## 当前 Wrapped 交付状态

Registry 与单池 Wrapped Swap 已编码；Router 支持 U↔Q 四条 exact-in/exact-out 路径，原版 W/PM 结算、一次回调与策略快照、精确双侧转账、surplus 不变、严格 exact-out 和不可变 PM/R 升级检查均已落地。external Adapter 入口立即拒绝，旧白名单移除。共享 `PermissionedValidationLib` 继续无存储，供 Registry 准入与 Router 策略校验使用；资金与上下文留在 Router。

当前验收记录、代码尺寸、库链接、ABI/layout 见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)。生产 Wrapped LP 源码尚未迁移；测试 seed 不属于生产制品。manifest readiness 保持 false，真实发行方/生产 SBT/目标链及流动性证据另行验收。

## 历史实现记录

更新：** Registry 与单池 Wrapped Swap 已实现，用户收付 U/Q，池内结算 W/Q。当前 ABI、库链接与验收边界见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)，当前运营步骤见 [W/U/Q 开通流程](./OPENING_A_STOCK_MARKET_V1.md)。下文旧 DIRECT、TokenConfig/getToken、DEX 与 LP 成功路径属于历史版本；生产 Wrapped LP 及真实资产/目标链验收仍待交付，历史测试数量不代表当前覆盖。

更新：2026-10-05。本文是当前工作区的状态看板：记录源码已实现什么、还缺哪些实现或外部证据。目标流程见[三系统总览](./SYSTEMS_OVERVIEW.md)，行为规范见[编码规格](./CODING_SPEC_V1.md)和[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)，目标验收条件见[测试规格](./TEST_SPEC_V1.md)。日期评审保留其当时结论，不自动代表当前实现。

**状态用语：**“已编码”表示源码存在；“部分实现”表示仍缺目标行为或自动防护；“外部阻断”表示须取得发行方、法务或目标链证据。测试规格是目标清单，不代表所有测试已执行。

所有领域的剩余测试和验收工作已去重至[测试缺口统一清单](./TEST_GAPS_V1.md)，本文继续维护实现及历史执行状态。

## 1. 当前实现与缺口

| ID / 状态 | 当前实现 | 尚缺事项或限制 |
| --- | --- | --- |
| GAP-01 **已编码（本地）** | Registry、Router 和 LP Manager 只直接结算唯一池内 Currency；旧 TSLAx→wTSLAx 用户结算组合不在当前 ABI | 真实 wTSLAx 实例及法律计股依据仍待准入；本部署无旧仓位迁移，验收见 A05/A06 |
| GAP-02 **已编码（本地行为 mock）** | 唯一 `BackedAutoFeeLegalShareAdapter` 已接入 Hook；实际股票腿在 `afterSwap` 直接调用来源 Token `getUnderlyingAmountByShares(rawShares)`，本地 V4 集成覆盖两方向 Swap 与 LP | 本地来源/Wrapped mock 不构成真实发行方证据；真实代理、转换方法语义和法律计量仍须逐实例审查，验收见 A01/A04 |
| GAP-03 **部分实现** | 直接换算接口已取代 RateSnapshot、rateId 与反向 raw 换算；Hook 在 `afterSwap` 换算，Ledger 校验正/零 shares 与 Registry 元数据后记账；Adapter 可受控版本替换 | 成交事件只记 Adapter 版本，不记录实时发行方参数；链上没有 unitEpoch，也不能拦截未预告的法律股数单位变化。拆并股额度已按 D-37 支持未来日独立系数；实际成交仍实时 Adapter 计股。来源法律单位异常时须暂停并在口径一致的新日恢复；无足够预告期的资产不得准入。流程见[准入标准 §4](./TOKEN_ADMISSION_STANDARD_V1.md#4-公司行动与数据单位) |
| GAP-04 **已编码** | DataInbox 接受角色地址直写的 Market、ADTV、可选 Quota 和未来日 SplitFactor；支持 quota SET/CLEAR、版本顺序和硬上限 | 生产报告服务、索引器与角色操作留证仍须准备；规则见[编码规格 `7](./CODING_SPEC_V1.md#7-角色报告计量日和额度) |
| GAP-05 **已编码** | VolumeLedger 按 UTC 与可配置起点自动生成计量日；支持未来排期、偏移边界、过渡日锁定和取消待生效配置 | 生产报告服务与索引器须采用同一日切规则；部署与验收见[部署清单](./DEPLOYMENT_CHECKLIST_V1.md)及 D04/D05/P03 |
| GAP-06 **已编码，本地回归通过** | 独立 Authority 与治理根迁移已移除；唯一固定 Anchor 直接保存 Governor/Guardian/Council 和升级开关；Council 提案、当前 Guardian 批准后可恢复 Governor/Guardian | Anchor 不可升级，Council 固定；本版用于全新部署，目标链部署与真实多签恢复仍须独立核验；验收见 G09 |
| GAP-07 **已编码** | Router 和 LP Manager 对直接结算校验转出、PoolManager 和最终收款方的实际余额变化；非精确转账整笔回滚 | 真实发行方 Token 与目标链仍须执行 A03 及固定依赖验证；相关安全评审见 F-05 |
| GAP-08 **运营方案已定** | 不在链上自动监控发行方代理升级；监控发现后由运营暂停并复审 | 监控数据源、告警、暂停/复审 runbook 和升级证据留存仍待交付 |
| GAP-09 **已编码，本地回归通过** | GLOBAL/SECURITY/TOKEN/POOL 紧急暂停与市场 HALT 支持 TRADE/LP/ALL；市场按模式叠加/恢复，交易与普通 LP 门禁分离，授权强退继续可用 | 本版按首次部署更新暂停、MarketReport、事件及计数查询 ABI；无旧暂停状态迁移。生产报告服务和索引器须采用新模式字段 |
| GAP-10 **已编码，本地回归通过** | admitSecurity 原子登记证券及批准首个 Currency；registerToken 登记即批准；取消待审、市场未初始化及首次开市报告，准入后默认 OPEN；市场状态由暂停模式推导 | 报价币已获批时首次运营调用从六次减为三次；ADTV 与建池独立，缺 ADTV 时可提供 LP，但 Swap 全部回滚。准入与真实 V4 回归通过，包含准入回滚的 256 次 fuzz；本版用于全新部署，无旧 ABI/存储迁移 |
| GAP-11 **已编码** | TimeLock 与专用 Executor 已移除；Governor 单笔 UUPS 升级并初始化，Anchor 支持六代理原子批量升级；恢复提案移至 Anchor；事故控制器已移除，Guardian 可冻结/解冻所有升级，身份恢复不自动解冻 | 新部署初始化 ABI 已简化为 Anchor 与业务依赖；发布仍须验证布局与批量初始化调用者，验收见 G02/G05/G07 |
| GAP-12 **已编码，完整回归通过** | 独立 `SplitFactorReport` 精确比例按未来计量日开始自动生效，ADTV/Tier 保持；最新未生效项更正/取消；来源月基准、跨月防重复、版本/ID、防溢出、绝对 quota、升级保留 | 报告服务须固定月末单位与公告排期，发行方单位/监控及生产联测仍需证据；实际 Adapter 计股不新增通用归一化，见 TG-10/TG-12 和 D10–D13 |
| GAP-13 **已编码** | 业务入口、TokenConfig、证券/报告/暂停/恢复/日切结构与事件已移除 hash 参数；部署脚本和 manifest 不再接收代码哈希输入。保留业务 ID、原因码、salt、权限、报告去重/序号和内部回调哈希 | 函数/事件 ABI 与存储布局已改变，须全新部署；链下审查材料按业务 ID、资产地址和交易记录归档；禁止直接升级旧布局实例 |
| DEPLOY-01 **脚本已编码，本地预测已测** | DeployGovernanceV1 与 DeployCoreV1 分阶段部署；六代理地址及 Hook 依赖 Router/LP Manager 地址的 CREATE/CREATE2 预测有回归 | 尚未在目标链广播；按[部署清单](./DEPLOYMENT_CHECKLIST_V1.md)完成绑定、SBT、角色及发布后快照 |

## 2. 规格与发布门禁

### 规格待闭合

| ID | 尚待确认 | 权威来源 |
| --- | --- | --- |
| SPEC-01 | 固定 Anchor 构建与部署来源、身份恢复演练和业务代理升级存储布局检查仍须作为发布证据完成 | [编码规格 `9](./CODING_SPEC_V1.md#9-代理角色和升级)、[部署清单 `9](./DEPLOYMENT_CHECKLIST_V1.md#9-治理身份恢复和升级) |
| SPEC-02 | 每个生产资产的发行方预告期、法律生效时间和可暂停性须确认；链上无法自动识别未预告的法律单位切换 | [准入标准 `4](./TOKEN_ADMISSION_STANDARD_V1.md#4-公司行动与数据单位) |

前端股数展示及换算使用发行方认可的持仓权益定义，并把结果换算为现有 raw Swap/LP 参数。逐笔 Adapter 的 `toLegalShares` 不能替代用户账户持仓权益读取；当前 Adapter ABI 也不提供从股数预算反算 raw 数量的方法；V1 不增加股数输入合约入口。

### 外部证据与交付

| ID | 尚待取得的证据或交付物 |
| --- | --- |
| EXT-01 | 发行方与法务确认 TSLAx/wTSLAx 的逐笔法定股数公式、账户权益定义、成交量费用口径、公司行动单位及拒转强退方案；证据未齐不得准入；未登记为 ABSENT |
| EXT-02 | 核验真实代理 ABI、管理员、制裁/暂停权限、wTSLAx 精确转账、`getUnderlyingAmountByShares` 调用 gas 与返回语义，并留存代理升级监控及暂停复审证据 |
| EXT-03 | 固定 V4 上游来源和可重现版本；分别构建并通过薄接口集成 SmartWalletSbt 与 Backed 产物 |
| EXT-04 | 完成固定区块 X Layer 核验、fuzz/invariant、存储布局升级回归、最坏 gas、Hook salt manifest、目标链部署演练及监控留证 |
| EXT-05 | 补充仓库内 lib/v4-core 的上游来源/版本证明和固定构建记录；Git 基线及报告 ABI 变更记录已建立 |

## 3. 本地验证记录

2026-10-05 移除业务 hash 参数后的完整优化回归：`make test` **372 通过、0 失败、0 跳过**（unit 235、local 137，63 个不联网套件），包含 7 项 invariant（默认每项 64 轮 × 32 步）和默认 256 次 fuzz。固定 X Layer 区块 **72,271,000 / chainId 196** 的 `make test-xlayer` **11 通过、0 失败、0 跳过**。`make check` 通过；8 个 TSV 合约的编译 ABI 均无 hash 参数、返回字段或事件字段，最大运行时代码为 Registry 的 **17,443 字节**。文档中 8 处结构体字段顺序与源码一致，当前文档链接校验通过；manifest 使用 `tsv-v1-deployment-5`。本轮改变 ABI 与存储布局，须全新部署。日志在忽略的 `out/hash-parameter-tests.log`、`out/hash-parameter-xlayer.log`，ABI/体积校验记录在 `out/hash-parameter-validation.json`。下方为此前版本的历史执行记录。

2026-10-01 旧 Swap Adapter/状态设计下的历史完整套件记录为 **62 个通过、0 个失败、0 个跳过**，包含已删除的 ERC-8056 反算测试，不作为当前实现的验证。2026-10-02 直接换算 Adapter 和 Hook 流程变更后，`FOUNDRY_PROFILE=unit forge test --summary` 为 **38 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --summary` 为 **23 通过、0 失败、0 跳过**；`FOUNDRY_PROFILE=unit forge build --skip test --sizes` 编译成功。本次覆盖 Backed Adapter 的 source/currency/零值校验及接入真实 V4 的两向 Swap、LP raw 结算。合约未部署，因此当前 Router/Hook 布局按新实现直接定义，不保留旧 Swap 专用槽。

2026-10-03 三种暂停模式实现后，`FOUNDRY_PROFILE=unit forge test --offline` 为 **58 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --offline` 为 **82 通过、0 失败、0 跳过**；local 包含 Position ID 测试继承执行的集成用例。`forge build --offline --sizes` 编译成功，Registry 运行时代码为 **18,318 字节**。回归覆盖四种 scope × 三种 mode、紧急记录叠加/逐条清除、市场部分恢复与无变化请求回滚、新事件模式字段、直接及 Adapter Swap、五种普通 LP 操作、暂停期间强退、建池和 Adapter 替换门槛；Position ID 的 8 项验证继续通过。

2026-10-03 治理简化后，`FOUNDRY_PROFILE=unit forge test --summary` 为 **72 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --summary` 为 **88 通过、0 失败、0 跳过**。覆盖 Governor 单次升级/初始化、初始化失败回滚、绑定代理批量升级及整批回滚、非治理身份拒绝、恢复/迁移后旧权限失效，并保留 LP Position ID 升级兼容性回归。治理部署改为 Anchor 构造时原子创建并绑定组件，初始化 ABI 仅接收 Anchor 和业务依赖。

2026-10-03 全局升级冻结实现后，`FOUNDRY_PROFILE=unit forge test --summary` 为 **74 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --summary` 为 **90 通过、0 失败、0 跳过**。事故控制器与独立升级入口已删除；开关存放在固定 Anchor，六代理和批量入口共同检查。回归覆盖六个真实代理的冻结/解冻、绑定前冻结、非 Guardian 拒绝、零证据与旧 freezeId 拒绝、Governor/Guardian 恢复与治理根迁移保持冻结，以及冻结期间真实 V4 Swap、LP 增减/收取/关闭仍正常执行。local 包含继承执行的集成用例。`FOUNDRY_PROFILE=unit forge build --skip test --sizes` 编译通过，六业务合约和 Anchor 均在运行时大小限制内；`forge fmt --check`、`git diff --check` 通过。

2026-10-03 单 Anchor 治理实现后，`FOUNDRY_PROFILE=unit forge test --summary` 为 **75 通过、0 失败、0 跳过**，`FOUNDRY_PROFILE=local forge test --summary` 为 **90 通过、0 失败、0 跳过**。独立 Authority 和治理根迁移已删除，Governor/Guardian/Council 直接保存在固定 Anchor；六代理直接读取当前 Governor。回归覆盖一次恢复后六代理默认管理员同步、旧 Governor 失去升级权、升级冻结与业务角色保留、取消/未经批准/旧 epoch 恢复拒绝、非法 Anchor 身份初始化拒绝、批次中恢复拒绝和单独/批量升级回滚。部署脚本与 manifest 已移除 Authority 输入。`FOUNDRY_PROFILE=unit forge build --skip test --sizes` 编译通过，Anchor 运行时代码 **7,297 字节**；本版用于全新部署，未在目标链广播。

这些记录证明当时本地源码的执行结果，不替代真实 wTSLAx、SBT、发行方代理、固定区块 fork、目标链部署和独立审计。当前测试命令及每项目标覆盖见[测试规格](./TEST_SPEC_V1.md)。

2026-10-03 治理测试补齐与测试目录重整后，完整本地套件为 **208 通过、0 失败、0 跳过**（unit 154、local 54）。公共 fixture 不再包含测试函数，Position ID 不再重复执行其他集成套件；治理新增角色/绑定/恢复/批量回滚/事件/部署校验与随机序列，真实 V4 场景验证六代理迁移前后资金、额度、暂停、仓位和 Receipt 保留。`forge coverage --ir-minimum` 的 unit 结果：Anchor 行/分支/函数均 **100%**，TSVGoverned 行 **92.86%**、分支 **90.91%**、函数 **100%**；覆盖率受 IR 源码映射影响，不能作为全部业务场景已验证的证明。`make check` 通过。真实多签和目标链广播仍是独立发布门禁。

2026-10-03 交易/LP 补齐后的最终优化回归，`make test` 为 **270 通过、0 失败、0 跳过**（unit 155、local 115），含五项治理/交易 LP invariant。覆盖新增：双向 exact-output、部分成交及最低输出边界、跨池额度和协议费、18/6 decimals、Token 拒转/少转/税/false/no-return、全部 LP 生命周期/owner/tick/滑点、第一/第二退出腿回滚、回调参数哈希与重入，以及十类混合操作的独立状态模型。原有 124 个不同名称的测试全部保留，无可执行套件继承造成的重复计数。`make check` 通过。

X Layer 固定区块 **72,271,000** 使用真实 DexRouter `0x7c5bee2a8091c3ef39072f64f18fac913060aeaf` 和授权组件，**11 通过、0 失败、0 跳过**。薄 ABI 已保存在 `lib/dexrouter-interfaces/`；测试 Adapter 由 DEX 认证追加标记提取原调用者，覆盖两向、拆单、多跳、合约钱包、指定收款人、退款、失败原子性和 LP 生命周期。入口版本 `v1.0.10-rfq-anti-arbitrage` 与公共源码版本不同，manifest 固定八个部署 codehash；公开源码仅作 ABI 依据。TSV/V4 在 fork 中新部署，发行方 Token/SBT 使用 mock，正式 Adapter、真实资产/生产 SBT/生产 TSV 与多签仍须独立验收；未向目标链广播。具体对应关系与限制见[覆盖矩阵](./TEST_COVERAGE_V1.md)。

2026-10-04 交易/LP 阶段覆盖率归档：coverage profile 的 **270 项全部通过**。Anchor 行/语句/分支/函数均 **100%**；TSVGoverned 行 **95.24%**、分支/函数 **100%**；Router 行 **98.51%**、分支/函数 **100%**；LP Manager 行 **99.30%**、分支 **77.78%**、函数 **100%**；Hook 行/函数 **100%**、分支 **77.78%**；DirectSettlementLib 四项均 **100%**。IR 源码映射与未执行的生产部署路径仍限制统计结论；完整分母、汇总及原始记录位置见[覆盖矩阵](./TEST_COVERAGE_V1.md#最终覆盖率)。

2026-10-04 运营测试 review 与补齐：固定 seed `0x20261004` 的完整本地优化回归为 **334 通过、0 失败、0 跳过**（unit 208、local 126）。运营相关 113 项、20 个套件全部通过，新增 64 项，包含两项运营模型性质。补齐报告角色/元数据/版本/拒绝重试、100 条批次原子性、Tier/证券/Token/池生命周期、SBT/Adapter 配置故障、逐入口撤权、Gregorian 边界与日切排期；真实 V4 验证额度/报告更正、跨月、20/28h 过渡日、已有仓位与费用保留。P03 新增独立季度日历/报告模型，七类动作覆盖四个月 ADTV、96 日 quota/used 与历史边界。测试目录校验为 61 个套件（含既有 fork），无可执行套件继承。真实发行方/SBT/多签、链下报告/索引/重组/告警服务、法律单位审批及最坏 gas/生产演练仍待验收；完整范围与限制见[运营测试 review](./OPERATIONS_TEST_REVIEW_V1.md)。

2026-10-04 运营阶段 coverage 也为 **334 通过、0 失败、0 跳过**。DataInbox 与 ReportValidationLib 行/语句/分支/函数均 **100%**；Registry 行 **98.41%**、分支 **95.08%**、函数 **100%**；Ledger 行 **98.61%**、分支 **84.21%**、函数 **100%**；TradeDayLib 行/函数 **100%**、分支 **71.43%**。剩余防御输入、当前入口约束不可达分支、时间模型范围和映射遗漏分别列入运营 review，未把它们统一计为已覆盖。全部非测试源码含脚本的分支汇总从 **68.97%** 提升至 **83.91%**；真实广播仍未执行。

2026-10-04 拆并股系数功能的最新优化回归：**369 通过、0 失败、0 跳过**（unit 237、local 132，63 个不联网套件），固定 seed `0x20261004`。本轮新增 35 项，运营范围现为 **148 项 / 23 个套件**。包含七项 invariant，默认每项 64 轮 × 32 步，普通 fuzz 256 次。使用独立 `out/split-factor-regression` / `cache/split-factor-regression` 从头编译，避免复用旧测试制品。

独立 coverage 运行同样 **369 通过**；固定 X Layer 区块 **72,271,000 / chainId 196** 的 DEX fork 重新执行 **11 通过、0 失败、0 跳过**。本地与 fork 分别执行，共 380 个不同用例，不把重复插桩执行计为新增用例。`make check` 通过；六业务合约和 Anchor 运行时均小于 24,576 字节。

复现：`FOUNDRY_PROFILE=default FOUNDRY_OUT=out/split-factor-regression FOUNDRY_CACHE_PATH=cache/split-factor-regression forge test --fuzz-seed 0x20261004 --summary`；fork 为 `FOUNDRY_PROFILE=xlayer forge test --fuzz-seed 0x20261004 --summary`。原始记录在忽略的 `out/`：`tsv-split-factor-all-tests.log`、`tsv-split-factor-xlayer.log`、`tsv-split-factor-coverage.log`、`tsv-split-factor-coverage.lcov`、`tsv-split-factor-check.log` 和 `tsv-split-factor-layout.json`。

系数新增两个 mapping 位于 Ledger slot 9/10，既有 ADTV、quota、used 和日切字段顺序保持；实际成交计股仍由现有实时 Adapter 决定。新增单元/真实 V4/模型覆盖及更新后的覆盖率见[覆盖矩阵](./TEST_COVERAGE_V1.md)。
