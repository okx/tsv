# 旧失败测试在验证什么

> 失败日志基准：`6743896068174c0bd8472f893b661ab23366e409`，2026-10-12 的 [coverage.log](coverage.log)。
>
> 当前对照代码：`50414fcbbf38ae52c383a80d2794fcf29a50fad2`，`fix/uniform-reason-code-require`，对应 [MR !45](https://gitlab.okg.com/web3-dex/tsv/-/merge_requests/45)。本文用于解释测试目的及代码变化，不包含新的测试执行结果。

## 1. 失败范围

这批日志是编译 import 失败，没有执行到测试断言。缺少的源码包括 `TSVDataInboxV1`、`TSVReports`、`TradeDayLib`、`ReportValidationLib`、`BackedAutoFeeLegalShareAdapter`。

日志直接指向 12 个 `.t.sol` 测试文件，共 95 个 `test*` 用例，以及 5 个共享 fixture/handler。共享 fixture 阻塞了其他套件，不能将其余测试当成通过。之后 `main` 的 `0adb4b5` 合入了测试清理：删除 30 个旧测试文件，包含 213 个 `test*` 函数及 2 个运营模型 `invariant*` 函数。当前源码剩余 9 个测试文件、70 个 `test*` 函数；这些数量均来自源码扫描，不代表测试通过。

下文“旧测试验证”描述历史测试的预期，即使该预期在失败日志基准时已经与合约不一致，也不把它当成当前实现保证。

## 2. 直接阻塞编译的 12 个套件

| 旧测试文件 | 用例数 | 原本验证什么 | 当前代码关系 |
|---|---:|---|---|
| reports/Ingress | 4 | 报表授权、ID 去重、来源时间不倒退、过期拒绝，禁止绕过 Inbox 直接写 Ledger/Registry | Inbox/报表元数据机制已移除；授权分别在 Registry/Ledger 直接入口检查 |
| reports/PayloadValidation | 5 | 市场、ADTV、quota 业务字段合法性，失败不消耗 ID，修正后可重试；清除 quota 保留 used | 业务结构体及去重状态已移除；当前 quota 是直接数组赋值，写零表示零额度 |
| reports/AdtvBatch | 6 | 1–100 条批量 ADTV 的排序、去重、统一月份，任何位置出错都整批回滚并可重试 | ADTV 批量机制已移除；当前 multicall/数组设置的原子性是另一组入口与规则 |
| reports/Reports | 7 | 多证券批量、quota override/clear、上限、市场 HALT/RESUME、重放与 reporter 角色 | ADTV/hard-cap/override 已移除；暂停和角色业务保留但直接设置最终 mode |
| reports/CapCorrections | 5 | ADTV/tier 调整即时改变额度、历史 used 不变、整数向下取整、未来 quota/月份适用性 | ADTV×tier 的 hard cap 已移除；现在直接写每证券每天的绝对额度，used 可由独立接口更正 |
| reports/SplitFactor | 14 | 拆并股分数、按日生效、checkpoint 更正/取消、跨月重置、同证券/不同证券隔离、最终一次取整 | Ledger 的拆并股 checkpoint 机制已移除；U 的实时 multiplier 换算仍是独立功能 |
| reports/SplitFactorBoundaries | 14 | 拆并股授权、非法字段、重放、事件、临界秒锁定、极大数及溢出回滚 | 报表与 checkpoint 机制已移除；不能直接改名成当前 multiplier 测试 |
| reports/Bindings | 3 | Ledger/Inbox 初始化、可配置日切 offset、管理员专属且一次性的组件/writer 绑定 | Proxy 初始化和 Registry 一次绑定仍在；Inbox、Ledger.bindWriters、可配置 offset 已移除 |
| registry/Pauses | 12 | 全局/证券暂停、暂停位累加及独立恢复、事件、重上市保留暂停、暂停时替换 converter、未知池拒绝 | 暂停/替换业务仍在；HALT/RESUME 变为最终 mode 赋值，事件和 converter 类型有变化 |
| governance/ComponentUpgradeRoles | 6 | 多组件升级角色授予/撤销、禁止本地 AccessControl、初始化锁、admin 配置继承、Router immutable 兼容性 | 大部分业务仍在；组件清单、初始化参数和 Ledger writer 绑定已变化 |
| integration/WrappedPolicy | 8 | 真实参与者身份、多个 SBT 权限并集、发行方策略撤销、暂停、U 授权 Router、输出目的地、Router immutable 依赖 | 核心业务仍在；fixture、暂停入口、quota getter 等需按当前代码解释 |
| integration/WrappedSwap | 11 | U↔Q 资金守恒、W mint/burn、实际成交记账一次、共享额度、手续费、失败回滚、合约钱包、非法 Adapter | 核心交易仍在；旧额度/事件已变化，逐笔精确转账、库存快照拒绝等旧安全预期需单独确认是否仍为产品要求 |

## 3. 对决策有影响的具体语义变化

| 旧测试预期 | 当前实现 |
|---|---|
| 未设置 daily override 时，使用 `ADTV × tierBps` 默认上限；CLEAR 恢复默认 hard cap | 未设置 `Quota[security][ESTDay]` 等于 0；写 0 也等于 0 额度，没有默认 hard cap |
| HALT TRADE 后 HALT LP 累加到 ALL；RESUME 只清指定暂停位 | `applySecurityStatus(securityId, mode, reasonCode)` 直接 `state.pauseMode=mode`；从 TRADE 设置 LP 后最终是 LP |
| 报表 ID 全局唯一、sourceTimestamp 单调、submitDeadline 校验、可回放查询 | Core Registry/Ledger 没有这些报表状态与字段；`reasonCode` 是原因码，不是去重 ID |
| 调整日切 offset，处理 20/28 小时过渡日、Gregorian 日期和历史 checkpoint | 固定 EST/UTC-5：`(block.timestamp - 5 hours)/1 days`；day 是 epoch day 整数 |
| Ledger 每月 ADTV 与拆并股分数共同计算当日上限 | 后台直接给日额度；实时 `uiMultiplier` 只用于 actual raw delta→legal-share WAD 换算 |
| 成交日志 `SwapAccounted` 携带 W/U/方向/raw/法定份额 | 当前事件为 `VolumeUsed(securityId,poolId,ESTDay,amount)` |
| Ledger 的 used 只能来自成交追加 | 当前还有 `setUsedWad`，授权 oracle 可以覆盖用量，包括清零或写到 quota 以上 |
| 库存快照、少付、额外 sender fee 必须统一以 SettlementMismatch 拒绝 | 当前结算 helper 为 SafeERC20，没有逐笔两端余额差与完整库存快照检查；W 仍检查包装时 surplus 和 PM 独占 W |
| security LP pause 阻止普通 LP 和两类 unwind | 普通 LP 受 security LP gate；授权 unwind 绕过普通 gate，但仍受全局 pause |

当前依据：[Registry](../src/v1/core/TSVRegistryV1.sol#L643)、[Ledger](../src/v1/core/TSVVolumeLedgerV1.sol#L42)、[Router](../src/v1/periphery/TSVSwapRouterV1.sol#L189)、[结算库](../src/v1/libraries/TSVPermissionedSettlementLib.sol#L8)、[LPManager](../src/v1/periphery/TSVLPManagerV1.sol#L140)、[Hook](../src/v1/core/TSVHookV1.sol#L163)。

## 4. 共享测试环境为什么一起失效

| 辅助文件 | 原本做什么 | 与当前代码的不一致 |
|---|---|---|
| FoundationFixture | 部署 Registry/Ledger/Inbox/PM/Factory，授角色，注册股票/报价，准备统一断言工具 | Ledger.initialize(registry,offset)、Inbox 部署、5 参数 Registry.bindComponents、Ledger.bindWriters、含 tierBps 的 setTierPolicy 都已变更 |
| OperationsFixture | 在基础场所中构造市场/ADTV/quota 报表，封装提交和报告状态快照 | 依赖已删除结构体、Inbox、旧 getter |
| SplitFactorFixture | 构造拆并股报表、分数 checkpoint 与状态对照工具 | Ledger 拆并股/report/dayStart API 已移除 |
| OperationsHandler | 驱动随机报表、用量、时间、日切调度及因子变更，并与独立模型比较 | 驱动的大部分操作已移除；当前模型应解释 direct quota、used correction、固定 EST 等实际操作 |
| WrappedSwapFixture | 用真实 PM/W/Router/Hook 准备 U/Q 池、资金、参与者 SBT 和模拟发行方；通过 Inbox 初始化额度 | 交易主体仍存在，但环境初始化/准入/暂停/日额度准备采用旧 API |

Fixture/handler 自身不是独立测试用例。恢复一个 helper 的编译，并不能证明套件中的旧业务期望仍成立。

## 5. 其他一起被清理的 18 个套件

下表列出同次删除但没有在该日志里直接报缺失 import 的套件，共 118 个 `test*` 用例。它们多数受共享 fixture 阻塞；没有逐个执行失败的证据。

| 旧套件 | test* 数 | 原本验证的业务 |
|---|---:|---|
| integration/LPHook | 9 | LP mint/increase/decrease/收手续费/burn、各种暂停与 unwind、退出失败回滚、空仓位、授权回调和 multiplier snapshot |
| integration/DexAdapter | 11 | caller 签名与真实参与者、防身份伪造、nonce 重放/过期、资金方向、独立 recipient/refund、部分成交、名单撤销与重入锁 |
| integration/WrappedBoundaries | 12 | 建池原子性、未知池拒绝、生命周期、全额 exact-in/min-out、畸形请求、callback 来源、重入/锁释放、升级中操作、精度换算 |
| integration/WrappedInventory | 3 | 预存 U/捐赠不改变用户资金与库存基线、交易中 U 余额变化回滚、存量 U 不能掩盖少付 |
| governance/BusinessRoles | 6 | default admin 和业务角色授予/撤销/自退、不能替他人退角色、管理权转移 |
| registry/AdapterChanges | 3 | 不同暂停模式替换转换器、历史 used 保留、接口及 currency 身份拒绝 |
| registry/Admission | 10 | W/U/证券原子准入、首次/追加 W 的库存、canonical 绑定、报价隔离、W/Q 组合、仅禁用未来建池、issuer owner 变更 |
| registry/Configuration | 10 | tier 容量、SBT 配置/事件、身份持有与权限区别、多个身份权限并集、错误读取、非法 bit/decimals |
| registry/Consumers | 10 | Hook 实际 delta→份额转换、converter 替换、共享 quota、极小/极大有符号量、伪造 delta/份额/证券/池拒绝 |
| registry/Environment | 5 | 固定 Factory/SBT/组件绑定、接口畸形/EOA 拒绝、管理员权限与失败不留半配置 |
| registry/FactoryChecker | 8 | Factory 验证不等于 TSV 准入、拒绝别的 Factory、issuer checker 与 TSV SBT/暂停相互独立 |
| registry/Lifecycle | 9 | 上/下市、tier 容量、池 PAUSE、NFT/tick 计数与 listedPoolCount、历史身份保留、全局 pause 独立 |
| registry/PauseBoundaries | 3 | 原因码/重复暂停不修改状态、pauser/resumer 分权、暂停事件 |
| registry/Permissions | 4 | SYMBOL_ADMIN 撤销后拒绝、pauser/resumer 互不越权、业务 operator 不取得 admin 权限、仅固定 LPManager 可更新池 |
| reports/CalendarBoundaries | 7 | Gregorian 闰日/月/年边界、秒级 day 归属、20/28 小时过渡、日切取消窗口、历史 offset 查询 |
| reports/TradeDay | 5 | Gregorian 当前日、可调日界线、checkpoint 调度/取消、连续变更、过去日期或超 4 小时偏移拒绝 |
| reports/StatefulOperations | 2 + 2 invariant* | 多步骤报表/更正/撤权/成交/拆股/跨月/长短日，账本与独立日期和报告模型始终一致 |
| trading/VolumeAccounting | 1 | 实际成交量用 canonical converter 换算，多池共同消耗证券额度 |

`StatefulOperations` 的两个函数名是 `invariantCalendarMatchesIndependentModelAndHistoryIsStable`、`invariantReportsCapsReplayProtectionAndUsedMatchModel`。之前 x-ray 扫描只匹配 `invariant_`，因此漏计，不能据原计数断言旧代码没有运营模型的 invariant 校验。

## 6. 当前已有的相关测试

[VolumeLedgerSetUsedWad.t.sol](../test/unit/v1/trading/VolumeLedgerSetUsedWad.t.sol) 的 11 个用例已经采用当前 `Quota` / `usedWad` 模型，验证角色授权与撤销、zero securityId 拒绝、覆盖用量/事件/其他日期隔离、后续成交额度与回滚、超过 quota 后阻断、重复日期末值、空批次，以及 multicall 原子性/调用顺序/权限。它使用 mock 的 Registry.hook/getPool，不等于真实 Router→PM→Hook→W 的资金链路覆盖。

其余保留套件位于 adapters、governance、deployment 和 trading/Initialization。本次没有重跑，所以这里只说明源码中存在的验证内容。

## 7. 95 个直接受阻用例逐项说明

以下为 `6743896` 历史源码的函数级目录。链接打开固定版本，当前工作树已无这些文件。

### Ingress.t.sol

历史路径：[test/unit/v1/reports/Ingress.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Ingress.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testEveryReportRejectsInvalidMetadataWithoutConsumingState](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Ingress.t.sol#L12) | 逐种提交市场/ADTV/quota 报表，注入零 ID、重复 ID、来源时间倒退/未来时间和过期 deadline；预期拒绝且不消耗元数据，合法重试可接受。 |
| [testReportRolesAreIndependentAndRevocationAppliesToEveryEntry](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Ingress.t.sol#L57) | 把 HALT 与 VOLUME reporter 权限分开；错误角色、角色撤销、自退后的所有对应入口均拒绝，重新授予后恢复。 |
| [testReportIdsAreGlobalWhileSourceTimeIsTrackedPerKindAndSecurity](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Ingress.t.sol#L98) | 同一 reportId 在不同证券/不同报表种类中不能重复使用；来源时间的单调记录按报表种类和证券分别保存。 |
| [testDirectWritersCannotBypassInboxAuthorization](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Ingress.t.sol#L126) | 直接调用 Ledger/Registry 的底层 writer 应拒绝，以保证所有报表先经过 Inbox 授权与元数据处理。 |

### PayloadValidation.t.sol

历史路径：[test/unit/v1/reports/PayloadValidation.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testMarketFieldsRejectAndSameIdCanBeCorrected](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol#L12) | 对市场报表测试零/未知/已下市证券、非法暂停模式和零 reasonCode；失败不消耗 ID，同 ID 修正后可重试。 |
| [testAdtvFieldsRejectAndSameIdCanBeCorrected](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol#L46) | 对 ADTV 测试无效证券、零 ADTV、非法来源年月和已下市证券；失败不写状态，修正后可重试。 |
| [testQuotaFieldsRejectAndSameIdCanBeCorrected](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol#L75) | 对 quota 测试无效证券、非法 SET/CLEAR、零 SET、超过 hard cap、无效日期、未 SET 就 CLEAR及下市；失败不消耗 ID。 |
| [testCorrectionsUseUniqueIdsAndNondecreasingSourceTimeAcrossPeriods](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol#L117) | 更正使用新 reportId，并要求来源时间不倒退；不同来源月份分别保存 ADTV，相同来源时间/相同值但新 ID可接受。 |
| [testQuotaClearMustBeZeroAndKeepsUsage](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/PayloadValidation.t.sol#L134) | CLEAR 必须携带 quotaWad=0，保留已成交 used；重复 CLEAR 拒绝，重新 SET 后按新额度计算剩余量。 |

### AdtvBatch.t.sol

历史路径：[test/unit/v1/reports/AdtvBatch.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testBatchRejectsEmptyAndAboveMaximumBeforeAnyWrite](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L10) | 空数组和101条 ADTV批次在任何写入前拒绝；原最大批量为100。 |
| [testSingleElementBatchUsesSameRulesAsSingleReport](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L23) | 单元素批次与单条 ADTV 使用同样规则，允许合法更正已存 ADTV。 |
| [testMaximumBatchLastFailureRollsBackAllReportsThenRetrySucceeds](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L32) | 100条中最后一条非法时，前99条的值、来源时间和ID消费全部回滚；修正末项后整批可重试成功。 |
| [testBatchRejectsZeroDuplicateDescendingAndMixedMonthAtomically](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L52) | 批次中零证券、重复证券、非升序证券、混合月份均导致整批回滚。 |
| [testBatchDuplicateReportIdAcrossSecuritiesRollsBackAndCanRetry](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L75) | 不同证券重复 reportId 也导致整批失败；换成独立 ID 后可重试。 |
| [testFuzzBatchFailureAtEverySmallBatchPositionIsAtomic](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/AdtvBatch.t.sol#L88) | Fuzz 将非法 ADTV或过期 metadata 放在任一小批次位置，验证全批原子性。 |

### Reports.t.sol

历史路径：[test/unit/v1/reports/Reports.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testAdtvBatchAcceptsMultipleSecuritiesInOneSubmission](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L14) | 一次 ADTV批量提交可写入多个证券，并按证券分别查询。 |
| [testAdtvBatchIsAtomicWhenOneReportIsInvalid](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L31) | 任一 ADTV 为零时整个批量回滚，所有 ID 和证券值都不写入。 |
| [testDailyQuotaIsOptionalAndClearRestoresTheHardCap](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L51) | 日 quota override 是可选值；SET 限制到自定义值，CLEAR 后恢复 ADTV×tier 的默认 hard cap。 |
| [testQuotaRejectsInvalidClearAndValuesAboveHardCapAtomically](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L72) | 无 active SET 的 CLEAR、quota零 SET和超 hard-cap的 SET 被拒绝，ID不被消耗。 |
| [testMarketReportDoesNotNeedHeartbeatAndReplayFails](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L91) | 市场 HALT状态不因长时间没有 heartbeat自动失效；有效 RESUME可恢复，但同报表再次提交拒绝。 |
| [testReportsRequireDirectRoleCaller](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L104) | 提交必须来自具有 reporter 角色的直接调用者，普通地址不能提交市场报表。 |
| [testMarketReportsRejectNoneNoopsAndInvalidActionsAtomically](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Reports.t.sol#L111) | 无意义 HALT/RESUME、重复暂停位、非法 action必须原子拒绝；合法指定暂停位恢复成功。 |

### CapCorrections.t.sol

历史路径：[test/unit/v1/reports/CapCorrections.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testAdtvCorrectionClampsExistingQuotaAndPreservesConsumedVolume](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol#L9) | 降低 ADTV 后生效 cap收紧而保存原 quota与used；上调 ADTV不能绕过已有较低 override，CLEAR后才恢复hard cap。 |
| [testTierPolicyCorrectionImmediatelyChangesCapWithoutResettingUsedOrQuota](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol#L31) | 更改 tierBps 即时改变 cap，但不清零 used或日override；恢复较高比例后剩余额度按原用量计算。 |
| [testAcceptedReportsDoNotExpireWithSubmissionDeadline](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol#L48) | 报表在 submitDeadline前被接受后，其业务状态不因deadline已过而自动失效。 |
| [testFuzzHardCapUsesFloorAndExactLimitIsAllowed](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol#L59) | Fuzz 比对 floor(ADTV×bps/10000)，恰好达到上限允许，多消耗1拒绝；取整到0的额度不能成交。 |
| [testFutureDayQuotaDoesNotChangeCurrentDayAndRequiresApplicableMonth](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/CapCorrections.t.sol#L80) | 写未来日期quota不改变当前日；目标日依赖适用来源月份的 ADTV，缺月数据时不能成交。 |

### SplitFactor.t.sol

历史路径：[test/unit/v1/reports/SplitFactor.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testDefaultFactorKeepsExistingAdtvTierAndMissingReportRules](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L10) | 默认因子1/1不改变 ADTV×tier 和缺少 ADTV时禁止成交的规则。 |
| [testSplitActivatesExactlyAtDayStartWithoutAnotherTransactionAndKeepsOldUsed](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L22) | 拆股因子在指定日开始秒自动生效，不需要额外激活交易；旧日已用量不变，新日用新上限。 |
| [testReverseSplitUsesAnExactFractionAndCanReduceTheCapToZero](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L45) | 并股使用原始分子/分母精确比例，可缩小 cap到0并禁止成交。 |
| [testSeveralAbsoluteFactorsUseTheLatestApplicableCheckpointInsteadOfMultiplyingAgain](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L65) | 多个因子保存绝对比例，查询选最近已生效 checkpoint，而不是把因子反复相乘。 |
| [testNewAdtvSourceMonthStartsAtOneAndDoesNotApplyPreviousMonthsSplitAgain](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L81) | 新的 ADTV来源月份以新月份单位作为基准，默认因子回到1/1，不重复应用前月拆股。 |
| [testFactorsAreIndependentAcrossSecurities](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L97) | 不同证券各自保存因子，不互相改变额度。 |
| [testFactorCanBeScheduledBeforeMonthlyReportButDoesNotSubstituteForMissingAdtv](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L112) | 可以先排未来因子后报 ADTV，但因子本身不能替代缺失 ADTV。 |
| [testOnlyLatestPendingCheckpointCanBeCorrectedAndItsOldReportRemainsConsumed](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L126) | 只能更正最新尚未激活 checkpoint；不能改较早 checkpoint，旧报告 ID仍保持已消费。 |
| [testCancelLatestPendingFactorRestoresEarlierFactorWithoutOrderCounters](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L141) | 取消最新待生效因子恢复此前因子；全部取消后恢复1/1，也可以重新排同日因子。 |
| [testActivatedFactorCannotBeEditedCancelledOrReplayed](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L156) | 因子达到生效日后不能更正、取消或重放，历史比例保持不变。 |
| [testTwentyAndTwentyEightHourTransitionsActivateAtTheConfiguredDayStart](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L171) | 在20/28小时日切过渡下，因子仍只在配置的目标交易日起始秒激活。 |
| [testQuotaRemainsAnAbsoluteTargetDayOverrideAndIsClampedByTheAdjustedHardCap](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L192) | 目标日期 quota 是绝对值，不再乘拆股因子；实际可用额度仍受调整后hard cap限制。 |
| [testTierAndAdtvCorrectionsStillParticipateInTheAdjustedCap](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L208) | tierBps和ADTV更正参与拆股后cap计算，并不会产生另一个与因子无关的上限。 |
| [testCapUsesOneFinalFloorInsteadOfFlooringBeforeApplyingTheFactor](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactor.t.sol#L220) | 只在完整计算末尾取整：floor(3×1/2×2)=3，不先floor(3×1/2)再乘2。 |

### SplitFactorBoundaries.t.sol

历史路径：[test/unit/v1/reports/SplitFactorBoundaries.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testScheduleCorrectionAndCancellationEventsCarryReportedFactorsAndReportIds](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L14) | 排程、更正、取消事件必须带原始因子分数、来源月、目标日和相关报告ID。 |
| [testDelistedSecurityCannotReceiveNewFactorReports](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L30) | 证券下市后新因子报告拒绝，因子和metadata不变。 |
| [testOnlyVolumeReporterCanScheduleOrCancelAndRevocationTakesEffectImmediately](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L39) | 仅VOLUME reporter能排或取消因子；HALT角色及无角色地址不能操作，撤销角色即时生效。 |
| [testLedgerFactorWriterIsOnlyTheBoundInbox](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L67) | 只能固定 Inbox 调用 Ledger 因子writer，直接调用底层acceptSplitFactor拒绝。 |
| [testInvalidBusinessFieldsDoNotConsumeReportMetadataAndTheSameIdCanBeRetried](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L75) | 无效证券/月/日期/分数分子分母/action不消耗报告ID，修正业务字段后可使用同ID重试。 |
| [testInvalidIngressMetadataAndReplayLeaveAllFactorStateUnchanged](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L100) | 零ID、来源时间倒退/未来、过期deadline、重放都不改变已存因子或报告metadata。 |
| [testReportIdsAreGlobalAndSourceTimestampsAreScopedByReportKind](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L122) | 因子报告与ADTV等其他流共用reportId去重，但来源时间分别按kind保存。 |
| [testSourceTimeAndSubmissionDeadlineCannotSelectAnIntradayActivationTime](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L133) | 来源时间/deadline不能把未来日因子提前到日内激活；只看生效日界线。 |
| [testCancellationRequiresTheLatestPendingDayAndZeroFactorComponents](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L148) | 取消必须指向最新待激活的目标日，且取消分子分母均为0；空历史取消拒绝。 |
| [testCancellationOneSecondBeforeStartSucceedsButAtStartIsLocked](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L168) | 生效前1秒允许取消，在生效秒开始锁定，禁止取消。 |
| [testFactorOverflowRejectsScheduleOrAdtvCorrectionWithoutPoisoningFutureCaps](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L184) | 排因子或上调ADTV导致cap算术溢出时回滚；修正基准后原失败ID可重试，既有可用cap不被破坏。 |
| [testScheduledFactorBeforeAdtvAlsoGuardsTheFirstReportAgainstOverflow](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L207) | 先排因子后首次报ADTV时，同样检查溢出，非法首报不消费ID。 |
| [testMaximumEqualFractionIsPreservedAndAllMonthDaysRemainQueryable](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L219) | 最大相等分子/分母保持原样且比例为1；整月checkpoint均可正确查询，新月默认1/1。 |
| [testFuzzAdjustedCapMatchesIndependentBoundedIntegerFormula](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/SplitFactorBoundaries.t.sol#L235) | Fuzz 用独立有界整数公式比对调整后cap，验证分数、bps和最终向下取整。 |

### Bindings.t.sol

历史路径：[test/unit/v1/reports/Bindings.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Bindings.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testLedgerAndInboxInitializationRejectZeroDependenciesAndInvalidOffsets](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Bindings.t.sol#L13) | Ledger/Inbox初始化拒绝零依赖及非法日切offset，最大合法offset86399可保存。 |
| [testRegistryBindingIsGovernorOnlyAtomicAndOneTime](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Bindings.t.sol#L32) | 仅default admin可一次性绑定Registry五个旧组件；任何非法组件让整组赋值回滚，重复绑定拒绝。 |
| [testLedgerWriterBindingIsGovernorOnlyAtomicAndOneTime](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/reports/Bindings.t.sol#L70) | Ledger仅default admin可一次绑定Hook+Inbox writers；非法地址整组回滚、发事件、重复绑定拒绝。 |

### Pauses.t.sol

历史路径：[test/unit/v1/registry/Pauses.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testMarketReportRejectsOutOfRangeActionBeforeStateChanges](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L20) | 向旧HALT/RESUME action编码注入超出enum范围值，应拒绝且不改变证券pause与操作gate。 |
| [testRelistingRetainsSecurityPauseState](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L36) | 证券下市再重上市保留原pause；只有明确恢复动作后gate才重新开放。 |
| [testLegalAdapterReplacementDoesNotRequirePause](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L52) | 不必先暂停场所即可替换legal-share converter；验证canonical记录确实改变。 |
| [testLegalAdapterReplacementAllowedByGlobalEmergencyPause](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L60) | 全局紧急暂停时仍允许替换converter，解除暂停后保留新配置。 |
| [testEmergencyPauseBlocksBothOperationsAndCanResume](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L70) | 全局暂停阻止TRADE与LP两个gate，解除后恢复，并正确发暂停/恢复事件。 |
| [testEmergencyPauseRejectsInvalidNoopAndUnauthorizedCallers](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L85) | 零reason、重复启用/解除及缺少pauser/resumer角色拒绝；两角色权限分别有效。 |
| [testPauseEventsExposeEmergencyModeAndSecurityMaskChanges](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L107) | 事件暴露全局pause和证券旧/新状态、暂停mask及报告ID，逐次mask累加反映在事件中。 |
| [testSecurityPauseModesAccumulateAndResumeIndependently](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L138) | HALT通过按位累加，RESUME清指定bit；交易与LP暂停可独立恢复。 |
| [testSecurityFirstLPPauseAllowsTrading](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L156) | 首先仅暂停LP时，LP禁止但交易允许。 |
| [testSecurityFirstAllPauseBlocksBoth](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L161) | 首先暂停ALL时，两类普通操作均禁止。 |
| [testEmergencyAndSecurityPauseRecoveriesAreIndependent](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L166) | 全局暂停与证券暂停分别保存：恢复其中一个不清除另一个。 |
| [testUnknownPoolRemainsDisallowed](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/registry/Pauses.t.sol#L180) | 未知poolId在TRADE/LP两个查询中都不允许操作。 |

### ComponentUpgradeRoles.t.sol

历史路径：[test/unit/v1/governance/ComponentUpgradeRoles.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testRegistryUpgradeGrantAndRevocationApplyToEveryComponent](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L63) | Registry授予/撤销UPGRADE_ADMIN立即作用于Hook/Inbox/Ledger/Router；default admin本身不绕过升级授权，升级保留组件依赖。 |
| [testComponentsDoNotExposeLocalAccessControl](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L106) | 业务组件没有自己的grantRole/hasRole存储入口，角色统一来自Registry。 |
| [testImplementationAndProxyInitializationRemainLocked](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L116) | 实现不可被initialize，proxy不能重复初始化；实现不能直接upgrade，proxy上读proxiableUUID拒绝。 |
| [testLedgerConfigurationTracksRegistryDefaultAdmin](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L131) | default admin转移后旧管理员不能Ledger.bindWriters，新管理员可以绑定Hook+Inbox。 |
| [testRouterAdapterConfigurationTracksRegistryAdmin](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L145) | default admin转移后Router Adapter白名单配置权跟随新管理员，且可以撤销Adapter。 |
| [testRouterUpgradeStillRejectsChangedImmutableDependencies](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/unit/v1/governance/ComponentUpgradeRoles.t.sol#L161) | Router升级若新实现换PoolManager或Factory则拒绝，implementation保持原值。 |

### WrappedPolicy.t.sol

历史路径：[test/integration/local/trading/WrappedPolicy.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testUserIdentityIsAvailableFromFirstCredentialRead](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L40) | 真实用户身份从首次资格读取开始就可见，Router/PM不是身份主体；空闲时msgSender为0。 |
| [testBothIdentitiesAuthorizeBothSwapDirectionsUntilAllAreRevoked](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L47) | 任一已注册SBT身份均能支持双向交易，只有全部有效身份被撤销后才拒绝；未注册ID不计资格。 |
| [testSwapRequiresSwapPermissionAndUpdatesApplyToExistingHolders](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L68) | 只有LIQUIDITY权限不能交易；SWAP位配置更新即时影响已有持有人，多身份权限按并集计算。 |
| [testOnlyTradingPauseBlocksSwapsAndPreservesAccounting](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L90) | 证券LP暂停允许swap，交易暂停拒绝两方向，并且失败不改变额度和资产状态。 |
| [testFuzzPolicyRevocationRejectsBeforeTransfer](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L106) | Fuzz 撤销issuer/wrapper/Hook/SBT/交易开关或启用暂停、制造SBT读取失败/零换算时应拒绝并整体回滚。 |
| [testStockUserMustApproveRouterForUnderlying](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L148) | 用户必须把U allowance给Core Router；只给W授权不能替代。 |
| [testExitAdminNeverReceivesSwapOutputAndIssuerCanRejectUser](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L159) | 普通swap输出不会fallback到exit admin；issuer拒收用户时整笔失败，解除阻止后输出仍给用户。 |
| [testImmutableBindingsCheckedOnInitializeAndUpgrade](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedPolicy.t.sol#L171) | Router构造、proxy初始化及升级校验PM/Factory不可变身份，合法同依赖升级后仍能交易。 |

### WrappedSwap.t.sol

历史路径：[test/integration/local/trading/WrappedSwap.t.sol](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol)

| 历史用例 | 原本验证什么 |
|---|---|
| [testMeasuresGasForBothExactInputDirections](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L32) | 分别观测U→Q和Q→U exact-input的本地fixture gas消耗，属于测量而非生产gas上限断言。 |
| [testBothDirectionsExactInputConserveInventoryAndAccountOnce](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L41) | 双向exact-input消费全输入，用户两币余额/W supply变化准确；只记一次SwapAccounted，surplus不变，PM delta清零，无其他地址持W。 |
| [testVerificationDustAndHistoricalSurplusCannotMaskShortPayment](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L90) | W中的验证dust/历史U surplus不能掩盖本次少付；失败回滚，恢复精确转账后能重试且surplus不变。 |
| [testFuzzNonExactTransfersRollback](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L106) | Fuzz 非精确转账两方向都回滚；没有返回值但实际金额精确的token仍可交易。 |
| [testFuzzExtraSenderFeesRollbackOnBothSides](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L122) | Fuzz token对发送方额外扣费时，不论U/Q或输入/输出方向都应以SettlementMismatch回滚。 |
| [testUnderCollateralizedStockRejectsBeforeSwap](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L133) | 人为降低W内U backing到不足totalSupply时，预期在swap前以SettlementMismatch拒绝且状态不变。 |
| [testNonzeroProtocolFeesGrossNetQuotaAndOfficialWithdrawal](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L141) | 设置非零协议费，股票输入按gross、输出按net计量；官方领取股票协议费时解包U，收款失败回滚。 |
| [testMultipleWrappersShareQuotaAndCanonicalAdapter](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L168) | 同证券多个W/池共享额度和canonical converter；替换converter后各池后续成交都使用新converter并单次记账。 |
| [testQuotaFailureRollsBackPoolInventoryAndEvents](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L227) | 极低quota导致Hook.afterSwap拒绝，用户资产、池、surplus和账本都回滚，Router锁释放。 |
| [testCredentialSubjectIsUserAndContractWalletReceivesUnderlying](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L254) | 资格检查针对真实用户；组件有SBT但用户无SBT仍拒绝；合约钱包可收到U且不会持W，exit admin无输出。 |
| [testUnapprovedAdapterRejectsWithoutAnyStateChange](https://gitlab.okg.com/web3-dex/tsv/-/blob/6743896068174c0bd8472f893b661ab23366e409/test/integration/local/trading/WrappedSwap.t.sol#L273) | 没有获准的普通caller/Adapter无论请求是否完整都不能交易，失败不改变场所状态。 |

