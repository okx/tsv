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
