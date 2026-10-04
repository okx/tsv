# 测试场景覆盖评估 — TSV

审查范围是 `test/` 全部 81 个 Solidity 文件，以及 fixture、handler、fork 清单和测试配置。`src/`、`script/` 用于核对场景与真实行为。下列项目是测试或验收证据缺口，不是生产漏洞。三轮审查均已完成；15 项建议经过交叉复核。

审查快照：2026-10-04 02:30:05，HEAD `51aa98f` 加当前未提交改动。冻结源码见 `source-snapshot.md`；代码清单和逐文件哈希见 `snapshot-sha256.tsv`；测试文件分配见 `test-file-review.tsv`。三轮各使用 3 个审计 worker，合计执行 12 个检查视角，不代表 12 个独立代理。审计期间两个 helper 仅删除末尾空行，差异见 `test-helper-drift.patch`。

## 已有证据

测试包含真实本地 V4 PoolManager、exact-input/output、部分成交、协议及 LP fee 计量、共享证券额度、SBT/暂停门禁、仓位 owner 和 salt 隔离、不可转让 Receipt、强退、发行方失败、结算余额检查及失败回滚。治理覆盖当前身份、过期批准、恢复、冻结、批量升级失败和资金状态保留。运营覆盖报告权限、全局 report ID、分流 sequence、配额更正、日切及拆并股系数。

三个状态模型对权限、仓位/额度、报告/日历有独立预期和成功/失败断言，但其输入域有限。独立模型、真实本地 V4 和确定性边界用例各自提供不同证据，不能用其中一项替代其他项。

X Layer 用例固定区块及多个外部代码哈希，调用真实 DEX/授权组件，但 TSV、V4、issuer、SBT 和 DEX Adapter 仍包含新部署实例或替身。本次仅静态审查这些用例；历史通过次数不计入本次执行结果。GovernorExecutor 的合约调用证据也不等同于生产多签验收。

## 建议补充的场景

P1 表示优先补充的重要集成证据；P2 表示边界或模型增强；P3 表示较低优先级或不在当前 V1 资金路径内。优先级不表示漏洞严重等级。

