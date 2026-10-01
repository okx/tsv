# TSV V1 合约测试规格

版本：1.5，2026-10-02。交易、运营、治理流程和入口总览见[三系统总览](./SYSTEMS_OVERVIEW.md)。本文是[当前编码规格](./CODING_SPEC_V1.md)的验收清单；代币准入按[新版准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)执行。表内用例表示**应实现的目标测试**，当前已执行的本地结果见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。本地 Hook 集成测试以 Backed 行为 mock 作为股票 Currency，并通过唯一的 `BackedAutoFeeLegalShareAdapter` 调用来源 Token 的实时转换方法；普通 `V1LocalERC20` 作为报价币、故障币和普通 ERC-20 兼容性夹具。`ERC8056TestToken` 暂无股数 Adapter，不作为本地 Hook 股票资产。目标新操作只直接收付池内 Currency。

**迁移状态：**SIP 窗口追加/更正与逐日 quota 必填用例已从当前测试移除；当前测试按 D-33/D-34 覆盖可选 quota 和 UTC 自动日切。旧 `TSLAx → wTSLAx` 包装结算路径不属于当前 ABI；旧 Static、ERC-8056 snapshot、ERC-8056 direct 股数 Adapter 及其专属测试已删除。下表只规定当前目标结果，已执行的本地覆盖见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

## 1. 测试边界和证据

测试对象是 TSV 自有 Registry（含全局 SBT 凭证策略）、VolumeLedger、DataInbox、Hook、Router、LP Manager（含 Receipt ERC-721）、股数 Adapter 和治理合约；旧结算 Adapter 只允许出现在隔离的历史单元测试，不属于目标交易路径。外部行为必须分别参照仓库固定的三份源码：`lib/v4-core`、`lib/soul-bound-token-1155`、`lib/TestToken/backed-token-contract`。V4 `PoolManager` 不用自写模拟品代替关键集成用例；SmartWalletSbt 的 `verify/paused` 和发行方 wTSLAx 的 ERC-20 转账、托管及 `getCurrentMultiplier()` 须有源码实例用例，另用故障替身覆盖拒转、少转、重入和升级。

测试层级及完成条件：

| 层级 | 用途 | 必须交付的证据 |
| --- | --- | --- |
| U：单元与确定性向量 | 校验 Backed Adapter 直接换算、状态机、Router 授权、边界、权限 | Foundry 用例；每个表内 ID 有通过/失败记录 |
| I：本地协议集成 | 使用真实 V4 PoolManager 和本地 SBT/Backed 行为 mock；测试完整原子路径 | 调用 trace、关键事件、交易前后状态快照 |
| F：固定区块 X Layer fork | 核对官方 PoolManager 和实际 TSLAx/wTSLAx 代理、代码哈希、ABI、只读状态及受控地址的交易路径 | 固定 block、chainId、合约地址/codehash、运行结果；不广播主网交易 |
| P：fuzz/invariant | 随机交易序列、整数边界、升级/暂停/日切交错 | seed、最小复现输入、`fail_on_revert` 策略与不变量结果 |
| G：gas/部署 | 最坏 `getUnderlyingAmountByShares` 调用、单股票腿计量、双侧资产结算、强退、Hook 代理地址 | 给出所用编译器/优化参数、区块 gas limit、实际 gas 与余量 |

`F` 层固定区块和 RPC 由测试清单提供，不把实时链状态当成稳定断言。测试必须校验 `chainId == 196`、官方 PoolManager 的地址/codehash、TSLAx/wTSLAx 的代理地址、运行代码哈希与可核验的实现/ABI；任何一项不符即让该组测试**失败**，不得自动改为 mock 或跳过。实际代理与本地 Backed 源码不一致时，记为准入阻断项并保持资产 `UNREVIEWED`。底层转账场景只使用测试控制的地址或本地发行方实例；不能控制的真实发行方状态只做只读核验并如实标注未覆盖路径。

