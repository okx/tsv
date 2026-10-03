# TSV V1 测试覆盖矩阵

更新：2026-10-04。这里按业务行为解释测试完整度；具体规范编号见[测试规格](./TEST_SPEC_V1.md)，运行与维护规则见[测试说明](../test/README.md)。百分比衡量被触达的源码位置，不能证明所有输入或状态组合正确。

后续待办以[测试缺口统一清单](./TEST_GAPS_V1.md)为准；该清单合并各领域限制，并补记 Ledger、初始化、ERC-8056 与区块时间的直接补测项。本文保留已执行覆盖与统计证据。

## 原有缺口与补齐方式

| 领域 / 对应规格 | 原有缺口 | 当前用例 |
| --- | --- | --- |
| 治理 G02–G15 / P06 | 角色内部路径、完整恢复生命周期、绑定交叉链接、批量任意位置失败、事件、部署校验及状态序列不足 | `unit/v1/governance/`；四项独立模型 invariant；`local/governance/SixProxyMigration.t.sol` 在已注资真实 V4 环境升级六代理并验证回滚/状态保留 |
| Swap S04–S06 | exact-output 两方向、金额/限额/过期边界、部分成交和重试缺完整余额检查 | `local/trading/Boundaries.t.sol`：输入 fuzz、inclusive deadline、PoolKey 各字段、两侧实际到账、最低输出/最高输入失败全快照回滚、同请求再次成交 |
| 计股 S01–S03 / D07 | 协议费、真实多池共享 quota、不同精度 Currency 的端到端验证不足 | `local/trading/Accounting.t.sol`、`Precision.t.sol`：实际含费股票支出；跨两个真实池累计同一证券额度；18/6 decimals 的 Swap/LP raw 结算 |
| Swap S07–S10 / S12 | 恶意 Token、回调、source 故障与极端 signed delta 防御覆盖不足 | `local/trading/Settlement.t.sol`、`DeltaGuards.t.sol`、`HookCallbacks.t.sol`、`IssuerFailures.t.sol`：两方向/两模式 recipient tax、false/short/no-return、重入、source 零值/revert、int128.min、调用者/HookData 校验 |
| LP L01–L05 / L10–L12 | 输入/tick/owner/deadline 组合、无费/重复领费、关闭本金与未领费、两 owner 同范围分离不足 | `local/liquidity/Boundaries.t.sol`；`local/trading/Accounting.t.sol`：非法输入全部回滚；先领费再关闭与一次关闭到账相同；同范围两 owner 的费用和仓位独立 |
| LP A03 / L06–L09 / S12 | funding/exit/collect 的 Token 故障矩阵、所有入口重入、Hook context 缺逐字段检查 | `local/liquidity/Settlement.t.sol`、`DeltaGuards.t.sol`、`HookCallbacks.t.sol`：五种普通 LP 操作和强退失败保持原仓位/Receipt/余额；`IssuerFailures.t.sol` 分别使第一/第二结算腿拒转并验证重试；畸形 context/mode/sign 拒绝；授权 admin 独立强退 |
| 交易 + LP P01/P02/P04/P05 | 单个成功用例无法证明任意操作先后次序保持一致 | `local/trading/StatefulTradingLP.t.sol` 与独立 Handler：十类操作、两个 owner、七个连续日、quota 下调/CLEAR、来源 multiplier、SBT/暂停、强退；逐步比较 TSV/V4 liquidity、Receipt、资产总量、每日成交股数、失败快照及零欠款 |
| DEX 原始身份 | 原 Adapter mock 接受任意 participant，不能证明真实 DEX 身份传递 | 测试 Adapter 只接受指定 DEX callback，身份来自经过验证的追加 marker；本地 `DexAdapter.t.sol` 检查伪造 caller、长度/前缀/零身份、错路由、授权清理和捐赠余额保护 |
| DEX + TSV 完整流程 | 真实 DEX/授权组件入口未落地 | `xlayer/DexRouterFlow.t.sol` 固定区块调用用户指定地址：双向、拆单、多跳、合约钱包、指定收款人、退款、暂停/撤权、DEX 滑点失败全回滚及 LP 生命周期；部署 manifest 验证八个 codehash |
| 运营 R01–R09 / D01–D09 | 报告 metadata/批次边界、Tier 与上下架、配置故障、日切和额度更正缺直接证据 | `unit/v1/registry/`、`unit/v1/reports/` 及 `local/operations/`：逐入口角色与撤权、报告拒绝快照/修正重试、100 条批次原子性、资产生命周期及真实 V4 更正/跨月/20–28h 日切；逐项见[运营 review](./OPERATIONS_TEST_REVIEW_V1.md) |
| 运营随机序列 P03 | 报告/日切只验证个别确定性例子 | `reports/StatefulOperations.t.sol`：八类报告/额度/系数/时间/排期/权限动作，两项独立模型性质；四个月 ADTV 与因子检查点、96 日 quota/used/边界、失败 ID/sequence/sourceTime 保留，季度/月末/跨年确定性序列 |
| 拆并股 D10–D13 | 缺独立比例及未来日自动生效能力 | `reports/SplitFactor.t.sol`、`SplitFactorBoundaries.t.sol` 和 `local/operations/SplitFactorFlows.t.sol`：精确比例、日边界、连续/换月、latest-only 更正/取消、防重放/算术拒绝、绝对 quota、真实 V4、资金与排期升级保留；P03 模型加入独立线性因子查询 |
| 报告/暂停/仓位 ID | 原有测试散落、Position ID 继承导致重复执行 | 保留原有具名测试，拆分至 reports/registry/liquidity 等目录；fixture 没有测试方法，脚本禁止套件继承套件 |