| ID | 优先级 | 对象与当前证据 | 缺口及验收要求 |
| --- | --- | --- | --- |
| TC-01 | P1 | `test/unit/v1/governance/DeploymentChecks.t.sol:24` 只暴露 `_checkInput(_loadInput())`；`HookFactory.t.sol:96` 重建部署步骤；`DeploymentChecks.t.sol:135` 对治理脚本仅检查 broadcast 前的错误链拒绝。 | 本地直接成功执行实际 `DeployCoreV1.run()` 和 `DeployGovernanceV1.run()`，检查两个 broadcast 阶段、deployer nonce、六代理和实现地址、Hook 权限位、初始化及后续治理绑定。增加抢先部署完全相同 Hook 后的恢复流程，验证既有部署和链接。 |
| TC-02 | P1 | `test/unit/v1/adapters/ERC8056DirectLegalShareAdapter.t.sol:29` 检查 floor 舍入，但 `raw=3` 的结果非零；构造 decimals>18 已有拒绝测试，fixture 使用 Backed，且 Backed source-zero/revert 集成已有覆盖。 | 补 `raw=1, multiplier=5e17, decimals=18` 舍入为零、运行时零 multiplier/越界 decimals/异常或畸形返回、构造零地址/无代码/零版本矩阵。真实本地 V4 中验证 ERC8056 股票两个方向、系数生效前/时刻、额度及错误回滚。对应既有 TG-03。 |
| TC-03 | P1 | `test/helpers/v1/DexRouterTestAdapter.sol:47` 校验长度和最终身份 marker；`:60` 以总余额满足请求金额。固定两尾字 fixture 不认证实际 hop 入款，不能把声明的 moreInfo 金额视为实际转入证明。 | 补实际 hop 入款小于声明金额、捐赠余额与请求错配、失败后捐赠/授权/额度不变。例：已有 50、hop 转入 50、请求 100，不能据此证明仅使用本次 hop 的钱。固定版本两尾字与目标三尾字、caller/refund 分离各需明确预期。这是测试 fixture 和生产 Adapter 验收边界。 |
| TC-04 | P2 | `test/integration/local/governance/SixProxyMigration.t.sol:116` 播种资金、quota、角色及暂停；`:144` digest 不含 Router Adapter allowlist。 | 六代理组合升级前播种并比较 Adapter 授权、待生效 factor/day-start、各类业务角色；升级成功后走 Adapter swap，失败批次也比较这些状态。`SplitFactorFlows.t.sol:81` 已有 Ledger/Inbox 两代理 pending factor 保留测试，不能称该能力完全缺测。 |
| TC-05 | P2 | 本地 `trading/Accounting.t.sol:34` 用同一股票 Currency 的两个池。X Layer `DexRouterFlow.t.sol:91` 已覆盖同证券两个不同 Wrapped Currency 的双 hop 及成交量求和。 | 缺口限定为离线本地回归，以及不同 raw decimals/multiplier/source、但代表同一获准 legal-share WAD 单位的共享 quota 耗尽、第二腿失败和整笔回滚。两种股票排序、输入/输出股票腿都应覆盖；不引入不兼容的日内单位变更。现有 fork 两个 Adapter 使用同一来源和公式，不能替代这些情况。 |
| TC-06 | P2 | `liquidity/Boundaries.t.sol:105` 对 open/increase 检查 max input，对 decrease/close 检查 min output。`Liquidity.t.sol:110` 已有零输出最小值回归。 | `liquidity/Settlement.t.sol` 已有先累计 fee 再 increase，状态模型也可能累计 fee；剩余缺口是显式构造并断言小额 increase 的一腿/两腿正或零净 delta。比较流动性、余额、fee claim、Receipt 和最小输出失败回滚；不能把关闭仓位测试当作 increase 正 delta 分支证据。 |
| TC-07 | P2 | `test/unit/v1/trading/VolumeAccounting.t.sol` 包含正常计量和额度拒绝；未授权写入拒绝不等同于授权写入坏输入。 | 用合法绑定 Hook 身份提交零 delta、同号 delta、非股票腿非零 legal shares。两种 Currency 排序均需覆盖；股票在第一腿时，第二非股票腿错误填写 legal shares 应使第一腿 used 和事件/状态整笔回滚。Registry 拒绝单池两条股票腿，不为不可达状态新增测试。对应既有 TG-01。 |
| TC-08 | P2 | 治理 V1 初始化矩阵主要从 Registry 验证 Anchor；`BatchBoundaries.t.sol:69–80` 已验证六代理 V2 reinitializer 锁，Hook/Router 的依赖拒绝矩阵已有覆盖。 | 六个实现地址及已初始化代理的 V1 `initialize` 锁矩阵；Hook 错权限位地址、LP 无代码依赖、Factory 无代码 implementation/空 initData 等入口矩阵。检查精确错误、无部分状态，合法参数可重试；不重复宣称 V2 锁未测。对应 TG-02 的入口补测。 |
| TC-09 | P3 | `reports/CalendarBoundaries.t.sol:51` 验证日期参数，状态模型限制在近期日期。 | 对 `currentTradeDay()` 测 block timestamp 0、offset−1、offset，以及 9999 年最后支持日和下一日。参数日期拒绝不能替代区块时间端点；明确预期结果/错误与历史 checkpoint 不变。端点不在当前运营时间范围，优先级低。对应 TG-04。 |
| TC-10 | P2 | `reports/SplitFactorBoundaries.t.sol:249` 在可证明不溢出的 `uint160 × uint64` 范围内独立比对，另有专门 overflow 和 max/max 用例。 | 以离线 BigInt 生成完整 `uint256 × uint128` 参考向量，覆盖 512-bit 中间积但最终可表示、结果等于 uint256.max、最终溢出、分母极值和商的一单位边界。不要用同一个 Math.mulDiv 实现计算预期。 |
| TC-11 | P2 | `TradingLPHandler.sol:58` swap 限在 `1e12…1e15`，`:67` 用 remaining>1e18；`:155` 保留 baseline 仓位；quota 取宽松或低于已用值。 | 扩展 near-cap 等值/差一单位、部分成交与换算舍入、所有有效流动性消失/离开价格范围、不同 fee/range/证券/池、Adapter 路径。增加独立 fee entitlement，避免只用总资产守恒掩盖 owner 间错误分配。`CapCorrections.t.sol:59` 已有 exact-cap/差一单位，`StatefulOperations.t.sol` 已有报告/日历交错模型；但其 handler 直接写 Ledger，缺与真实 V4 swap/LP/结算交错的组合模型。确定性部分成交测试已有，缺的是组合模型。 |
| TC-12 | P2 | `GovernanceHandler.sol:55` 生成有效新身份；`:158/:170` 升级使用空初始化和前缀 target；`:194` 比较成功布尔值。 | 随机序列加入无效/复用身份、提案全部字段、任意 batch 顺序、非空 migration 的失败/回调、业务状态，以及角色/报告/暂停/恢复交错。`BatchBoundaries.t.sol:88` 已有任意位置失败及重试，`:164/:187` 已有嵌套回调及迁移中冻结；额外建议是将这些场景与有资金的六代理状态快照组合。确定性治理用例已覆盖多项拒绝，不应重复宣称全部不存在。 |
| TC-13 | P2 | `ProtocolFixture.sol:141` rollback digest 包含全局 fee growth、资金、仓位及 used。 | 增加 V4 每仓位 fee-growth checkpoint 和协议已计 fee，或在已有失败后重试基础上，与 untouched snapshot 的 fee claim 比较；全局增长和余额不能直接证明每个 owner 的权益。原子回滚是 EVM 机制，本项补强测试断言，不构成新漏洞。 |
| TC-14 | P3 | `unit/legacy/TSVIssuerAdapter.t.sol:41` 的三个场景覆盖整数换算、debit limit、强退拒绝。 | 对请求纳入的 legacy 代码补 caller/context/owner/recipient、重复 prepare、错收款/少交付、wrapper supply、allowance cleanup、reentry、redeem min output、非整数展示换算和预存余额。当前 V1 未路由该 Adapter，优先级低于实际资金路径。 |
| TC-15 | P3 | `test/integration/xlayer/deployment.json:4` 记录 blockHash，`DexRouterFlow.t.sol:284` 未断言该值。 | fork 验收同时核对固定区块的 canonical hash；保留链、区块、代码 hash 和执行日志。该项改善可复现性，不能当作合约漏洞。 |

