# 审计 Issue 逐项复核与修复价值评估

复核目标：远端 `main` **90929552fd557fd67b9debafa905bafffb40ed86**。开始复核及用户追问后均执行 fetch/ls-remote，远端仍为该 SHA。本地工作区 `main` 的 fa73087 未作为代码结论依据。

范围：[审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd) 拆出的 #9–#29 共 21 项。#30 是版本差异说明，不是待修复漏洞。本次是既有问题的定向复核，不代表完整新一轮安全审计，也未核验链上角色持有人、实际准入资产供应量或生产仓位。

判断依据分为“代码现象是否仍在”“现有入口是否可触发实际影响”“修复是否值得承担回归与升级成本”。保留代码现象不等于漏洞未修复。下述 P1/P2/P3 是工程处理优先级，不自动更改原报告风险等级。

## 建议先处理什么

1. **#9 优先修复**：标准 ERC20 即可在 unsubscribe 中转走 LP 原有余额，使两条强退的汇总事件下溢。已用固定 main 的真实强退代码和既有 PoolManager 测试替身复现回滚及重复阻断。
2. **#12 优先完善应急流程**：Hook、Router、LPManager 在全局暂停中拒绝普通升级。不是无权限攻击，但与暂停后升级修复的运维目标冲突。移除暂停门禁应保留所有其他授权/锁/兼容性检查。
3. **#10、#29 按规模和准入上界处理**：两者有真实边界机制，当前证据不等于实际部署已可触发。#10 优先明确身份总量上限；#29 优先用获准入资产的未来 raw 供应/单仓上界排除极值，不能排除再设计分段退出。
4. **#11 可按已修复关闭**：主线程已运行对应事件和 fallback 回归。#21 优先补足业务口径与示例；#13 按治理措施跟踪。
5. 其余多为可选清理或建议保留的检查。尤其 **#14 的“只有抽象合约需要 gap”不成立，#28 无法据 approval 无 SBT 推导执行权限绕过**。

## 逐项结论