V1 TSV 编译产物固定 Solidity `0.8.26`，SBT `^0.8.29`、Backed `0.8.9` 分别构建。跨版本集成测试通过薄接口调用各自产物；不得仅因一个集成 profile 能用 `0.8.29` 重编译 TSV，就把它当作生产 `0.8.26` 字节码的验证。测试清单保存三份外部源码 commit、OZ 版本、TSV 实现/代理 codehash 和 CREATE2 salt。

## 2. 公共 fixture 与状态快照

每个合约测试可按以下组合搭建，不让测试自行猜测资产语义：

| fixture | 固定值或要求 |
| --- | --- |
| `BackedAutoFeeLegalShareAdapter` + `V1MockIssuerShares` / `V1MockIssuerWrapped` | 当前本地股票适配路径；Adapter 直接调用来源 Token `getUnderlyingAmountByShares`，测试 mock 不能代替真实 wTSLAx 准入 |
| `ERC8056TestToken`（`STDx`） | ERC-8056 raw/UI multiplier 行为夹具；当前未配备股数 Adapter，不用于 Hook 股票腿 |
| `V1LocalERC20`（`QUOTE`） | 普通报价币与转账故障夹具，`securityId == 0` |
| `QUOTE6` | 可选的 6 decimals 报价币，用于非 18 位金额边界 |
| `TSLAx/wTSLAx` | 生产目标场景；准入假设与限制见[准入标准 §6](./TOKEN_ADMISSION_STANDARD_V1.md#6-tesla-实例tslax-与-wtslax)；外部实例仍须单独验证 |
| `SEC_A/SEC_B` | 两个不同证券 ID，用于证券与非股票币建池及双股票币对拒绝用例 |
| `Day D` | 按测试输入选择日期和 UTC 起点；`tradeDayId`、ADTV 与 quota 规则见[编码规格 §7](./CODING_SPEC_V1.md#7-角色报告计量日和额度) |
| `Identity` | Governor、Guardian、RecoveryCouncil、Executor、各业务角色各自为单独地址；测试只改变地址和角色，不依赖多签内部签名门槛 |

每个预期回滚的完整路径在发送交易前保存 `S_pre`：用户/Router/LP Manager/PoolManager 的相关 ERC-20 余额、V4 PoolId 状态和仓位流动性、TSV position/Receipt owner、`usedWad`、报告 reportId/序号、暂停计数和治理状态。回滚后逐项断言等于 `S_pre`；仅断言 revert selector 不足以证明原子性。成功路径逐项检查金额、股数、事件、V4 delta 清零及 Router/LP Manager 本次暂存余额回到基线。

## 3. 必须实现的确定性测试

下表每一行的正反面场景均须有独立用例；`U/I/F` 是最低层级，关键路径在 `I` 中重复验证。对外 ABI 的 struct 编码、事件索引及错误 selector 按编码规格 §2、§7、§10、§12 校验。

### 3.1 登记、池和身份

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| R01 U/I | 按目标配置登记 wTSLAx 行为 mock、普通 `QUOTE`/`QUOTE6` Currency，查询 Token/Currency 配置；尝试将无适配器的 `STDx` 登记为股票 | 股票身份及 `BackedAutoFeeLegalShareAdapter` 绑定同一 wTSLAx Currency；新资产 `UNREVIEWED`；无兼容 Adapter 的股票配置失败；旧 TSLAx→wTSLAx 结算 ABI 不属于当前 Registry |
| R02 U | Currency 为零、无代码、代码哈希/decimals 错、重复 Currency、quote 携带 securityId、动态逐笔公式不可复算、股数 Adapter 报错或资产对不匹配 | 每种注册失败且无 TokenConfig 残留；目标 Registry 不用独立静态比例字段判定公式 |
| R03 U/I | 没有审查/股数依据就批准；`APPROVED→DISABLED→APPROVED` 携新依据；活动仓位时更换股数 Adapter 或 Token 关键实现 | 无依据拒绝；合法状态转换成功；未暂停或新 Adapter 公式/版本不符则拒绝；变更不改写旧仓位资产；发行方实际拒转则强退原子回滚 |
| R04 U/I | Tier 名额上限边界、证券重复登记/下架/重上架、跨 Token 同 securityId | `listedCount` 按 securityId 去重；活动池未处理前不能下架；同证券不同 Currency 合并日额度 |
| R05 I | POOL_CREATOR 提交有序 PoolKey、静态 fee、tickSpacing、sqrtPriceX96；随后尝试重复初始化 | 代理 Hook 地址位 `0x3FFF`；PENDING→ACTIVE 与 V4 Initialize 同笔完成；初始价格等于提交值；重复拒绝 |
| R06 U/I | 非 POOL_CREATOR、错 Hook、两侧均为股票（相同或不同 `securityId`）、倒序 Currency、动态费、fee=1_000_000、tickSpacing=0/32768、越界价格 | 全部拒绝；Registry 不残留 PENDING；V4 不创建池 |
| R07 I | 第三方直接调用 PoolManager `swap/modifyLiquidity/initialize/donate`，或伪造 Hook `sender/hookData` | Hook 拒绝；无额度、仓位或费状态变化 |
| R08 I | SBT holder、无证 holder、SBT 全局 paused、SBT revoke；Registry 未配置 SBT；AA 合约钱包直接调用且有/无 SBT | 普通 Swap/LP 仅在 `verify=true && paused=false` 可执行；未配置时回滚 `SbtNotConfigured()`；直接调用能力不代替持证；paused 不等于已撤证 |
| R09 U/I | 按全新部署清单部署六个业务代理，尝试空初始化数据、错误 Hook 地址、错误 Registry/Router/LP 交叉绑定 | 空初始化数据被代理拒绝；Hook 低 14 位必须为 `0x3FFF`；所有双向绑定 getter 一致；错误绑定时发布流程停止且不启用资产 |

### 3.1.1 新版准入目标的增量用例（本地夹具已覆盖部分路径；真实发行方仍需留证）

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| A01 U/I | 用 Backed 行为 mock 的 wTSLAx Currency 和唯一生产 Adapter 接入 Hook；另用普通 ERC-20 或错误/错绑 Adapter 配置尝试登记；来源 multiplier 变化后交换两方向 | Hook 对每条股票 delta 调用来源 Token 转换方法并按当次返回值计股；错误配置拒绝或保持 `UNREVIEWED`；PoolManager raw 份额不自行变化，用户始终收付 wTSLAx |
| A02 U/I | 来源转换参数变化实际改变法律股数单位；同一 TSV 计量日 ADTV、可选配额及 used 仍为旧单位 | 未完成法律单位/计量日切换时暂停并拒绝；完成批准与统一单位报告后恢复；历史 used 不静默清零，既有仓位仍按原 Token 强退 |
| A03 I | 模拟发送方扣 `x + fee`、接收方正好收到 `x` 的 Token，分别走 Swap 和 LP 的 PoolManager 入金/出金及强退 | 每条路径均因发送方 raw 差额不等于 `x` 而全回滚；用户余额、PoolManager、仓位、Receipt、used 恢复为 `S_pre` |
| A04 U/I | 仅 UI getter 存在但未绑定经审核的直接换算 Adapter；Adapter 返回零、currency 不匹配或 ERC-165/版本不符；`balanceOf(PoolManager)` 会 Rebase | 不兼容股票 Token 不得批准或 Swap；正 raw 换算结果为零、来源方法 revert 时整笔回滚；准入不能仅凭函数名或单次余额读取 |
| A05 U/I | 在 wTSLAx 股票池直接买入/卖出，覆盖 exact-in/out 与价格边界部分成交；使用未登记或不同的 PoolKey 发起 Swap | 只收付已登记的池内 Currency wTSLAx，按每笔实际 V4 wTSLAx delta 记一次 Tesla 额度；池键不匹配或未知时回滚；当前交易路径不执行包装或赎回 |
| A06 I | LP 直接以 wTSLAx 开仓、加仓、领费、部分减仓、关闭和强退；wTSLAx 拒转或发送方额外扣费 | 每步只按实际 raw Currency delta 收付；退出向原 owner 交付 wTSLAx；失败方案 A 全回滚；LP 操作不增加 `usedWad` |
| A07 U/I | 发行方 multiplier 改变、来源换算方法失效或 Token 被停用；用户仍持有 wTSLAx | 交易时调用来源方法并按当次返回值计股；方法失效/Token 停用时新 Swap 拒绝，不沿用缓存比例；既有仓位强退按独立门禁处理，不自动改成 TSLAx |
| A08 I | 目标部署从无旧 TSLAx 结算仓位直接启用 wTSLAx 直结；尝试调用旧 TSLAx 结算入口 | 新部署只允许 wTSLAx 直结；旧包装/赎回入口不存在或回滚；不生成旧仓位兼容状态 |
| A09 U/I | `setSbtConfig` 指向无 `paused()` 或 `verify()` 的合约、零地址或无代码地址 | 配置原子回滚；已有 SBT 配置保持不变；未配置 Registry 的资格读取回滚 `SbtNotConfigured()` |

### 3.2 报告、自动日切与额度

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| D01 U/I | 由持有 `HALT_REPORTER_ROLE` 或 `VOLUME_ORACLE_ROLE` 的地址直接提交 Market、ADTV、Quota 报告；尝试用 relayer、签名参数或旧 TradeDay 入口提交 | 只有 `msg.sender` 当前持有对应角色时接受；DataInbox ABI 不含签名参数或 signer 字段；旧日历报告无可调用入口 |
| D02 U | 非角色调用、角色已撤、重复 reportId、序号回退、过 submitDeadline、sourceTimestamp 在未来、同月批次未排序/跨月 | 各自拒绝，reportId/sequence 不被占用；早先已接受状态不自动失效 |
| D03 U | INITIAL_OPEN/INITIAL_HALTED 一次；OPEN→HALT→RESUME；重复 OPEN、HALT 心跳、RESUME 心跳 | 仅合法状态变化上链；HALT 无年龄失效，状态长期不变无需重报 |
| D04 U/I | 初始 UTC 日切 04:00；普通日边界前后各一秒、周末、月末、闰日及年末；无预提交日历 | 每个 UTC 日期独立归属一个 `YYYYMMDD` 计量日，连续无空洞/重叠；边界后新日用量从零开始，历史用量不改；不要求下一窗口或心跳交易 |
| D05 U/I | 治理将日切从 04:00 排期为未来 07:00；另试从 04:00 直接改到 09:00、同时存在第二项待生效排期、已开始的过渡日、更改过去或当前日、取消待生效排期 | 只有符合未来边界、每次偏移差不超过 4 小时且过渡日尚未开始的排期/取消成功；过渡日可为 20–28 小时但只有一份完整硬上限；已开始和历史日边界永久不变；自动生效无需激活交易 |
| D06 U | 9 月 ADTV 适用 10 月计量日，进入 11 月但无 10 月 ADTV；同一月份 ADTV 值不变，同一日没有 quota 覆盖 | 10 月使用 9 月 ADTV；11 月缺适用 ADTV 则受影响证券 Swap fail-closed；无 quota 时仍按 ADTV/Tier 硬上限交易；同一有效期间不重复上报相同值 |
| D07 U/I | ADTV=1000e18、tierBps=25 得硬上限 2.5e18；无覆盖时交易，再为指定日 SET quota=2e18，随后下调到已用量以下并 CLEAR | `used` 对同证券跨池/跨 Token 汇总；每笔成功 Swap 不超过当时有效上限；SET/CLEAR 从成功提交后影响后续 Swap，不清零 used；下调到低于 used 后新 Swap 拒绝，CLEAR 后恢复硬上限但不重置历史用量 |
| D08 U/I | `SEC_A` 股票与 `SEC_B` 股票申请同一 PoolKey；另以同证券不同股票 Currency 申请同一 PoolKey | 两类均在 `registerPendingPool` 被拒，Registry 不残留 PENDING，V4 不初始化池；各证券额度保持不变 |
| D09 U | sourceMonth 格式错、SET 的 quota=0/大于提交时硬上限、CLEAR 无旧覆盖或 quota 非零、版本/序号回退、ADTV 更正后旧覆盖高于新 hard cap | 无效报告拒绝且不占 reportId；合法更正不改已用量，旧覆盖与新硬上限取更严值，不能继续超限成交；其他证券不受错误标的牵连 |

### 3.3 股数、Swap 与原子结算

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| S01 U/I | wTSLAx mock 来源方法初始 multiplier=`1e18`，输入 `2e18` raw shares；`QUOTE` 输出 | 该标的 `used` 增 `2e18`；quote 不产生 `SwapAccounted`；将来源 multiplier 改为 `2e18` 后，等量 raw 输入的 `used` 增量为 `4e18` |
| S02 U/I | `wTSLAx` 输入 `3e18` shares，来源 Token `getUnderlyingAmountByShares` 返回 `2.7e18` | 技术股数 `2.7e18`；Adapter 返回值、版本及事件值与独立计算一致，不生成 rateId/快照 |
| S03 U/I | 在股票／非股票池分别让股票作输入且存在 LP/协议费、股票作输出 | 输入按实际 V4 caller delta 的**含费总支出**计，输出按净收到计；每笔只记一条股票腿，不能按 `amountSpecified` 或用户预估数记账 |
| S04 I | exact input 完全成交；价格边界仅部分成交且仍达到 minOut；部分成交低于 minOut | 前两者只按实际 delta 直接收付 Currency 和计股；最后者全回滚 |
| S05 I | 股票输入和 quote 输入的 exact output 完全成交、超 maxIn、价格边界部分输出 | 仅完全输出且输入在上限内成功；股票输入按含费实际输入、quote 输入按净收到股票的法定股数增加 `used`；部分输出即使仍有非零量也回滚 |
| S06 U/I | 未持证调用、`msg.sender != participant`、participant/payer/recipient 不同、参数越界、deadline 过期；AA 钱包以自身地址直接调用 | 非 participant 调用拒绝；EOA 与 AA 钱包均须以 participant 身份直接调用；同一请求在后续独立调用中按新 Swap 校验，不做应用层 nonce 去重 |
| S07 I | 一笔 unlock 尝试第二次 swap、第二个 PoolId、额外 modify、Hook 直接调用、空活跃上下文或错 PoolId | 全部拒绝；一次成功 Swap 恰一次记账，结束清空单笔上下文 |
| S08 U/I | Backed 来源换算对正 raw 返回零、来源方法 revert、极大 raw 返回溢出/异常值 | Hook 调用失败或返回零时整笔回滚；正成交不以零股计入额度 |
| S09 I | `afterSwap` 调用 Adapter 时来源换算方法 revert 或返回零 | 整笔 Swap 回滚；没有旧快照、Ledger 复核或 Router 结算后的二次复验 |
| S10 I | 普通 ERC-20 fee-on-transfer、rebasing、无返回值/返回 false、静默少转；wTSLAx 发送方额外扣费 | 有效标准返回值且双方 raw 差额精确才可通过；金额不等即回滚，不留下池欠款 |
| S11 I | 用户持有 wTSLAx，但 issuer multiplier 在报价后变化；分别测试 raw 滑点通过/失败 | 成功交易以 `afterSwap` 实际 delta 调用来源换算方法并按当时返回值计股；raw 限额按请求执行；前端股数预估不作为链上边界 |
| S12 I | Router/LP Manager 非法回调、错 Swap 上下文/LP operationId/poolCurrency/owner/recipient、重入及故意遗留本次 wTSLAx 余额 | 全部拒绝或回滚；成功时上下文清空，Router/LP Manager 不留本笔资产 |

### 3.4 LP、Receipt、暂停和强退

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| L01 I | open→increase→decrease→collect→close；普通股票/quote 与 wTSLAx/quote 池均直接结算 | positionId/salt 唯一，Receipt owner 与账本 owner 一致；V4 实际 liquidity、callerDelta、最终 Currency 交付逐步吻合 |
| L02 I | 两个 owner、相同池/相同 tick 区间各建仓 | 不同 salt 的 V4 仓位不可混合；任一 owner 无法修改另一个仓位 |
| L03 U/I | Receipt `transferFrom/safeTransferFrom/approve/setApprovalForAll`，非 owner 操作，owner SBT 被撤或全局 paused | 全部拒绝用户 LP；Receipt 不能流转；强退资格单独判断 |
| L04 I | `collectFees` 在正流动性仓位有费/无费；最后一次 `closePosition` 有累计费 | 有费按返回 callerDelta 交付；无费回滚；close 单次负 liquidity 同时拿本金和费，不在零仓位追加领费 |
| L05 I | LP bounds 的两侧 raw Currency 付款上限、收款下限；报价后池价或 multiplier 变化 | 各侧按实际 callerDelta 校验 raw 边界，任一失败全回滚；前端股数展示不被误认为链上独立限价 |
| L06 I | `REVOKE_EXIT_EXECUTOR` 对确实无 SBT 的原 owner；SBT 只是 paused；`FORCE_EXIT_ADMIN` 有/无 reason/evidence | 仅规定的两类调用者满足各自条件时能强退；paused 但仍持证不能作为撤证理由 |
| L07 I | 停牌、EmergencyPause、Token/Pool DISABLED、报告缺失时强退，并提交两侧 raw `minPoolOut` | 业务门禁不阻挡既有仓位全额强退；两侧实际到账均满足调用时下限才成功，资产仍只发到**原 owner** |
| L08 I | 发行方 wTSLAx 拒绝向原 owner 转账，或另一侧普通 Token 拒转；分别安排失败发生在第一/第二腿 | 方案 A：V4 移除、资产转账、Receipt burn、TSV 仓位和事件均回滚到 `S_pre`；旧仓位可重试，无持久失败事件 |
| L09 I | 强退 wTSLAx 时底层 multiplier 或 TSLAx 账户显示余额改变，但 wTSLAx raw 应付量确定 | 原 owner 实收 wTSLAx raw 与 V4 应付量精确相等；不要求本交易执行发行方赎回，也不错误以 TSLAx 的 `balanceOfUI` 差额判断交付 |
| L10 I | 正常 LP 修改时零 liquidity、部分减仓清空、tick 未对齐、deadline 过期、余额不足、外部重入 | 全部拒绝且仓位/Receipt 保持一致 |
| L11 I | 强退设置任一侧高于实际到账的 `minPoolOut`，另一侧正常；再以可满足的两侧下限重试 | 前次整笔回滚且仓位、Receipt、两侧余额保持不变；重试按运营给定下限成功并向原 owner 交付 |
| L12 I | `closePosition` 或 `decreaseLiquidity` 在 tick 区间边界使一侧 delta 为零，同时该侧 `minPoolOut` 大于零 | `SlippageExceeded`，整笔回滚，仓位与 Receipt 保留；零输出也必须满足调用者设置的最低输出 |

### 3.5 治理与升级

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| G01 U/I | CREATE2 部署 Hook 代理、错误 salt、实现升级前后读 `tsvImplementation()`；真实 V4 下触发预留的 afterAdd/afterRemove 回调 | **代理**地址低 14 位为 `0x3FFF`；实现地址无需具备该位；V1 四种返回 delta 均为零、donate 仍回滚；升级不变 Hook 地址与池 PoolId |
| G02 I | Governor 普通 schedule 分别指定 0 和正延迟，早于 ready/到 ready 执行；updateDelay | 0 可下一笔执行，正延迟前拒绝；无自定义最小/最大；updateDelay 恒回滚 |
| G03 I | Guardian 取消 Waiting/Ready 普通操作；冻结事故入口；普通排期同时存在 | 普通操作取消，事故入口冻结；已有普通排期仍按自身 ready 规则可执行，冻结不暂停 Swap |
| G04 I | Governor 未冻结时事故升级；Timelock 分别将 Anchor 六代理成员、列表外 TSV 代理和伪造 nominated Anchor 声称的代理加入名单；重复 actionId，坏实现或坏 initData | 仅当前绑定 Anchor 六代理中的已允许目标可升级；列表外目标和未与旧 Timelock 互绑的伪造 nominated Anchor 均不能加入名单；所有失败回滚；成功记录旧新实现和证据 |
| G05 I | RecoveryCouncil 排期精确恢复、试图排普通升级/批次；Governor 排恢复；Guardian 取消受保护 ID | 只有 Council 的精确单项操作被保护；其余拒绝；受保护 ID 不可被 Guardian 取消，但未经当前 Guardian 对 operationId 批准不得执行，撤回批准后也不得执行 |
| G06 I | 恢复中任一 Controller/Authority/角色步骤失败，以及完整成功轮换 | 失败全部回滚；成功同笔切换根权限，旧 Governor 立即失去业务 admin/普通 proposer/事故升级权，旧 Guardian 失去冻结/取消权 |
| G07 I | Timelock 普通操作自调用 grantRole/revokeRole/renounceRole 修改受保护三角色，或直接调用恢复 setter | 全部拒绝；没有角色旁路 |
| G08 I | 每个 TSV 代理升级前后保存 PoolKey、额度、报告、暂停、position、Receipt；旧 `TokenConfig` 字段槽位不重排；升级后执行 wTSLAx 直结 Swap | 状态及权限位一致；新 Router/Hook 布局不含 Swap nonce 或 `operationId` 状态；旧 `version="1"` 授权失效、新 `version="2"` 授权有效；禁止不兼容 layout 的候选实现进入发布清单 |
| G09 I | D-35 GovernanceAnchor 提议同时切换 Timelock、BusinessAuthority、事故控制器；独立 Guardian 批准/撤回、坏互绑地址、未提名 Anchor、缺六代理允许名单、重复 epoch、旧根继续调用；候选代码哈希与升级布局由发布清单单独核验 | 仅完整的三地址组原子切换成功；失败不改变任何代理的治理根；成功后旧根失权，新根同时接管普通升级、事故升级和业务角色，原 PoolId、额度、仓位及强退能力不变 |

## 4. 三个外部协议的专项集成

| ID | 本地源码/实际实例 | 必须复核的具体行为 |
| --- | --- | --- |
| X-V4 | `lib/v4-core` 的 PoolManager/Hook 类型；固定 fork 官方 PoolManager | `initialize` Hook 两回调、`modifyLiquidity` 的 callerDelta 含本金与费用、零 liquidity 领费限制、`swap` 的 afterSwap delta 与手续费、`sync/settle/take` 清算和 `donate` 拒绝；直连绕过尝试失败 |
| X-SBT | `lib/soul-bound-token-1155` SmartWalletSbt 实际编译产物/代理 | `verify` 只反映持有余额，`paused()` 独立生效；撤证、停用、AA 钱包 ERC-1155 接收分别测试 |
| X-BACKED | `BackedAutoFeeLegalShareAdapter`、本地来源/Wrapped 行为 mock，再核对 fork 真实代理 | `getUnderlyingAmountByShares(rawShares)` 在转换调用时的返回值、底层 multiplier 变化、wTSLAx raw 稳定和双侧精确转账、发行方托管及 Wrapper 外部赎回限制；目标 TSV 新交易不调用 `transferSharesFrom/mint/redeem` |

X-BACKED 必须覆盖 multiplier=`1e18`、低于 `1e18`、会跨一个费率周期、正 raw 返回零显示量的边界；包含账户已有余额时的 floor 差额。对实际代理只读查 `getUnderlyingAmountByShares()`、`asset()`、`decimals()`、`getCurrentMultiplier()`、`sharesOf()`、代码哈希与可核验管理员/制裁列表；写路径只有测试地址和发行方允许的受控环境才能执行。真实代理未完成写路径验证，生产报告必须将其列为未通过门禁，不能用本地实例通过替代。

## 5. 性质测试与随机序列

| ID | 生成条件 | 每一步必须保持的不变量 |
| --- | --- | --- |
| P01 | 随机 open/increase/decrease/collect/close/forceExit、tick、owner | 每个活跃 position 的 `(PoolId,ticks,salt)` V4 liquidity 与 TSV ledger 相等；Receipt 恰好一个且 owner 不变；关闭后不可再领取 |
| P02 | 随机单池 exact-in/out、股票/quote 方向、滑点、fee、来源 multiplier、配额更正 | `usedWad[securityId][day]` 等于**所有成功 Swap** 逐笔按实际 delta 调用来源转换方法的返回值之和；每次成功成交均满足成交时两种上限，更正下调上限后禁止继续超额成交；LP 操作不计量 |
| P03 | 随机报告顺序、延迟、UTC 日切偏移排期/取消、过渡日、ADTV 和 quota SET/CLEAR | 任意时间只归属一个计量日，历史边界不变；无适用 ADTV 时不会成功 Swap，无 quota 时可按硬上限交易；已用额度不因报告或日切排期重置 |
| P04 | 随机权限、暂停叠加/解除、SBT revoke/paused、池停用 | 任一命中的业务门禁阻止新用户动作；清除单条暂停不清除其他条；强退仍按原 owner 交付 |
| P05 | 随机直接 Token 故障、报价边界和回调重入 | 失败路径完全等于 `S_pre`；成功路径 V4 所有 Currency delta 为零，Router/LP Manager 不积累本笔余额 |
| P06 | 随机 Governor/Guardian/Council/Executor 操作序列 | 事故升级只有未冻结且 Governor+允许目标可执行；普通升级只能 ready 后；受保护角色只经 Council 恢复；根身份唯一 |

Fuzz 输入需包含 `0/1/max`、`int128.max` 周围、`2**256-1` 附近但受范围约束的值、`1e18` 前后、tick 边界、UTC 日切 `startUTC-1/startUTC` 与 20/28 小时过渡日端点。`fuzz` 的无效输入应明确定义为预期 revert，不用无条件 `vm.assume` 大量跳过。股数换算以**独立 BigInt 参考函数**复算，不能用被测 Adapter 的输出当预期值。记录每次失败的 seed 和最小复现序列；性质测试不得用旧原型的 `testKnownGap` 充当通过证明。

## 6. 回归、执行顺序与通过标准

当前 V1 测试位于 `test/unit/v1/` 和 `test/integration/local/`；后续按 `test/integration/local/`、`test/integration/xlayer/`、`test/invariant/` 补齐外部协议、固定区块 fork 与性质测试。不得把已移除的旧原型 `testKnownGap_*` 问题复现计入 V1 通过数量。

当前可执行命令：

```sh
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary
FOUNDRY_PROFILE=unit forge build --skip test --sizes
```

`unit` 与 `local` profile 使用 Solidity `0.8.26` 编译 TSV V1，并分别选择对应测试目录。`test/helpers/v1/` 中的 SBT 与发行方行为 mock 不能代替固定源码的 SmartWalletSbt `^0.8.29`、Backed `0.8.9` 独立构建和集成；当前尚无固定区块 X Layer fork 套件。

执行顺序：先 U，再 I，再 P，最后固定区块 F 与 G。每次候选实现升级后重跑全部相关 U/I/P/F；涉及 Token/Adapter/Hook 的改动至少重跑 X-V4、X-BACKED 与 G08。CI 记录编译器、优化参数、依赖 commit、fork block、部署清单哈希、随机 seed、gas 报告和测试结果。不要使用实时最新区块生成会随市场状态漂移的必过断言。

V1 **代码验收**要求：上述所有适用 ID 已落地且通过；没有跳过/预期失败的关键路径；关键完整交易用真实 V4 PoolManager 测过；失败原子性快照与六项性质测试通过；Router 直接调用者约束、报告直接角色 ABI、事件和错误可复算；代理布局和 Hook 权限位通过升级回归。**生产启用**另外要求固定区块 fork/真实代理核验、wTSLAx 股数口径的发行方/法务书面批准、实际制裁/暂停/精确转账与强退可达性、最坏 gas 余量及独立安全审计。缺任一项时不宣称 wTSLAx 生产测试完成，也不把 `UNREVIEWED` 改为 `APPROVED`。