故障 PoolManager 的 mocked delta/context 用例只证明拒绝非法外部返回值；成功流程使用真实 V4。DEX callback caller 本地替身只用于注入畸形输入，真实调用者身份由 X Layer fork 独立验证。

## 验证边界

1. X Layer DEX 与授权合约为真实链上状态；TSV、V4 PoolManager 与测试池在 fork 内新部署，股票/Wrapped/SBT 为行为 mock。真实发行方资产、生产 SBT 与生产 TSV 写路径尚未验收。
2. 测试 Adapter 是测试专用代码。正式 Adapter 的设计、代码审查、部署/白名单仍需另行交付；此次不把测试替身发布到生产链。
3. GovernorExecutor 验证合约调用，不能代替真实 Safe 的签名门槛、模块与账户恢复演练；生产候选实现仍需单独检验存储布局、迁移参数与 gas。
4. DEX 固定 ABI 覆盖已实际调用的 ERC20 DAG 路由，不代表 DEX 自身的 RFQ、native、permit、佣金或所有协议均通过；公共仓库源码版本与指定部署不一致，测试固定链上字节码与版本。
5. 随机序列覆盖受控模型范围：交易/LP 为七个连续交易日、固定费用/范围、两位 owner；运营模型为单证券、固定 Tier、2026 年第四季度至 2027 年首日的报告/日切交错。闰日、世纪年份、配置故障和多证券独立性另有确定性/fuzz 用例。P03 已有独立模型，不等于任意长历史、证券/Tier/发行方故障组合的穷举。
6. IR minimum coverage 有源码映射限制；已经实际执行的成功/失败路径仍可能留有未计入的行/分支。业务模型、资金回滚和具体用例比单一覆盖率更能说明测试结论。

## 执行记录

2026-10-04 拆并股系数功能的最新优化回归：**369 通过、0 失败、0 跳过**（unit 237、local 132，63 个不联网套件），固定 seed `0x20261004`。本轮新增 35 项，运营范围现为 **148 项 / 23 个套件**。包含七项 invariant，默认每项 64 轮 × 32 步，普通 fuzz 256 次。使用独立 `out/split-factor-regression` / `cache/split-factor-regression` 从头编译，避免复用旧测试制品。

独立 coverage 运行同样 **369 通过**；固定 X Layer 区块 **72,271,000 / chainId 196** 的 DEX fork 重新执行 **11 通过、0 失败、0 跳过**。本地与 fork 分别执行，共 380 个不同用例，不把重复插桩执行计为新增用例。`make check` 通过；六业务合约和 Anchor 运行时均小于 24,576 字节。

复现：`FOUNDRY_PROFILE=default FOUNDRY_OUT=out/split-factor-regression FOUNDRY_CACHE_PATH=cache/split-factor-regression forge test --fuzz-seed 0x20261004 --summary`；fork 为 `FOUNDRY_PROFILE=xlayer forge test --fuzz-seed 0x20261004 --summary`。原始记录在忽略的 `out/`：`tsv-split-factor-all-tests.log`、`tsv-split-factor-xlayer.log`、`tsv-split-factor-coverage.log`、`tsv-split-factor-coverage.lcov`、`tsv-split-factor-check.log` 和 `tsv-split-factor-layout.json`。