| Issue / 报告编号 | 问题 | 当前状态 | 修复价值 | 建议 |
|---|---|---|---|---|
| [#9](https://gitlab.okg.com/web3-dex/tsv/-/work_items/9) / No.1 | 回调使强退余额差下溢 | 仍存在，已复现 | 高 / P1 | 修复；两条路径同时处理，避免事件计算阻止核心退出 |
| [#10](https://gitlab.okg.com/web3-dex/tsv/-/work_items/10) / No.2 | SBT 身份列表无上限 | 仍有规模风险，管理员配置触发 | 中 / P2 | 限制首次登记总量并测算最坏 gas；不要直接删 NONE 身份 |
| [#11](https://gitlab.okg.com/web3-dex/tsv/-/work_items/11) / No.3 | W/U 强退到账事件 | 已修复，回归通过 | 无需重复修改 | 建议按已修复关闭；事件仍以 W/Q 标识、U/Q 原始单位计量 |
| [#12](https://gitlab.okg.com/web3-dex/tsv/-/work_items/12) / No.4 | 暂停后升级检查不一致 | 仍存在，应急流程约束 | 高 / P1 | 允许暂停中授权升级，保留角色/锁/实现绑定检查 |
| [#13](https://gitlab.okg.com/web3-dex/tsv/-/work_items/13) / No.5 | 中心化信任依赖 | 属于现有信任模型 | 治理措施价值高 | 接受并跟踪多签、分权、时间锁和演练；不把角色设计当权限漏洞 |
| [#14](https://gitlab.okg.com/web3-dex/tsv/-/work_items/14) / No.6.1 | 主合约 reserve gap | gap 仍在，原建议论据不成立 | 无必要 | 保留升级布局约定；不能仅因具体合约非抽象就删 gap |
| [#15](https://gitlab.okg.com/web3-dex/tsv/-/work_items/15) / No.6.2 | constructor/initialize 重复 Registry | 冗余仍在，proxy 初始化正确 | 低 / P3 | 可集中配置到 initialize；不要直接将 storage registry 改 immutable |
| [#16](https://gitlab.okg.com/web3-dex/tsv/-/work_items/16) / No.6.3 | 强退临时标志魔法值 | 仍在，无已证实权限问题 | 低 / P3 | 顺手改具名常量即可 |
| [#17](https://gitlab.okg.com/web3-dex/tsv/-/work_items/17) / No.6.4 | Factory 两次 Adapter 查询 | 当前 Factory 不变量下重复 | 低 / P3 | 可用 verified 非零替代；保持其他准入校验 |
| [#18](https://gitlab.okg.com/web3-dex/tsv/-/work_items/18) / No.6.5 | 未支持的 FROM_DELTAS 分支 | 死分支仍在，外层已拒绝 | 低 / P3 | 可删不可达分支；不能为消除死代码而开放入口 |
| [#19](https://gitlab.okg.com/web3-dex/tsv/-/work_items/19) / No.6.6 | 结算 action 重复拒绝 | 拒绝结果重叠，提前拒绝有意义 | 很低，建议保留 | 提前 Unauthorized 表达强退边界并少做外部 SBT 查询 |
| [#20](https://gitlab.okg.com/web3-dex/tsv/-/work_items/20) / No.6.7 | registerPool 重复 listed | 冗余仍在，非交易热路径 | 低 / P3 | 可以精简，也可作为局部不变量保留 |
| [#21](https://gitlab.okg.com/web3-dex/tsv/-/work_items/21) / No.6.8 | 双向交易额度含费口径 | 行为仍在，按已写明 actual delta 则非漏洞 | 口径确认 / P2 | 补充买卖含费例子；业务要求去费口径才改公式 |
| [#22](https://gitlab.okg.com/web3-dex/tsv/-/work_items/22) / No.6.9 | before/after multiplier 双检 | 双检仍在，当前固定调用链可冗余 | 低 / P3，默认保留 | 当前两 hook 间无可写外部回调；after 保持记账边界，非必须修复 |
| [#23](https://gitlab.okg.com/web3-dex/tsv/-/work_items/23) / No.6.10 | setSbtConfig 重复健康检查 | 并非完全相同：具体 tokenId 与绑定时 0 不同 | 建议保留 | 保留具体 ID 的 fail-fast 校验，避免异常 ID 进入永久遍历 |
| [#24](https://gitlab.okg.com/web3-dex/tsv/-/work_items/24) / No.6.11 | pauseMode & 3 掩码 | 正常 setter 不变量下冗余 | 接近零，接受保留 | 返回归一化有解释价值；不单独修改 |
| [#25](https://gitlab.okg.com/web3-dex/tsv/-/work_items/25) / No.6.12 | 注册资产内外重复检查 | 两条件重复，其他唯一性检查必需 | 低 / P3 | 可整理职责；保留 currency 唯一性及绑定检查 |
| [#26](https://gitlab.okg.com/web3-dex/tsv/-/work_items/26) / No.6.13 | 未使用 TSVDirectSettlementLib | 仍未引用，无运行时资金权限 | 低 / P3 | 可清理/归档；不能据文件存在认定精确到账校验已启用 |
| [#27](https://gitlab.okg.com/web3-dex/tsv/-/work_items/27) / No.6.14 | swap 后清理 active 上下文 | activePayer 已清零，其余残留无已证实复用路径 | 低，非必要 | 锁、onlyPoolManager、每次覆盖和空闲 msgSender=0 已隔离 |
| [#28](https://gitlab.okg.com/web3-dex/tsv/-/work_items/28) / No.6.15 | approve 时检查 SBT | 授权可建立，执行时仍拦截无证 operator | 无安全修复必要 | 维持运行时合规；如业务要求委托持证，另作策略变更 |
| [#29](https://gitlab.okg.com/web3-dex/tsv/-/work_items/29) / 问题1 | 累计本金超过 int128 单次退出上限 | 边界真实，极大 raw 数量下已复现 | 条件化 / P2 | 先证明准入供应/仓位上界；不能排除时设计限额或分段退出，兼顾费用 |

## 主线程验证证据与限制

测试在独立 detached worktree `.audit-revalidation-20261027` 上执行，目标主仓 SHA 固定为 90929552；dex-adapters 单独检出主仓记录的 80800d5670012abe0f7363eecf12358cc50b813f，未使用本地脏子模块。v4-periphery 与 SBT 复用本地依赖目录，已核对 commit 与主仓 gitlink 一致且相关源码无已跟踪修改。没有修改原工作区的生产合约或切换原工作区 main。

**执行结果（针对性测试，不是全套测试）：82 项通过，3 项失败。**

| 测试集合 | 实际结果 | 说明 |
|---|---|---|
| LPLinkedLibrariesTest | 25 通过 | 包括 W 余额为 0 时 U 事件计量、发行方 fallback、FROM_DELTAS 拒绝、直接授权和订阅等已有回归 |
| 新增 AuditRevalidation.t.sol | 6 通过 | 两条强退回调下溢及回滚重试、无转出时成功对照、真实 Pool 累计 delta 上界、无 SBT operator 执行拒绝、暂停门禁优先阻断升级 |
| Registry 暂停/准入/权限、组件升级、Ledger 计量、DirectSwap 相关 6 个 suite | 51 通过、3 失败 | 失败原因见下文，不将此结果表述为全部回归通过 |

**#9 已复现的路径。**使用当前生产 TSVLPManagerLib 与既有 LPLinkedFixture。LP 初始持有 1,000 Q，并批准自选 Subscriber 转走这 1,000 Q；unsubscribe 回调正常转出，退出模型交付 1 Q 后，事件计算 `1 - 1000` 触发 Panic(0x11)。TSV 与发行方两个入口各执行两次，均回滚且 NFT、subscriber、原余额恢复。撤销 Subscriber 的 ERC20 allowance 后回调转出失败被 catch，强退成功、余额成为 1,001 Q。此证明使用 PoolManager/交付计数替身，覆盖真实退出事件与回调时序；不把它表述为完整真实 PoolManager 集成复现。

**#29 已复现的数值边界。**直接调用仓库固定 v4-core 的真实 `Pool.modifyLiquidity`；tickSpacing=60、range=[-887220,-887160]、spot tick=-887260，同一 position 连续增加 `2**71` liquidity 两次。单次合法输入原始单位为 `130122462400857233021688541762359641008`；整仓退出期望输出为 `260244924801714466043377083524719282014`，超过 int128.max，核心 SafeCastOverflow 回滚；两次较小退出均可成功。该测试覆盖真实 Pool 状态与 delta 转换，不包含资产准入和实际 token 资金结算。它证明结构边界而不证明实际已准入 token 有如此大的供应；decimals=18 时门槛已是约 1.7e20 个完整 token。

**#28 执行权限证据。**无 SBT operator 可被 owner approve，但其 INCREASE_LIQUIDITY 请求被生产 library 的 Unauthorized 拒绝；NFT owner 未变化。授权关系本身不等于执行资格。

**#12 门禁证据。**给调用方 mock 授予 UPGRADE_ADMIN_ROLE、令 Registry paused，LP 升级调用先于候选实现校验被 RegistryPaused 拒绝。Hook 与 Router 同类阻断已逐行核对。该用例验证门禁先后关系，不替代完整候选实现升级及恢复流程回归。

### 三项既有测试失败

1. `TSVOperationsPermissionsTest.testBusinessOperatorsCannotChangeAdminConfigurationOrOracleQuota`：旧测试期待 SYMBOL_ADMIN 调用 setTierPolicy 被 default-admin 校验拒绝；当前实现已授权 SYMBOL_ADMIN，故“next call did not revert”。需按最终产品权限规范更新期望，不能据该失败推断此次列举的优化项存在绕过。
2. `TSVComponentUpgradeRolesTest.testRouterUpgradeRejectsChangedImmutableDependencies`：旧测试期待更换为同 PoolManager 的新 Factory 也被拒绝；main 已显式支持该更换，所以旧断言失败。应保留跨 PoolManager 拒绝并增加新迁移协议回归。
3. `TSVComponentUpgradeRolesTest.testImplementationsAndProxiesCannotBeInitializedAgain`：详细 trace 确认再次 initialize 的检查均正确拒绝；失败发生于直接对 Router implementation 调 upgradeToAndCall，未初始化的 implementation registry 为零，whenRegistryNotPaused 先调用零地址 isPaused 而回滚，错误数据与期待的 UUPSUnauthorizedCallContext 不同。不能将这一失败误报为实现可被初始化/升级；可以单独整理门禁顺序与测试期望。

### 编译与测试范围限制

最初按仓库配置运行，`ITSVPermissionedRegistry.sol` 的全局 `@uniswap/v4-core/src/` 导入缺少可解析 remapping，未能编译。后续测试命令仅在 CLI 补充了该映射，并排除新增但尚未配齐 import 的 `SecuritizeTSVChecker.sol` 与脚本：

```sh
forge test --root .audit-revalidation-20261027 \
  --skip SecuritizeTSVChecker.sol --skip script \
  --remappings '@uniswap/v4-core/src/=lib/v4-periphery/lib/v4-core/src/' \
  --match-contract '<目标 suite>' -vv
```

运行 6 个新增用例时使用 `--match-path test/unit/v1/deployment/AuditRevalidation.t.sol`；其他 suite 名称和完整输出见保留的日志。本次不声称未调整的整个 main 能默认构建通过，也未验证 Checker、脚本或全部集成测试。

保留证据：[新增验证用例](proofs/AuditRevalidation.t.sol)、[LP 既有测试日志](revalidation-existing-tests.log)、[新增用例日志](revalidation-proof-tests.log)、[关联回归日志](revalidation-related-tests.log)、[初始化失败轨迹](revalidation-init-failure-trace.log)。

## 逐项详细依据

[LP、强退及授权 9 项](revalidation-lp.md) · [Registry 与身份 6 项](revalidation-registry.md) · [Hook、Router 及其他 6 项](revalidation-hook-router.md)。分工文件中“未运行测试”指该源码复核步骤，实际执行结论以本汇总的主线程证据为准。

## 推荐 issue 处理方式

- #9、#12：保留并安排优先改动；#9 保持真实 DoS 描述，#12 明确为应急升级流程改进。
- #10、#29：保留为有边界条件的可用性事项，补充规模/准入证明后再决定是否以代码修改解决。
- #11：按已修复结论及通过的回归关闭。
- #13：按接受的信任模型记录治理控制；#21：确认 actual-delta 的产品口径，接受时补示例后关闭。
- #14、#19、#22、#23、#24、#27、#28：建议解释接受/无需修改，不使用“已修复”掩盖“原建议不需要实施”的区别。
- #15、#16、#17、#18、#20、#25、#26：可转为维护 backlog，或接受后关闭；不建议独立占用安全修复发布窗口。

上述为建议结论，issue 原始风险等级仍以原报告为记录；后续改动或正式关闭应引用本次固定 SHA 和对应验收证据。


---

# LP 相关既有审计问题定向复核

固定代码版本：`90929552fd557fd67b9debafa905bafffb40ed86`（本次远端 main）。结论基于该版本的源码、入口及依赖调用链，未将本地 HEAD 或脏子模块作为目标。本文件仅分析既有问题，不是全仓安全审计；未运行测试，由主线程统一补充测试证据。

| Issue | 原报告 | 当前判断 | 修复价值及建议优先级 |
|---|---|---|---|
| #9 | No.1 回调致强退余额差下溢 | 仍成立，真实强退 DoS | 高；P1，建议修复 |
| #11 | No.3 W 余额导致事件漏报 U | 已修复 | 无需重复修改；复核回归后可关闭 |
| #14 | No.6.1 主合约不需 reserve gap | 代码仍有 gap；原建议的“仅抽象合约需要”论断不成立 | 无安全修复价值，建议解释后关闭 |
| #15 | No.6.2 constructor/initialize Registry 重复 | 仍存在配置冗余，但不是代理未初始化漏洞 | 低；P3 可清理 constructor 配置，勿直接将 proxy storage 字段改 immutable |
| #16 | No.6.3 强退临时状态魔法值 | 仍存在，可读性建议成立 | 低；P3 顺手整理 |
| #18 | No.6.5 不支持的 from-deltas 分支 | 仍存在不可达分支，入口已拒绝 | 低；P3 删除死分支，非安全修复 |
| #19 | No.6.6 MINT_6909/UNWIND 重复拒绝 | 最终拒绝结果确有重叠；提前拒绝有意图/错误语义价值 | 很低；保留也合理，不建议为 gas 单独改动 |
| #28 | No.6.15 approval 应校验 SBT | approval 未检查，但执行时已有权限检查；无法据此证明绕过 | 无需安全修复；若业务另有“委托也须持证”要求，再统一设计 |
| #29 | 问题1 累计原始本金超 int128 单次强退 | 条件成立，代码未消除；现实触发依赖极大原始资产量 | 中等、条件化；P2 先证明准入上界；若不能排除再做限额/分段退出设计 |

优先级是本次工程建议，P1=应优先修改，P2=按业务风险安排，P3=维护清理；不自动改变原审计风险级别。

## #9 — 仍成立，建议优先修复

**源码证据。** `TSVLPManagerLib.sol:125–132` 在 unsubscribe 前读取 LP 的实际结算 U/Q 余额；`153–162` 在销毁和交付后直接计算 `settlement.balanceOf(lp) - before`。发行方路径的 `185–188`、`220–230` 同样先快照再回调、最后作无保护减法。`451–470` 的 unsubscribe 确实会调用 LP 选择的 Subscriber；catch 仅吞掉回调本身的 revert，不阻断回调已成功完成的普通 ERC20 转出。

**可达路径。** 合法 LP 可以是实现 ISubscriber 的合约钱包，也可授权 Subscriber 转走自己原有 Q。该 LP 正常持仓并将该合约设为 subscriber（`Notifier.sol:43–63` 只校验 NFT owner/approval 和 PM locked）。强退前它持有 1,000 Q，强退仓位仅将收到 10 Q；在 notifyUnsubscribe 中转走原有 1,000 Q 并正常返回，最终余额 10 Q，汇总事件参数计算 `10 - 1,000` 触发 Panic(0x11)。这些 Q 不必有转账回调、扣费等特殊行为，标准 ERC20 即可。管理器的 isNotLocked 不限制外部钱包转自己的 Q，角色检查也只约束发起强退的人，不约束被动回调。

**影响。** 整笔回滚恢复 NFT、subscription、池计数及 Q 余额，LP 下次仍可重复该行为。虽然攻击者自己的仓位保持未退出，影响是管理方无法强退和潜在阻塞要求计数清零的池/证券下架，因此不只是自伤。

**价值与建议。** 保持为实际可用性问题，P1。最低改法是把退出前快照移到 unsubscribe 及重挂清理之后；汇总事件仍建议用非负安全差值，避免观察性事件造成核心操作回滚。余额下降时不能 unchecked 后伪造巨大数值；可返回 0 并额外记录异常，或使用可靠的实际交付记账。若允许任意带回调的出款资产，仅挪动快照不覆盖交付阶段回调转账，安全差值/交付记账更稳健。修复需同时覆盖 TSV 和发行方两个事件分支、LP/发行方到账路径；回归应断言恶意 unsubscribe 后强退完成、NFT 和池计数正确。

## #11 — 已修复，可在回归复核后关闭

**源码证据。** `TSVLPManagerLib.sol:125–129`、`182–185` 先解析 `settlement0/1`；`236–242` 的 `_settlementCurrency` 调用 Factory 的 `verifiedPermissionsAdapterOf(W)`，返回 U；无 underlying 时才返回原 currency。随后所有 recipient snapshots 及 TSV 事件末端余额都用已解析的结算资产。

**验证依据。** 当前测试 `LPLinkedLibraries.t.sol:43–112` 故意让 W 的 LP 和发行方余额保持 0，断言两种汇总事件仍报告 U；`114–131` 覆盖发行方 fallback 到账，`135–141` 是对应观测余额 mock。修复提交为 `8fbabc5`。本分工仅确认测试存在和源码意图，不能声称已实际跑过。

**剩余边界。** 事件的 token0/token1 仍表示池中 W/Q，金额表示结算 U/Q 原始单位；这是代码 `45/58` 已明示的事件格式，接入方应映射资产。#9 的无保护减法仍在，不能把本项修复当作 #9 也已修复。

## #14 — 原建议论断不成立，无需按其删除 gap

**源码证据。** `TSVLPManagerV1.sol:63–65` 仍保留 storage Registry 后的 `uint256[48] private __gap`，这是可升级代理实现。固定数组预留存储布局不会在部署时逐槽 SSTORE 48 个零，因此不存在由此必然造成的大额运行 gas 问题。

**判断。** “只有抽象合约才需要 reserve gap”不是有效规则。抽象基类使用 gap 常见，是为了给子类留出相对稳定位置；具体可升级实现同样可以选择预留 slot，未来 V2 可能继承该实现。当前实现作为 leaf 时，append-only 增加字段并不强制要求 gap，因此 gap 可以说“不是必需”，但不能说“错误”。没有权限绕过、资产损失或实际 DoS 路径。

**建议。** 无需安全修复；答复“保留为升级布局约定”并关闭该优化项即可。如果决定采用另一种布局策略，应通过完整 storage-layout diff 有意消费/缩减 gap，而不是机械按报告删除。尤其不能把本项同 Registry/Quota 的真实 storage 变更混为一谈。

## #15 — 配置冗余仍在，但当前 proxy 初始化正确

**源码证据。** `TSVLPManagerV1.sol:79–101` 的 constructor 校验 `_registry` 合约代码并写 implementation storage；`106–108` 的 initializer 再校验并写 proxy storage。constructor 同时 `_disableInitializers()`，因此实现合约不能被重新初始化；proxy 的 ERC721 状态也在 initializer 明确初始化。

**判断。** 报告关于“构造 storage 赋值不会自动初始化 proxy”的描述正确，但代码没有误依赖这种行为；proxy 正确使用 initialize。问题是多一个实现合约参数会造成工具/部署认知成本，可以传入与 proxy initializer 不同的 Registry，但这个 implementation storage 值不会控制 proxy 的日常权限。

**建议。** P3 可删除 constructor 的 Registry 参数和实现合约存储赋值，将配置来源集中于 atomic proxy initialize，同时更新部署脚本/构造参数。不要为了消除冗余就直接将已部署 proxy 的 storage `registry` 改成 immutable：那会把 Registry 绑定改为实现级配置，改变升级/校验语义且需要独立 storage/部署兼容评估。未发现当前授权漏洞，不应按安全修复阻塞发布。

## #16 — 魔法值仍在，可读性清理有低成本价值

**源码证据。** `TSVLPManagerV1.sol:338` 在授权 burn 时写 `bytes32(uint256(1))`，`352` 以同一值判断 `isUnwindActive`。整个授权 callback 先在 `323–327` 比较并消费 exact callback hash，burn 后在 `340` 归零；零/哈希/活动状态区分与注释匹配。

**判断及价值。** 目前两处一致，没有由重复字面量直接构成的权限绕过。定义共享 `UNWIND_ACTIVE_FLAG` 便于将来保持两处同步，属于 P3 可读性维护；不要为这项宣称修复了强退授权漏洞。不要改动回调哈希承诺、零态、burn 前后恢复的实际时序。

## #18 — 确有不可达分支，不是可利用的功能入口

**源码证据。** 报告截图指 `TSVLPManagerLib.sol:379–382` 的 `MINT_POSITION_FROM_DELTAS` 分支。当前 `TSVLPManagerV1.sol:356–364` 只有 MINT/INCREASE/DECREASE/BURN 四种正常 position actions 调到 `_handlePositionAction`；其他 action 进入 settlement validator，`TSVLPManagerLib.sol:411–415` allowlist 不含任何 FROM_DELTAS，故 revert。授权强退 dispatcher（`322–347`）也不接受 FROM_DELTAS。

**验证依据。** `LPLinkedLibraries.t.sol:298–328` 明确覆盖两个 modify entry points 对 INCREASE_FROM_DELTAS / MINT_FROM_DELTAS 的 UnsupportedAction 回滚。

**建议。** P3 可以删掉 library 的未使用分支，减少维护误导和 bytecode；不应开放外层 dispatcher 使其“有用”。当前拒绝逻辑有效，不需安全修复，也不应以此声称 FROM_DELTAS 旧有 sandwich 风险可经 TSV 到达。

## #19 — 逻辑重叠存在，但提前拒绝并非必须移除

**源码证据。** `TSVLPManagerLib.sol:398–399` 以 Unauthorized 提前拒绝普通用户执行 MINT_6909/UNWIND_WITH_FALLBACK；同函数 `411–415` 的 settlement allowlist 也不会允许这两种 action。若删掉前者，最终仍会在后者拒绝，但会先执行 `401` 的外部 SBT 权限检查，且错误从 Unauthorized 变为 UnsupportedAction（或先受 SBT 失败影响）。

**判断。** 报告说最终允许/拒绝结果重复是对的，但早返回表达“claims 专用于授权 unwind”的安全边界，省掉无意义的外部权限查询，具有代码意图和失败语义价值。未发现漏洞，也未测到应该优先优化的 gas 浪费。

**建议。** 可说明提前拒绝是有意为之而关闭优化项。若统一整顿 allowlist/error 设计，可重构一次集中判定，保留两 action 仅经承诺强退 callback 可达的边界；无需为该项单独变更。

## #28 — 无 SBT 的 approval 仍允许，但无法绕过执行时合规门禁

**源码证据。** `TSVLPManagerV1.sol:227–252` 的 approve/setApprovalForAll/permit/permitForAll 只加暂停门禁，delegate 关系的确不要求 SBT。执行 position action 时，`TSVLPManagerLib.sol:373/388` 分别检查 executor 和 NFT owner 的 `LIQUIDITY_ALLOWED` SBT，`389` 检查池生命周期门禁；正常 settlement 在 `401` 检查 executor，显式 recipient 在 `402–410` 再检查 recipient。底层 `PositionManager.sol:158–160/299/347/424` 仍保留 NFT approval 检查；`PermissionedPositionManager.sol:145–154` 禁止 NFT 转让。

**可达性判断。** 给一个无 SBT 地址 approve 并不等于它可以增/减仓、burn 或收资产：未持证 executor 在库的第一道检查就被挡住。approve 也不能赋予 FORCE_EXIT_ADMIN_ROLE 或 issuer 身份。subscribe/unsubscribe 使用 NFT 授权而非 SBT，但那是用户主动授权的通知管理能力，不等于获得 liquidity 权限；本项没有给出由此绕过既有资产合规边界的路径。

**建议。** 不作为安全漏洞修复，解释“委托关系与执行时资格分离”后关闭/接受。若业务明确要求“建立委托时对方也必须持证”，可作为产品策略变更另做；应同时覆盖四条 approval/permit 路径，保留 spender=0、approved=false 等撤销能力。只在 approve 时校验也不能替代每次执行校验，因为 SBT/权限会在授权后撤销；额外审批门禁还会妨碍给未申请 SBT 的工具合约预授权。

## #29 — 极大原始资产量下条件成立，优先明确准入上界

**源码证据。** 两强退路径最终都调用 `PositionManager.sol:422–448` 的 `_burn`，读取并一次性移除该 tokenId 全部 liquidity。核心 `lib/v4-core/src/libraries/Pool.sol:206–235` 把整笔本金 token delta 转为 int128；同文件 `189–192` 也将累计 feesOwed 转 int128。每次增仓单次的 delta 上限和每 tick 的 liquidity cap 不会普遍保证同一 NFT 的累计 raw token 本金小于 int128.max。`PermissionedValidationLib.sol:160–166` 的 decimals≤18 不等价于 totalSupply/raw amount 上限。

**具体条件示例。** 取 tickSpacing=60，range [-887220,-887160]，当前价在 lower 或其下，token0 单边；每次增加 `2**71` liquidity，单次 amount0 约为 `1.30e38`，小于 int128.max≈`1.70e38`；两次合计约 `2.60e38`，超过该上限。总 liquidity `2**72` 约 `4.72e21`，远低于该 tickSpacing 的 per-tick liquidity cap（约 `1.15e34`）。因此不能以 core liquidity cap 或单次 add 合法为理由排除累计本金问题。具体精确整数额应以主线程 TickMath/SqrtPriceMath 回归为准，此处分工未跑代码测试。

**现实前提与严重性。** 构造要求准入币能提供超过 `1.7e38` raw units 的单一仓位资产；18 decimals 时已相当于约 `1.7e20` 个完整 token，6 decimals 时约 `1.7e32` 个。这远超通常证券/主流稳定币供应规模。源码虽不排除，但不能据此声称当前实际获准入资产/线上仓位已能触发，也不能宣称任意用户可低成本攻击。若已证明所有准入资产未来发行上限均不足此量，理论本金路径无现实影响。

**修复价值。** 条件化 P2。建议先形成资产准入/仓位最坏价格 raw amount 上界及证据，尤其考虑未来增发、替换资产和 decimals。若业务上界排除本金及累计费用超限，可记录接受的工程边界，不必为理论极值直接引入复杂分段强退。若无法建立该保证，应该约束 cumulative raw 风险或设计授权分段减仓/结算及最终 burn；仅加一条注释不算修复。累计 fees 的 int128 限制是另一条相关边界，单纯分段本金并不会自动拆开 core 一次计提的全部费用，设计应覆盖收费结算与异常恢复。当前源码 NatSpec 已明确披露上界风险，但披露不改变可达性。


---

# Registry 相关审计 Issue 定向复核

目标版本固定为 `90929552fd557fd67b9debafa905bafffb40ed86`（本次取得的远端 main）。当前工作区 HEAD 不作为判断依据。以下行号均来自 `git show 90929552:<path> | nl -ba`；SBT 依赖固定为该主仓版本记录的 `a4c53ccbf7de65a3f415a706d22a506a215b68fc`。仅分析既有问题，未运行测试、读取链上配置或推断部署治理地址。

## 汇总

| Issue | 当前状态 | 是否是成立的外部攻击漏洞 | 修复价值 / 建议优先级 |
|---|---|---|---|
| #10 SBT 身份列表无长度上限 | 仍存在，依赖管理员配置规模的可用性隐患 | 没有证明任意用户可扩容；不能据此认定任意用户 DoS | 有价值：限制长期不可回收成本，P2；当前仅少量稳定 ID 时不必作为上线阻断项 |
| #13 中心化风险 | 仍是现有信任模型；未证明有权限绕过 | 否，角色按设计行使权限不是漏洞 | 治理/运维措施价值高；无需删除权限或重写合约，建议“接受并跟踪治理措施” |
| #20 registerPool 重复 listed 检查 | 冗余仍存在，原建议在当前调用链上成立 | 否，重复检查只会多作保护 | 低价值，P3；可在常规整理时删除，保留亦可接受 |
| #23 setSbtConfig 重复 verify 检查 | 调用仍在，但“完全重复”论据不充分 | 否，未导致授权绕过或错误拒绝正常当前 SBT ID | 建议保留或标注用途；只为节省管理操作一次外部调用不值得改动 |
| #24 pauseMode & 3 冗余 | 表达式仍在；正常写入不变量下确实冗余 | 否，未证明可造成错误状态 | 几乎无修复价值，建议接受/关闭优化项，保留归一化逻辑合理 |
| #25 注册函数重复环境/listed 检查 | 两处防御检查仍在，在现有单调用点下确实重复 | 否，未发现安全影响 | 低价值，P3 或接受；仅删除重复的两个条件，不应删除 currency 唯一性检查 |

P2 表示建议有计划地完善的可用性/治理措施；P3 为可选整理，不代表安全等级。

## #10 / 报告 No.2：SBT 身份列表无长度上限

**结论：当前未修复，但应保留为依赖管理员配置规模的可用性隐患，而非未经证明的任意用户中风险 DoS。**

代码证据（`src/v1/core/TSVRegistryV1.sol`）：

- L91–92：`identityTokenIds` 明确为 append-only 数组。
- L324–334：`setSbtConfig` 要求 `DEFAULT_ADMIN_ROLE` 和非零 reasonCode；首次注册直接 `identityTokenIds.push(tokenId)`，没有长度上限。
- L339：设为 `NONE` 仅替换 `SbtIdentityConfig(true, permissions)`，不会删 ID。
- L343–346：`sbtTokenIds()` 返回完整数组。
- L362–384：`hasCredential`、`permissionsOf` 和 `isSbtAllowed` 都依赖 `_credentialState`；SBT paused 时 `permissionsOf` 提前返回 NONE。
- L784–791：每次遍历全量历史 ID，并逐项外部调用 `verify(owner, tokenId)`，没有找到所需权限后提前返回。
- `src/v1/periphery/TSVSwapRouterV1.sol` L252：实际 swap 路径调用 `isSbtAllowed`；`src/v1/libraries/TSVLPManagerLib.sol` L373、L388、L425–426：LP 操作同时对执行者与 owner 校验，故成本会累加。

**能触发什么，不能触发什么：**随着管理员合法累积大量不同身份类型，每次普通用户权限检查的成本线性增长。当前固定 SBT 的 `SmartWalletSbt.sol` L167–171 只是 `balanceOf(user, tokenId) > 0`，因此不同 ID 会形成不同 storage 读取。数组足够大时存在耗尽交易 gas 的机制。但是，只有 Registry default admin 能新增 ID，普通用户即使能领取许多 SBT，也不能将未登记 ID 追加进 Registry；现有代码证据不支持“外部用户低成本填满数组”。本次未读取链上 `sbtTokenIds`，不声称当前部署已经接近 gas 上限，也不虚构具体阈值。

**修复价值：有，但与实际规模相关。**如果系统计划仅登记少量稳定的权限类型，该问题目前通常不紧急；如果身份类型会按发行方、资产、地域不断增长，历史 ID 永不回收就会把运营变更永久带入交易成本，值得在规模扩大前修复。建议 P2：基于真实 SBT 和最坏调用次数测算一个上限，只约束首次添加，已登记 ID 的权限更新仍可用，并监控当前长度。需要更长期扩容时再考虑有明确语义的删除/分集合机制。

**修复陷阱：不能直接跳过或删除 permissions=NONE 的身份来“优化”。**当前 `hasCredential` 明确独立于权限（L359–364），禁用操作权限并不等于撤销身份；`hasIdentity` 也独立查询登记身份（L349–356）。删除历史 NONE 身份会改变身份可见性，应把“是否有身份”与“是否有操作权限”的集合、查询语义分别设计，并作迁移。治理恶意把上限设成危险值也不是本项的外部攻击论据。

## #13 / 报告 No.5：中心化风险

**结论：仍是协议的既有信任模型，不能按代码缺陷认定“未修复漏洞”。**

代码证据：

- `src/v1/governance/TSVGoverned.sol` L15–24 定义分工角色；L32–36 在初始化时把 default admin 和 upgrade admin 授予传入的 `admin`；L40–41 对升级显式验证 upgrade role。
- Registry L245–247、L324–326：组件绑定和 SBT 配置要求 default admin；L392–394 的 `setTierPolicy` 当前已使用 `SYMBOL_ADMIN_ROLE`；L470–476、L654–656 等资产、池管理入口分别受 symbol role 限制。
- Registry L721–723、L751–755：证券暂停用 HALT_REPORTER_ROLE，全局暂停/恢复分别要求 PAUSER/RESUMER role。
- Registry L276–305：新增 Factory 更换要求 UPGRADE_ADMIN_ROLE、全局暂停、代码存在以及多组件绑定一致性检查，并非普通用户可更换。
- `src/v1/core/TSVVolumeLedgerV1.sol` L44–59：quota/usedWad 更新要求 VOLUME_ORACLE_ROLE，L89–90 升级要求 upgrade role。
- `src/v1/periphery/TSVSwapRouterV1.sol` L99–106：Adapter allowlist 由 default admin 管理。
- `src/v1/periphery/TSVLPManagerV1.sol` L139–143：TSV 强退要求 FORCE_EXIT_ADMIN_ROLE；L180–181：发行方强退先校验 issuer admin。注意当前 TSV 管理员强退分支已取消 LP 的 issuer-eligibility 前置条件，应修正文案，不能继续笼统描述两条路径完全相同。

这里未找到普通用户绕过角色、把权限授予自己或抢先初始化等具体利用路径。上述角色能进行业务治理，是系统设计，不因为权限高就构成低风险代码漏洞。初始化接收一个 `address` 也不能证明它是单签 EOA，该地址完全可能是多签或 timelock；本次没有读取实际角色持有人，不能声称治理措施已经落实或缺失。

**修复价值：治理措施有真实价值，代码上的“去掉管理员”无直接价值。**对合规证券协议，应保留必要的暂停、额度与强退能力；应通过多签、岗位分离、升级延迟（保留应急流程）、关键角色/参数监控、备份和撤销闲置权限降低失陷与误操作风险。已有分角色常量只提供分权能力，不等于部署时确实分权。建议将该 issue 作为接受信任模型及部署验收清单，提交真实多签/角色/升级控制证据后关闭或持续跟踪，不应宣称在本次代码版本中“修复中心化”。

## #20 / 报告 No.6.7：registerPool 重复 listed 检查

**结论：仍存在的低价值优化项，报告的局部冗余判断成立。**

执行路径和证据（Registry）：

1. L583–591：仅绑定的 LPManager 可调用；两侧必须通过 `_assetAllowed`。
2. L854–858：Q 返回 quote registered；W 返回 `config.registered && securities[config.securityId].listed`。
3. L592–595：从同一 `currencyUnderlying -> underlyings` 映射取证券，要求恰好一侧有非零 securityId，并选出股票侧的 securityId。
4. L596–597：再次读取该同一证券的 `listed`，否定则 revert。

在这些步骤之间没有外部调用、没有证券状态写入；正常存储不变量下，L597 检查不可能在 `_assetAllowed` 返回 true 后单独失败。因此移除该行不会放开未上市股票建池。但是这只是重复 warm storage 读取/分支，未测量优化器后的实际 gas 差，且建池不是高频 swap 路径。

**修复价值低，建议 P3/可接受。**可在清理代码时删 L597 并保留未上市股票拒绝建池回归；如果希望使 `registerPool` 的核心不变量局部可见，保留也合理。不属于需要阻断发布的漏洞，更不应删除上游 `_assetAllowed` 或后续 exactly-one-stock 检查来追求同一优化。

## #23 / 报告 No.6.10：setSbtConfig 的 verify 检查

已查看报告原始截图 `In7PbvmSioYqrfxyraHlwHDagqS.png`，红框是 `try ISmartWalletSbtV1(participantSbt).verify(address(this), tokenId)`，不是 `participantSbt != 0` 本身。

**结论：代码仍在；“bindComponents 已完全检查，所以一定冗余”不完全成立，建议保留防御性校验。**

- Registry L256–262：绑定时只尝试 `paused()` 与 `verify(address(this), 0)`，并不枚举未来要配置的 tokenId。
- L329–333：配置某个具体 tokenId 时再次调用 `verify(address(this), tokenId)`；`returns(bool) {}` 没有要求 true，因此它只是“该 ID 的校验调用当前能成功返回合法 bool”的健康检查，不验证 Registry 自身持有身份、也不验证身份曾发行。
- L330 可能拦截自定义/已升级 SBT 在特定 ID 下的 revert 或错误 ABI。SBT 本身是可升级依赖：固定依赖 `SmartWalletSbt.sol` L235–239 允许其 default admin 升级。一次绑定成功不能逻辑上保证后续每个 ID/每个时间点调用均成功。
- 对本次固定 SBT 实现 a4c53ccb，L167–171 的 verify 只读 ERC-1155 balance（非零 Registry 地址、任意 uint256 ID 正常返回），故该检查对当前实现没有增加“tokenId 合法性”约束。

**修复价值：单纯删除很低，保留有 fail-fast 价值。**该调用在管理员登记/修改 ID 时发生，不会在每次交易中额外多一次；它可以在写入 append-only ID 前提前发现当前具体 ID 的异常。对未来可升级/自定义 SBT，删除它还可能允许把会 revert 的 ID 永久追加到全量权限遍历，反而恶化 #10。建议接受/保留并将注释改为健康检查，避免声称它校验 tokenId 存在。即使删除也不是安全修复，不能据此关闭为“漏洞已修复”。

## #24 / 报告 No.6.11：pauseMode 的 & 3

已查看截图 `BwqibEbu6ovHh1xtWAqlTSKpg0d.png`，建议针对 `_getSecurityPauseMode` 中 `return securities[securityId].pauseMode & 3;`。

**结论：表达式仍存在，在当前正常写入不变量下确实可省，但没有证明需要修复。**

- Registry L744–745 仍与截图一致。
- `src/v1/types/TSVTypes.sol` L71–77 将存储字段定义为 uint8 的两位 mask。
- Registry L728 先归一化旧值；L732 的 selectedBits 只可能为 1/2/3（非法枚举值在 ABI 解码时拒绝）；L736 的 OR/AND 操作在旧值 0..3 上闭合；L738 为唯一 pauseMode 直接写入。默认值也是 0。因此，不存在经公开 setter 生成第 2 位以上非零 bit 的路径。
- L455–458 的 getSecurity 和 L706–707 查询使用此 helper；运行业务门禁 L885–889 本来就只检测 TRADE/LP 的对应 bit。
- 现有 `Pauses.t.sol` L94–125 包含独立 bit 模型 fuzz、ALL 开关和未知证券默认值的测试文本，未在本次执行。

**修复价值接近零。**位掩码成本很小，现有表达式让返回值显式归一化，也保持查询在高位异常时和实际门禁关注低位的语义一致；存储迁移/错误升级的问题不能靠这里删 mask 修复。建议按接受的微优化关闭或保留，不必安排独立补丁。若必须改，应在同一状态逻辑整理中处理并保留完整状态转移回归，不能称其为安全问题。

## #25 / 报告 No.6.12：注册函数重复检查

已查看截图 `LWTob1buSoZ8pMx3Mtll9AdLgcf.png`，红框明确是内部 `_requireEnvironment()` 和 `!securities[registerParam.securityId].listed`，不是 `currencyUnderlying[currency] != 0`。

**结论：当前单调用点下这两处检查仍重复，属于低价值可选整理。**

- Registry L470–491：外部 `registerPermissionedCurrency` 校验 role/reason/securityId，L480 已调用 `_requireEnvironment()`。新证券分支 L482–487 直接设置 listed=true；既有证券分支 L488–489 在 !listed 时 revert。随后才调用内部 helper。
- Registry L815–821：内部 helper 又检查 `_requireEnvironment()` 与证券 listed；L803–805 显示环境检查只是 Factory 地址非零。
- 全文件只有 L491 这一个 `_registerPermissionedCurrency` 调用点；外部环境检查与内部检查之间只有内部 tier 状态更新和事件，没有外部调用，不能重入改变 Factory/listed。因此在当前调用图上重复部分不会独立拒绝任何请求。
- 同一个 if 中的 `currencyUnderlying[currency] != address(0)` 是包装币重复注册防护，上游没有替代它，必须保留。后续 canonicalUnderlying 绑定一致性及 adapter 验证也均非本条建议的删除范围。

**修复价值低，P3 或接受保留。**管理员注册资产的频次低，重复条件使 helper 的预置条件易读，未来新增内部调用点时仍有保护。若选择精简，优先二选一地明确校验职责：让 helper 负责，移除外层重复环境检查；或者在外层保持保证并给 helper 写明前置条件，只删内部重复部分。两种方式必须保留外层新建/已存在证券及错误参数的完整语义，不宜为微量 gas 改动任何权限、存储布局或事件时序。

## 额外测试文本观察（不计入这 6 个问题）

固定 main 的 `test/unit/v1/registry/Permissions.t.sol` L83–99 仍期待仅拥有 SYMBOL_ADMIN_ROLE 的 operator 调用 `setTierPolicy` 被 DEFAULT_ADMIN_ROLE 拒绝，然而当前 Registry L392–394 已将该入口改为 SYMBOL_ADMIN_ROLE。此用例文本与代码不一致，测试若执行很可能在这里失败；这不能被误认为上述优化项的复现失败或新权限绕过。主线程需要在测试报告里记录实际执行结果。


---

# 定向复核：Hook、Router 与相关优化项

目标版本：`90929552fd557fd67b9debafa905bafffb40ed86`（远端 main 固定快照）。本文件所有行号均依据 `git show <SHA>:<path> | nl -ba`，没有使用当前本地 HEAD 代替目标版本。仅进行了源码、依赖路径及报告截图核对，未运行测试、未核验部署参数，也未修改生产代码或远端 issue。

判断“修复价值”时区分可触发的安全/可用性问题、产品口径和纯维护建议。P1=高价值，P2=中价值，P3=低价值/择机；不等同于漏洞风险等级。

| Issue | 当前状态 | 修复价值 | 建议 |
|---|---|---|---|
| #12 升级暂停检查 | 仍存在，真实的应急操作约束；不是无权限攻击漏洞 | P1 高 | 允许授权升级在暂停时执行，保留角色、锁和实现绑定校验，并验证暂停升级流程 |
| #17 candidateUnderlying 两次读取 | 仍存在；对当前两种 Factory 属冗余一致性读取 | P3 低 | 可择机改为读取 verified 后非零检查；保留 W/PoolManager/U/Checker 验证 |
| #21 双向额度手续费口径 | 行为仍存在；按实际股票流量解释则非漏洞，文档已部分说明 | P2 中（口径确认），代码修改取决于产品定义 | 明确 gross/net 口径并做双向例子；不要无产品依据直接扣手续费 |
| #22 multiplier 双检 | 两次读取仍存在；对当前受支持的固定调用链可证明无中间外部写入，不是漏洞 | P3 低 | 默认保留；有实测收益且限定不变性后才简化，至少保留记账前验证 |
| #26 未使用 DirectSettlementLib | 仍无生产调用；是孤立代码，不是运行时漏洞 | P3 低 | 可删除/移出生产目录，或明确保留用途；不应为了“用起来”改结算逻辑 |
| #27 active 状态清理 | 部分已做（activePayer 已清零）；其他残留未形成可执行旧上下文复用路径 | P3 低/非必须 | 可保持现状，若清理应先缓存返回金额，不能移除/重排已有 storage 字段 |

## #12 / No.4：升级暂停检查不一致

**结论：仍存在，值得修复，但应作为应急可恢复性改进而非无权限可利用漏洞。**

当前代码：

- `src/v1/core/TSVHookV1.sol:58–60`：`_authorizeUpgrade` 先检查 `registry.isPaused()` 再检查升级角色；全局暂停时即便升级管理员也被拒绝。
- `src/v1/periphery/TSVSwapRouterV1.sol:302–320`：升级入口带 `whenRegistryNotPaused`；授权函数另检查 UPGRADE_ADMIN_ROLE、locker=0，以及新实现 PoolManager/Factory 绑定。
- `src/v1/periphery/TSVLPManagerV1.sol:306–317`：升级入口同样带未暂停门禁，授权仍需 Registry UPGRADE_ADMIN_ROLE。
- `src/v1/governance/TSVGoverned.sol:39–42` 和 `src/v1/core/TSVVolumeLedgerV1.sol:89–90`：Registry 基类/Ledger 升级只检查角色，不要求未暂停。
- `src/v1/core/TSVRegistryV1.sol:751–756,893–895`：全局暂停只是 Registry 自有 `emergencyPauseEnable`，由独立暂停/恢复角色变更；这里不是 SBT 外部暂停。

**执行路径与影响**：运维暂停 → 升级管理员调用 Hook/Router/LPManager 升级 → 在 pause 检查直接回滚。该路径不需要攻击者操控，只需真实应急暂停。因此“暂停 → 修复升级 → 恢复”的常见流程不成立。现有恢复角色可以先恢复再升级；通过具备相应权限的可信 batch/coordinator 也可能原子完成恢复/升级/再暂停，所以不是永远锁死。但单笔普通升级必须先解除保护，分散角色的流程也更复杂。

**与新 Factory 功能的关系**：Registry 新 `replacePermissionsAdapterFactory`（276–310）要求全局暂停，Router/LPManager 升级却要求未暂停，进一步需要明确顺序。已有 `script/lib/TSVFactoryMigration.sol:78–83,108–121,196–211` 的专用迁移使用未暂停的一次性 Registry/Router bridge+coordinator 路径，说明迁移可以绕开这个操作约束，但该脚本不是通用暂停升级能力的修复。

**修复价值 P1（高）**：应急流程收益明显，改动范围有限；建议只去除升级入口和 Hook 授权中的 pause 阻断，不能去除角色校验、Router 的 locker 校验、PoolManager/Factory 绑定。补充“暂停状态授权升级成功、非升级管理员失败、升级不自动取消暂停、恢复后功能正常”的回归。不能仅为风格一致而给 Registry/Ledger 增加同样未暂停门禁。

## #17 / No.6.4：candidateUnderlying 两次查询

**结论：代码观察仍成立；属于准入路径的小幅 gas/简化优化，不是安全修复。**

`src/v1/libraries/PermissionedValidationLib.sol:112–124` 先读取 `permissionsAdapterOf(w)`，检查非零，再读取 `verifiedPermissionsAdapterOf(w)` 并要求一致。随后 125–134 仍校验 W 代码、PoolManager、PERMISSIONED_TOKEN、Checker 接口和资产身份。

当前 Factory 保证 verified 映射是原始映射的已验证子集：

- `src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol:22–30` 仅由 create 写入原始映射；35–45 从原始映射读取 U，验证 backing 后用同一 U 写入 verified，无改写/撤销入口。
- `script/lib/TSVFactoryMigration.sol:31–38,41–61` 的 compatible Factory 对本地 adapter 同样以 localAdapters 的 U 写 localVerified，对 legacy adapter 则一起回落到旧 Factory；对这些实际实现依旧保持一致性不变量。

因此可直接 `u = verifiedPermissionsAdapterOf(w); if (u == 0) revert`，后续其他校验不变。该调用由 Registry `_registerPermissionedCurrency`（`src/v1/core/TSVRegistryV1.sol:823`）使用，不在每笔 swap 的热路径；节约的 gas 总量有限。新的可更换 Factory 仅验证接口/绑定，不在语言层面保证任意未来 Factory 的两个 getter 一致，所以简化的前提应记录为 Factory 接口约束，并随新 Factory 审计。

**修复价值 P3（低）**：可顺手简化，不值得单独以安全紧急变更发布；保留现状也合理。不能连带删掉下游 W/U、PoolManager 和 Checker 边界校验。

## #21 / No.6.8：额度按股票实际 delta 统计的含费差异

**结论：行为仍存在，但是否是问题取决于业务额度定义；现有文档已确认采用实际池 delta，未看到本次所读文档对双向含费差异给出明确例子。**

- Hook `src/v1/core/TSVHookV1.sol:228–232,309–315` 对股票侧 delta 取绝对值，再调用对应 legal-share adapter 转换；不剥离 fee。
- Ledger `src/v1/core/TSVVolumeLedgerV1.sol:70–85` 取唯一股票腿的 legalShares 并加到 usedWad，当日超额则整个交易回滚；没有依据方向补偿手续费。
- 固定主仓源码 `lib/v4-core/src/libraries/Pool.sol:370–381` 的输入量以 `amountIn + feeAmount` 计入，而输出量是 amountOut；`lib/v4-core/src/PoolManager.sol:227–236` 也明确费用在输入币上。因此卖股票 W→Q 时股票 delta 包含 W 输入手续费，买股票 Q→W 时股票 delta 为输出 W，不含 Q 手续费。
- `docs/CONTRACT_ARCHITECTURE.md:13–15` 已说明“池内实际结算数据”作为额度输入，`docs/TEST_SPEC_V1.md:26,38` 同样使用 actual pool delta。它们已支持当前实现的流量口径，因此不能直接判定这是未修复的错误计量。

**具体例子（仅说明口径，不主张具体固定 swap 价格）**：某卖单股票侧 delta 为 -1,000 U，其中手续费 3 U、本金 997 U，则额度按 1,000 U 对应股数消耗；某买单用户实际获得 997 U，则额度按 997 U 对应股数消耗。以“实际股票流出/流入量”定义，两者一致遵循股票资产实际净交付方向的绝对流量；以“去费成交本金”定义，卖出 1,000 的用量则多计 3。不能仅因买卖数值不同就推导可绕过额度或资产损失。

当前 TSVRouter 公开入口只构造 exact-input 单跳（Router 280–299）；报告提到的 exact-output 应在未来引入相应入口时再覆盖，不应暗示当前用户已有该入口。

**修复价值 P2（中，主要是产品定义和测试）**：应由业务明确额度是股票毛流量、去费成交量，还是其他法定统计口径；保留 actual-delta 设计时补充买卖含费示例及零/高费率回归即可，不必改合约。只有确认监管/产品要求去费对称口径后才设计变更，不能凭优化项直接从所有方向减手续费，尤其 Q 输入侧的手续费与 U 输出不在同一计价单位。

## #22 / No.6.9：beforeSwap 和 afterSwap 都检查 multiplier

**结论：重复读取仍存在，但不是安全问题；对当前严格限定的调用链可优化，默认不建议单独修改。**

已查看原图 `XvbGbGTZJozLXhx5t1VlYh6fgFb.png`：红框实际是 beforeSwap 与 afterSwap，报告文字“beforeSwap 和 beforeSwap”是笔误。

- `src/v1/core/TSVHookV1.sol:210,228` 两处均调用 `_validateMultiplierSnapshot`；289–301 从 Registry 定位 adapter，读取 currentMultiplier，比较非零且等于请求快照。
- 在 pinned PoolManager `lib/v4-core/src/PoolManager.sol:200–219,227–250`，这两个 hook 之间只执行 Pool.swap、协议费记账和发事件，没有外部 token 转账、用户可写回调或第二个 Hook。Hook.beforeSwap 是 view；其 Registry/adapter 查询均走静态调用。`ERC8056DirectLegalShareAdapter.sol:33–57` 仅静态读取 U 的 uiMultiplier/decimals。
- 因此不能以“用户可在两个 hook 之间通过 ERC20 回调写倍率”来证明 afterSwap 必需：当前链路上没有这种回调。若倍率仅由 U 存储或同一区块时间确定，两次读取相同，属于冗余防御。
- 但 `IDirectLegalShareAdapter` 接口并未保证任意实现的返回值在不同调用点恒定；Pool 自身价格/状态在两次查询间变化，未来自定义 adapter 或 PM/Hook 升级也可能增加依赖。afterSwap 位于额度记账前，保留其校验能明确维护“记账时倍率匹配报价快照”的边界。删除要以限定 adapter/PM 不变性为前提，不是机械去重。

**修复价值 P3（低）**：如果没有 gas 实测和热路径成本目标，保留更划算。如要优化，优先保留 afterSwap 记账前校验，可在证明调用者只通过固定 PM 且所有准入 adapter 都满足倍率不变性后，讨论去掉前置读或合并快照校验与换算；同时更新“失配时原子回滚”的测试。保留现状不属于审计缺陷未修复。

## #26 / No.6.13：TSVDirectSettlementLib 无调用

**结论：原始观察仍成立，是死代码清理建议，无直接安全收益。**

固定 SHA 下执行 `git grep -n TSVDirectSettlementLib <SHA> -- src script test`，仅命中 `src/v1/libraries/TSVDirectSettlementLib.sol:10` 自身定义。23–55 两个 helper 都是 internal，当前生产合约未 import 或调用；旧审计快照中的引用属于历史记录，不能当当前使用。

该库提供带实际余额差校验的 ERC20 settle/take helper，而当前 Router/LP 走 `TSVPermissionedSettlementLib` 等路径。未使用库不会因为文件存在而拥有资金权限，也不会把这两个 internal helper 链接进未引用合约的运行时代码。因此不能把删文件作为结算安全修复；若要解决结算精确到账，需要另行评估实际调用路径。

**修复价值 P3（低）**：可删除或移到明确的参考/历史目录，减少读者误以为已启用精确余额校验的混淆。无需为使用该库而替换当前结算逻辑，也不应声称删库能显著缩小正在部署的合约字节码。

## #27 / No.6.14：swap 后清理上下文状态

**结论：部分已实现，activePayer 在 265 行已清零；其他残留没有构成旧权限上下文复用，完整清理不是必要安全修复。**

已查看原图 `VI8EbzzwwoOsAExBj8MlmvCtgqg.png`，图中也已经有 `activePayer = address(0)`，故原建议把 activePayer 列为未删除项不准确。

- `src/v1/periphery/TSVSwapRouterV1.sol:248–251` 每次进入 `_swap` 都在外部付款/PoolManager.unlock 前重写 participant、recipient、inputCurrency、payer；三个公开 swap 入口均带 isNotLocked（114–166）。
- `ReentrancyLock.sol:10–15`（固定 v4-periphery 子模块 commit `9969eec44cfdf07e24b41de47f40276a58401976`）在入口前设 transient locker、退出后清零，嵌套入口被拒绝。
- `msgSender()` 在 Router 176–178 明确要求 locker 非零，否则返回零，不会在空闲时暴露旧 participant 为有效身份。
- 回调入口 `src/v1/vendor/v4-router/base/SafeCallback.sol:15–16` 只接受固定 PoolManager；外部用户无法直接调用 `_settle/_take` 消费旧 payer/recipient。
- 265 行清零 payer；266–268 读金额返回并校验 actualIn 与请求数量一致。正常 SWAP/SETTLE_ALL/TAKE_ALL 路径会重写金额；本次未证明 stale amount 能绕过请求校验或让旧上下文获授权。

**修复价值 P3（低，可不改）**：清空剩余上下文可增加可读性，但会增加存储写成本；字段 private，空闲 msgSender 已有显式边界。若实现清理，先把 actualIn/actualOut 缓存到返回值，再清理，回归所有成功/失败和重入场景。升级合约不能通过删除/重排现有 storage 声明实现“清理”，否则可能引入布局不兼容；直接采用 transient storage 也属于独立设计变更，不应作为本项的小修顺带进行。
