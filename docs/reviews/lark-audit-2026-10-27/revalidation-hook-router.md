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