## 生产与链下验收边界

真实发行方的权益定义、Token/Adapter 升级权限与监控、SBT/制裁行为、生产治理账户、生产 DEX Adapter、报告服务的来源/重放/重试、early/late 公司行动处理，需要各自的真实实现和运行证据。本次不 review 外部仓库，也不把替身通过当作这些对象通过。

`SplitFactorFlows.t.sol:46` 在 multiplier/cap 时序错位窗口检查 cap getter，但交易发生在 multiplier 对齐后。`OperationsFlows.t.sol:132` 已验证手动暂停、当前日交易拒绝、修改 ADTV/future quota、下一日恢复、历史 used 保留及 owner 退出。剩余建议限定为排期因子的 early/late 错位窗口内交易尝试，以及不等换算替换/多 Currency 组合；这属于单位政策的操作验收，不能把既有暂停和新日恢复写成完全缺失。

## 三轮复核与执行记录

- 第 1 轮：建立上述候选缺口，并验证现有回滚/状态模型。
- 第 2 轮：三组交叉复核完成，0 finding / 0 lead。缩小多 Currency 缺口，并明确已有 exact-cap、运营状态模型、任意位置批次失败和两代理 factor 迁移的证据；剩余建议针对资金状态与组合模型。
- 第 3 轮：三组完成重新审查和第三个测试域交叉复核，0 finding / 0 lead。确认 15 项建议；补治理脚本成功路径，区分 V1/V2 初始化锁、认证入款与声明金额，并明确已有手动暂停后次日恢复和增加流动性前 fee 累计。
- 本地测试：**369 通过、0 失败、0 跳过，63 个 suite，exit 0**。命令 `FOUNDRY_PROFILE=default forge test --offline --summary --fuzz-seed 0x20261004`；日志 `local-tests.log`。该 profile 排除 X Layer fork。7 个 invariant 使用配置的 64 runs、32 depth；本次未重新计算行/分支覆盖率。
- 目录布局检查：通过，识别 64 个 suite；fixture 无可执行 test、未发现 suite 继承。
- 源码完整性：`snapshot-check.json` 确认 110 个文件无增删，`src`/`script` 字节一致，仅两个 helper 末尾空行不同，无语义变更。并行工作使 HEAD 从 `51aa98f` 移至 `44012cb`，结论以冻结 worktree 源码为准。审计未修改 `src`、`script`、`test`。