2026-10-04 系数功能之前的运营历史优化回归：**334 通过、0 失败、0 跳过**，unit 208 + local 126，60 个不联网套件。其中 Registry/报告/运营范围为 **113 项 / 20 个套件**；本轮新增 64 项。包含七项 invariant 和十二个具名 fuzz 用例；默认 invariant 每项 64 轮 × 32 步，普通 fuzz 每项 256 次。复现命令：`FOUNDRY_PROFILE=default forge test --fuzz-seed 0x20261004 --summary`。

交易/LP 阶段历史优化回归为 **270 通过、0 失败、0 跳过**（unit 155 + local 115，46 个不联网套件）。该阶段固定区块 DEX 为 **11 通过、0 失败、0 跳过**，chainId 196，block 72,271,000，入口版本 `v1.0.10-rfq-anti-arbitrage`，当时连同本地共 281 项。运营阶段未修改 DEX/fork 夹具，未重新执行该 11 项；不将其混入本轮 334 项结果。

`make check` 的目录规则、格式和 diff 检查均通过；覆盖率 profile 使用独立缓存，不覆盖普通测试的编译缓存。历史治理收尾记录为 unit 154 + local 54，共 208 通过。

目录重整保留原有 **124 个不同名称的用例**；运营阶段新增文件也未删除原用例。共享 fixture 不包含测试函数，64 个可执行套件（含 fork）之间无继承关系。计数不再包含 Position ID 对整个协议套件的重复继承执行。

## 最终覆盖率

最新系数功能 coverage profile 使用 `--ir-minimum` 和 seed `0x20261004` 汇总全部不联网用例；**369 通过、0 失败、0 跳过**。X Layer 独立 fork 的 11 项未计入下表。

| 合约 | 行 | 语句 | 分支 | 函数 |
| --- | --- | --- | --- | --- |
| TSVDataInboxV1 | 100% (40/40) | 100% (47/47) | 100% (5/5) | 100% (8/8) |
| TSVRegistryV1 | 98.41% (248/252) | 99.02% (403/407) | 95.08% (58/61) | 100% (36/36) |
| TSVVolumeLedgerV1 | 99.01% (201/203) | 98.65% (292/296) | 90.57% (48/53) | 100% (28/28) |
| ReportValidationLib | 100% (5/5) | 100% (13/13) | 100% (2/2) | 100% (1/1) |
| TradeDayLib | 100% (44/44) | 98.15% (106/108) | 71.43% (5/7) | 100% (7/7) |
| TSVGovernanceAnchor | 100% (109/109) | 100% (218/218) | 100% (24/24) | 100% (11/11) |
| TSVGoverned | 95.24% (40/42) | 96.67% (58/60) | 100% (11/11) | 100% (10/10) |
| TSVSwapRouterV1 | 98.51% (66/67) | 98.97% (96/97) | 100% (18/18) | 100% (11/11) |
| TSVLPManagerV1 | 99.30% (141/142) | 96.98% (193/199) | 81.48% (22/27) | 100% (25/25) |
| TSVHookV1 | 100% (78/78) | 97.50% (117/120) | 77.78% (14/18) | 100% (16/16) |
| TSVDirectSettlementLib | 100% (19/19) | 100% (42/42) | 100% (2/2) | 100% (2/2) |

全部非测试源码（含部署脚本）的汇总为：行 **91.98% (1181/1284)**、语句 **92.98% (2000/2151)**、分支 **85.14% (235/276)**、函数 **94.71% (179/189)**。部署脚本的真实广播路径没有执行。

LP Manager 与 Router 的结算符号判断已被实际正/负 delta 用例执行，IR 最小优化的行映射仍各留下一个未计入位置。Hook/LP 的分支统计也尚未达到 100%；上述矩阵记录具体成功、失败和回滚行为，不能从百分比推导所有输入组合均已验证。

运营合约未计入位置分为实际未注入的防御输入、当前入口约束不可达的状态和源码映射遗漏；分类见[运营 review](./OPERATIONS_TEST_REVIEW_V1.md#覆盖率与尚未触达的合约内分支)。没有把这些分支全部称为已测试。

本轮原始记录位于忽略的 `out/`：`tsv-operations-all-tests-v2.log`、`tsv-operations-model-v2.log`、`tsv-operations-check.log`、`tsv-operations-coverage-v2.log` 与 `tsv-operations-coverage.lcov`。旧阶段的 `tsv-final-fork-tests-v2.log` 继续保留；可按测试说明重新生成。

系数功能的最新 coverage 记录：`out/tsv-split-factor-coverage.log`、`out/tsv-split-factor-coverage.lcov`；原有运营 334 项阶段的日志保留为历史记录。
