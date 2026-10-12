# TSV V1 合约测试规格

版本：1.10，2026-10-04。交易、运营、治理流程和入口总览见[三系统总览](./SYSTEMS_OVERVIEW.md)。本文是[当前编码规格](./CODING_SPEC_V1.md)的验收清单；代币准入按[新版准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)执行。表内用例表示**应实现的目标测试**，当前已执行的本地结果见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。本地 Hook 集成测试使用实现 `uiMultiplier()` 的股票行为 mock，并接入 `ERC8056DirectLegalShareAdapter`；普通 `V1LocalERC20` 作为报价币、故障币和普通 ERC-20 兼容性夹具。ERC-8056 Adapter 另有独立单元测试。生产发行方资产仍须单独验证 multiplier 接口和法律计量。目标新操作只直接收付池内 Currency。

跨领域的剩余工作、依赖及完成条件见[测试缺口统一清单](./TEST_GAPS_V1.md)；不以规范表格或覆盖率百分比推定已验收。

**迁移状态：**SIP 窗口追加/更正与逐日 quota 必填用例已从当前测试移除；当前测试按 D-33/D-34/D-37 覆盖可选 quota、UTC 自动日切及未来日拆并股系数。旧 `TSLAx → wTSLAx` 包装结算路径不属于当前 ABI；旧 Static、ERC-8056 snapshot Adapter 及其专属测试已删除；当前 ERC-8056 direct 计股 Adapter 的独立单元用例保留。下表只规定当前目标结果，已执行的本地覆盖见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

## 1. 测试边界和证据

测试对象是 TSV 自有 Registry（含全局 SBT 凭证策略）、VolumeLedger、DataInbox、Hook、Router、LP Manager（含 Receipt ERC-721）、股数 Adapter 和治理合约；旧结算 Adapter 只允许出现在隔离的历史单元测试，不属于目标交易路径。外部行为必须分别参照仓库固定的三份源码：`lib/v4-core`、`lib/soul-bound-token-1155`、`lib/TestToken/backed-token-contract`。V4 `PoolManager` 不用自写模拟品代替关键集成用例；SmartWalletSbt 的 `verify/paused` 和发行方 wTSLAx 的 ERC-20 转账、托管及 `getCurrentMultiplier()` 须有源码实例用例，另用故障替身覆盖拒转、少转、重入和升级。

测试层级及完成条件：

| 层级 | 用途 | 必须交付的证据 |
| --- | --- | --- |
| U：单元与确定性向量 | 校验 ERC-8056 Adapter 换算、状态机、Router 授权、边界、权限 | Foundry 用例；每个表内 ID 有通过/失败记录 |
| I：本地协议集成 | 使用真实 V4 PoolManager、本地 SBT 和实现 `uiMultiplier()` 的股票行为 mock；测试完整原子路径 | 调用 trace、关键事件、交易前后状态快照 |
| F：固定区块 X Layer fork | 核对官方 PoolManager 和实际 TSLAx/wTSLAx 代理、代码哈希、ABI、只读状态及受控地址的交易路径 | 固定 block、chainId、合约地址/codehash、运行结果；不广播主网交易 |
| P：fuzz/invariant | 随机交易序列、整数边界、升级/暂停/日切交错 | seed、最小复现输入、`fail_on_revert` 策略与不变量结果 |
| G：gas/部署 | 最坏 `uiMultiplier()` 调用、单股票腿计量、双侧资产结算、强退、Hook 代理地址 | 给出所用编译器/优化参数、区块 gas limit、实际 gas 与余量 |

`F` 层固定区块和 RPC 由测试清单提供，不把实时链状态当成稳定断言。测试必须校验 `chainId == 196`、官方 PoolManager 的地址/codehash、TSLAx/wTSLAx 的代理地址、运行代码哈希与可核验的实现/ABI；任何一项不符即让该组测试**失败**，不得自动改为 mock 或跳过。实际代理不兼容 `uiMultiplier()` 时，记为准入阻断项并保持资产未准入。底层转账场景只使用测试控制的地址或本地发行方实例；不能控制的真实发行方状态只做只读核验并如实标注未覆盖路径。

V1 TSV 编译产物固定 Solidity `0.8.26`，SBT `^0.8.29`、Backed `0.8.9` 分别构建。跨版本集成测试通过薄接口调用各自产物；不得仅因一个集成 profile 能用 `0.8.29` 重编译 TSV，就把它当作生产 `0.8.26` 字节码的验证。测试清单保存三份外部源码 commit、OZ 版本、TSV 实现/代理 codehash 和 CREATE2 salt。

## 2. 公共 fixture 与状态快照

每个合约测试可按以下组合搭建，不让测试自行猜测资产语义：

| fixture | 固定值或要求 |
| --- | --- |
| `ERC8056DirectLegalShareAdapter` + `V1MockIssuerWrapped` / `V1SwapToken` | 当前 direct-adapter Hook 测试路径；mock 的 `uiMultiplier()` 读取 mock issuer multiplier，不能代替真实发行方准入 |
| `ERC8056TestToken`（`STDx`） | ERC-8056 raw/UI multiplier 行为夹具；用于 Adapter 独立单测，不代表真实证券权益或生产准入 |
| `V1LocalERC20`（`QUOTE`） | 普通报价币与转账故障夹具，`securityId == 0` |
| `QUOTE6` | 可选的 6 decimals 报价币，用于非 18 位金额边界 |
| `TSLAx/wTSLAx` | 生产目标场景；准入假设与限制见[准入标准 §6](./TOKEN_ADMISSION_STANDARD_V1.md#6-tesla-实例tslax-与-wtslax)；外部实例仍须单独验证 |
| `SEC_A/SEC_B` | 两个不同证券 ID，用于证券与非股票币建池及双股票币对拒绝用例 |
| `Day D` | 按测试输入选择日期和 UTC 起点；`tradeDayId`、ADTV 与 quota 规则见[编码规格 §7](./CODING_SPEC_V1.md#7-角色报告计量日和额度) |
| `Identity` | Governor、Guardian、RecoveryCouncil、各业务角色各自为单独地址；测试只改变地址和角色，不依赖多签内部签名门槛 |

每个预期回滚的完整路径在发送交易前保存 `S_pre`：用户/Router/LP Manager/PoolManager 的相关 ERC-20 余额、V4 PoolId 状态和仓位流动性、TSV position/Receipt owner、`usedWad`、报告 reportId/来源时间、暂停计数和治理状态。回滚后逐项断言等于 `S_pre`；仅断言 revert selector 不足以证明原子性。成功路径逐项检查金额、股数、事件、V4 delta 清零及 Router/LP Manager 本次暂存余额回到基线。

## 3. 必须实现的确定性测试

下表每一行的正反面场景均须有独立用例；`U/I/F` 是最低层级，关键路径在 `I` 中重复验证。对外 ABI 的 struct 编码、事件索引及错误 selector 按编码规格 §2、§7、§10、§12 校验。

### 3.1 登记、池和身份

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| R01 U/I | 按目标配置登记股票 W/U、普通 `QUOTE`/`QUOTE6`，查询 W/U/Q 配置；尝试错误 Factory、owner 或 Adapter | 新证券通过 admitPermissionedSecurity 原子准入，新增 W 和 Q 使用各自注册入口；W 以非零 underlying、Q 以 registered 表示准入，零位精度 Q 合法；市场默认 OPEN；无兼容 Adapter 的股票配置失败 |
| R02 U | Currency 为零、无代码、decimals 错、重复 W/Q、股票身份冒充 Q、股数 Adapter 报错或资产对不匹配 | 注册失败且不留下 W/U/Q 配置；不使用独立静态比例字段判断公式 |
| R03 U/I | TOKEN 暂停后恢复 W/Q；暂停中篡改绑定、精度、owner/wrapper/Hook 权限；有无暂停时替换股数 Adapter；持有供给和手续费时恢复 | 恢复复核当前配置，失败保留暂停；修正后可重试；不重做首次库存检查，不改写历史资产或仓位；Adapter 替换只校验角色、接口和 U 绑定，不要求暂停，历史 used 不迁移 |
| R04 U/I | Tier 名额上限边界、证券重复登记/下架/重上架、跨 W 同 securityId；重新上市时另有暂停 | listedCount 按证券去重；下架直接阻止全部池普通操作且保留历史池；重上架恢复未暂停池，独立暂停不被清除；同证券共享日额度 |
| R05 I | POOL_CREATOR 提交有序 PoolKey、静态 fee、tickSpacing、sqrtPriceX96；随后重复初始化 | 代理 Hook 权限位 0x3FFF；Registry.registerPool 与真实 PM.initialize 同笔完成，无池生命周期字段；初始价格与输入一致，重复拒绝 |
| R06 U/I | 非 POOL_CREATOR、错 Hook、两侧均为股票或报价币、倒序 Currency、动态费、fee=1_000_000、tickSpacing=0/32768、越界价格 | 拒绝且 Registry 不残留注册记录，V4 不创建池；修正价格后可成功重试 |
| R07 I | 第三方直接调用 PoolManager `swap/modifyLiquidity/initialize/donate`，或伪造 Hook `sender/hookData` | Hook 拒绝；无额度、仓位或费状态变化 |
| R08 I | SBT holder、无证 holder、SBT 全局 paused、SBT revoke；Registry 未配置 SBT；AA 合约钱包直接调用且有/无 SBT | 普通 Swap/LP 仅在 `verify=true && paused=false` 可执行；未配置时回滚 `SbtNotConfigured()`；直接调用能力不代替持证；paused 不等于已撤证 |
| R09 U/I | 按全新部署清单部署六个业务代理，尝试空初始化数据、错误 PoolManager/Registry/Ledger 地址、错误 Registry/Hook/Router/LP 交叉绑定 | 空初始化数据被代理拒绝；Hook 低 14 位必须为 `0x3FFF`；Router 初始化不绑定 Hook，Hook 的 Router/LP 交叉绑定及治理 Anchor 其余绑定必须一致；错误绑定时发布流程停止且不启用资产 |

### 3.1.1 新版准入目标的增量用例（本地夹具已覆盖部分路径；真实发行方仍需留证）

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| A01 U/I | 用暴露 `uiMultiplier()` 的 Currency 和 `ERC8056DirectLegalShareAdapter` 接入 Hook；另用普通 ERC-20 或错误/错绑 Adapter 配置尝试登记；multiplier 变化后交换两方向 | Hook 对每条股票 delta 按当次 multiplier 换算计股；不兼容的 wTSLAx 配置、错误配置或错绑 Adapter 回滚且资产保持未登记；PoolManager raw 份额不自行变化 |
| A02 U/I | 公告指定未来计量日拆股/并股，Token 提前或推迟更新；异常来源单位需人工暂停/跨日恢复 | 额度按 D-37 的独立系数在日开始自动切换；实际成交仍实时 Adapter 换算；不修改旧 quota/ADTV/历史 used。单位异常暂停流程另验证；不声称合约自动识别或阻止发行方日内变更。 |
| A03 I | 模拟发送方扣 `x + fee`、接收方正好收到 `x` 的 Token，分别走 Swap 和 LP 的 PoolManager 入金/出金及强退 | 每条路径均因发送方 raw 差额不等于 `x` 而全回滚；用户余额、PoolManager、仓位、Receipt、used 恢复为 `S_pre` |
| A04 U/I | 仅 UI getter 存在但未绑定经审核的直接换算 Adapter；Adapter 返回零、currency 不匹配或 ERC-165 不符；`balanceOf(PoolManager)` 会 Rebase | 不兼容股票 Token 不得批准或 Swap；正 raw 换算结果为零、来源方法 revert 时整笔回滚；准入不能仅凭函数名或单次余额读取 |
| A05 U/I | 在 wTSLAx 股票池直接买入/卖出，覆盖 exact-in/out 与价格边界部分成交；使用未登记或不同的 PoolKey 发起 Swap | 只收付已登记的池内 Currency wTSLAx，按每笔实际 V4 wTSLAx delta 记一次 Tesla 额度；池键不匹配或未知时回滚；当前交易路径不执行包装或赎回 |
| A06 I | LP 直接以 wTSLAx 开仓、加仓、领费、部分减仓、关闭和强退；wTSLAx 拒转或发送方额外扣费 | 每步只按实际 raw Currency delta 收付；退出向原 owner 交付 wTSLAx；失败方案 A 全回滚；LP 操作不增加 `usedWad` |
| A07 U/I | 股票 Currency 的 multiplier 改变、`uiMultiplier()` 读取失败或 Token 被停用 | 交易时按 Adapter 读取的当次 multiplier 计股；读取失败/Token 停用时新 Swap 拒绝，不沿用缓存比例；既有仓位强退按独立门禁处理 |
| A08 I | 目标部署从无旧 TSLAx 结算仓位直接启用 wTSLAx 直结；尝试调用旧 TSLAx 结算入口 | 新部署只允许 wTSLAx 直结；旧包装/赎回入口不存在或回滚；不生成旧仓位兼容状态 |
| A09 U/I | `bindComponents` 的 SBT 指向无 `paused()` 或 `verify()` 的合约、零地址或无代码地址；`setSbtConfig` 的实际 ID 读取失败 | 绑定失败时全部组件保持未绑定；身份配置失败时权限与 ID 列表保持不变；组件未绑定的 Registry 资格读取回滚 `SbtNotConfigured()` |

SBT 增补验收：按 tokenId 独立配置 swap-only、LP-only、双权限及零权限；更新立即作用于持有者且不重复登记；多身份取权限并集。分别验证 Registry 的统一 `isAllowed(permission,account)` 与发行方 W 权限独立，Router/LP 的两层门禁均须通过；拒绝 NONE、组合权限和未知操作。验证所有已登记身份均撤销后才允许撤销强退。暂停、读取异常、关闭权限和部分撤证均不能替代身份全部撤销。

### 3.2 报告、自动日切与额度

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| D01 U/I | 由持有 `HALT_REPORTER_ROLE` 或 `VOLUME_ORACLE_ROLE` 的地址直接提交 Market、ADTV、Quota、SplitFactor 报告；尝试用 relayer、签名参数或旧 TradeDay 入口提交 | 只有 `msg.sender` 当前持有对应角色时接受；DataInbox ABI 不含签名参数或 signer 字段；旧日历报告无可调用入口 |
| D02 U | 非角色调用、角色已撤、重复 reportId、sourceTimestamp 回退/未来、过 submitDeadline、同月批次未排序/跨月 | 各自拒绝，失败不占用 reportId 或更新来源时间；早先已接受状态不自动失效 |
| D03 U | 准入后默认开放；首份 HALT 的三种模式；HALT 叠加与 RESUME 部分恢复；NONE、越界 action 和无模式变化报告 | 无需首次开市报告；按模式独立阻断/恢复，任一暂停时 HALTED、全部恢复时 OPEN；无变化请求整体回滚去重状态；HALT 无年龄失效 |
| D04 U/I | 初始 UTC 日切 04:00；普通日边界前后各一秒、周末、月末、闰日及年末；无预提交日历 | 每个 UTC 日期独立归属一个 `YYYYMMDD` 计量日，连续无空洞/重叠；边界后新日用量从零开始，历史用量不改；不要求下一窗口或心跳交易 |
| D05 U/I | 治理将日切从 04:00 排期为未来 07:00；另试从 04:00 直接改到 09:00、同时存在第二项待生效排期、已开始的过渡日、更改过去或当前日、取消待生效排期 | 只有符合未来边界、每次偏移差不超过 4 小时且过渡日尚未开始的排期/取消成功；过渡日可为 20–28 小时但只有一份完整硬上限；已开始和历史日边界永久不变；自动生效无需激活交易 |
| D06 U | 9 月 ADTV 适用 10 月计量日，进入 11 月但无 10 月 ADTV；同一月份 ADTV 值不变，同一日没有 quota 覆盖 | 10 月使用 9 月 ADTV；11 月缺适用 ADTV 则受影响证券 Swap fail-closed；无 quota 时仍按 ADTV/Tier 硬上限交易；同一有效期间不重复上报相同值 |
| D07 U/I | 默认系数1时 ADTV=1000e18、tierBps=25 得硬上限 2.5e18；无覆盖时交易，再为指定日 SET quota=2e18，随后下调到已用量以下并 CLEAR | `used` 对同证券跨池/跨 Token 汇总；每笔成功 Swap 不超过当时有效上限；SET/CLEAR 从成功提交后影响后续 Swap，不清零 used；下调到低于 used 后新 Swap 拒绝，CLEAR 后恢复硬上限但不重置历史用量 |
| D08 U/I | 不同证券的 W/W 或同证券不同 W 申请同一 PoolKey | 均在 registerPool 拒绝，不残留 Registry 记录，V4 不初始化池，各证券额度不变 |
| D09 U | sourceMonth 格式错、SET 的 quota=0/大于提交时硬上限、CLEAR 无旧覆盖或 quota 非零、来源时间回退、ADTV 更正后旧覆盖高于新 hard cap | 无效报告拒绝且不占 reportId；合法更正不改已用量，旧覆盖与新硬上限取更严值，不能继续超限成交；其他证券不受错误标的牵连 |


### 3.2.1 拆并股系数

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| D10 U/I | 默认系数、拆/并股、日开始前一秒/准确边界、未来日查询、20/28h 过渡日及 Token 早/晚更新 | 无报告默认1/1；只在目标计量日开始切换，无激活交易；不允许当天/过去/非法日、源月错配；旧用量和 LP 保留，真实 Swap 使用调整上限 |
| D11 U/I | 同月连续绝对系数、更正/取消最新待生效项、修改更早项、已生效后操作、跨月/跨证券 | 2→6 不再相乘；latest-only 且必须尚未开始；取消恢复前一项、版本仍递增，ID 不释放；新来源月默认1，证券隔离；ADTV 数据更正保留同月基准 |
| D12 U/I | 系数角色/撤权/固定 writer、报告 metadata/replay、零比例、约分、单次最终 floor、最大分数、ADTV/Tier 更正及绝对 quota | 同一 VOLUME_ORACLE_ROLE，reportId 全局唯一、来源时间按类别/证券校验；拒绝完全回滚可纠正重试；精确正分数，超 full-Tier 可表示范围拒绝；quota 不自动乘因子，始终 min；边界 fuzz 用独立整数参考 |
| D13 I/P | 现有资金/ADT/quota/角色/ID 加待生效系数升级 Ledger/Inbox、升级冻结、模型交错 | 升级追加字段且现有状态/排期保留；Guardian 冻结不阻止自动生效或业务报告；独立线性因子模型与实际二分查询比较，版本/历史/失败 ID 保留 |

### 3.3 股数、Swap 与原子结算

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| S01 U/I | wTSLAx mock 来源方法初始 multiplier=`1e18`，输入 `2e18` raw shares；`QUOTE` 输出 | 该标的 `used` 增 `2e18`；quote 不产生 `SwapAccounted`；将来源 multiplier 改为 `2e18` 后，等量 raw 输入的 `used` 增量为 `4e18` |
| S02 U/I | 股票 Currency 输入 `3e18` raw，`uiMultiplier()` 返回 `0.9e18` | 技术股数 `2.7e18`；Adapter 返回值及事件值与独立计算一致，不生成 rateId/快照 |
| S03 U/I | 在股票／非股票池分别让股票作输入且存在 LP/协议费、股票作输出 | 输入按实际 V4 caller delta 的**含费总支出**计，输出按净收到计；每笔只记一条股票腿，不能按 `amountSpecified` 或用户预估数记账 |
| S04 I | exact input 完全成交；价格边界仅部分成交且仍达到 minOut；部分成交低于 minOut | 前两者只按实际 delta 直接收付 Currency 和计股；最后者全回滚 |
| S05 I | 直接结算 Adapter exact-in 的股票输入和 quote 输入完整成交、价格边界导致输入未完全消耗 | 仅完整消耗指定输入时成功；股票输入按含费实际输入、quote 输入按净收到股票的法定股数增加 `used`；部分成交整笔回滚；Router 无成交事件或 int128 事件转换 |
| S06 U/I | 未持证 Adapter、非白名单 Adapter、参数越界、deadline 过期；EOA/AA 尝试直接调用 Router | 未持证及非白名单 Adapter 拒绝；用户直调 Swap selector 不存在；同一请求在后续独立调用中按新 Swap 校验，不做应用层 nonce 去重 |
| S07 I | 非 PoolManager 直接调用 Router.unlockCallback；非 Router 直接通过 PoolManager.swap；Router 收到不可交易池；Hook 收到不匹配的 PoolKey；Swap 回调期间重入 Router；直接调用 Hook 或尝试非 Swap 的 modify/donate | 全部拒绝；一次成功 Router Swap 恰一次记账；Swap 不依赖或清理活跃上下文 |
| S08 U/I | `uiMultiplier()` 对正 raw 返回零、调用 revert，或极大 raw 返回溢出/异常值 | Hook 调用失败或返回零时整笔回滚；正成交不以零股计入额度 |
| S09 I | `afterSwap` 调用 Adapter 时来源换算方法 revert 或返回零 | 整笔 Swap 回滚；没有旧快照、Ledger 复核或 Router 结算后的二次复验 |
| S10 I | 普通 ERC-20 fee-on-transfer、rebasing、无返回值/返回 false、静默少转；wTSLAx 发送方额外扣费 | 有效标准返回值且双方 raw 差额精确才可通过；金额不等即回滚，不留下池欠款 |
| S11 I | 用户持有股票 Currency，但 multiplier 在报价后变化；分别测试 raw 滑点通过/失败 | 成功交易以 `afterSwap` 实际 delta 和当时的 `uiMultiplier()` 计股；raw 限额按请求执行；前端股数预估不作为链上边界 |
| S12 I | Router/LP Manager 非法回调、错 LP callback context/request hash/poolCurrency/owner/recipient、重入及故意遗留本次 wTSLAx 余额 | 全部拒绝或回滚；成功时 LP 活跃上下文与请求哈希清空；Router/LP Manager 不留本笔资产 |

### 3.4 LP、Receipt、暂停和强退

暂停模式为 TRADE=1、LP=2、ALL=3；NONE=0 不能用于暂停/恢复请求。普通 LP 包括开仓、加仓、减仓、收费、关闭。

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| L01 I | open→increase→decrease→collect→close；普通股票/quote 与 wTSLAx/quote 池均直接结算 | positionId/salt 唯一，Receipt owner 与账本 owner 一致；V4 实际 liquidity、callerDelta、最终 Currency 交付逐步吻合 |
| L02 I | 两个 owner、相同池/相同 tick 区间各建仓 | 不同 salt 的 V4 仓位不可混合；任一 owner 无法修改另一个仓位 |
| L03 U/I | Receipt `transferFrom/safeTransferFrom/approve/setApprovalForAll`，非 owner 操作，owner SBT 被撤或全局 paused | 全部拒绝用户 LP；Receipt 不能流转；强退资格单独判断 |
| L04 I | `collectFees` 在正流动性仓位有费/无费；最后一次 `closePosition` 有累计费 | 有费按返回 callerDelta 交付；无费回滚；close 单次负 liquidity 同时拿本金和费，不在零仓位追加领费 |
| L05 I | LP bounds 的两侧 raw Currency 付款上限、收款下限；报价后池价或 multiplier 变化；输入 delta 恰为 `int128.min`；COLLECT 返回负 delta | 各侧按实际 callerDelta 校验 raw 边界，任一失败全回滚；`int128.min` 在 token 转账前拒绝，COLLECT 的负 delta 拒绝；前端股数展示不被误认为链上独立限价 |
| L06 I | `REVOKE_EXIT_EXECUTOR` 对确实无 SBT 的原 owner；SBT 只是 paused；`FORCE_EXIT_ADMIN` 有/无 reason/evidence | 仅规定的两类调用者满足各自条件时能强退；paused 但仍持证不能作为撤证理由 |
| L07 I | 停牌和 EmergencyPause 三种模式、TOKEN/POOL 暂停、证券下架、报告缺失时强退，并提交两侧 raw minPoolOut | 业务门禁不阻挡既有仓位全额强退；两侧实际到账满足下限才成功，资产按原仓位规则交付 |
| L08 I | 发行方 wTSLAx 拒绝向原 owner 转账，或另一侧普通 Token 拒转；分别安排失败发生在第一/第二腿 | 方案 A：V4 移除、资产转账、Receipt burn、TSV 仓位和事件均回滚到 `S_pre`；旧仓位可重试，无持久失败事件 |
| L09 I | 强退 wTSLAx 时底层 multiplier 或 TSLAx 账户显示余额改变，但 wTSLAx raw 应付量确定 | 原 owner 实收 wTSLAx raw 与 V4 应付量精确相等；不要求本交易执行发行方赎回，也不错误以 TSLAx 的 `balanceOfUI` 差额判断交付 |
| L10 I | 正常 LP 修改时零 liquidity、部分减仓清空、tick 未对齐、deadline 过期、余额不足、外部重入 | 全部拒绝且仓位/Receipt 保持一致 |
| L11 I | 强退设置任一侧高于实际到账的 `minPoolOut`，另一侧正常；再以可满足的两侧下限重试 | 前次整笔回滚且仓位、Receipt、两侧余额保持不变；重试按运营给定下限成功并向原 owner 交付 |
| L12 I | `closePosition` 或 `decreaseLiquidity` 在 tick 区间边界使一侧 delta 为零，同时该侧 `minPoolOut` 大于零 | `SlippageExceeded`，整笔回滚，仓位与 Receipt 保留；零输出也必须满足调用者设置的最低输出 |
| L13 U/I | 四种紧急 scope × 三种 mode；同模式多记录、ALL 与单项叠加、清除顺序与未命中目标 | TRADE 只阻断 Swap、LP 只阻断全部普通 LP、ALL 同时阻断；精确模式计数逐条更新；恢复不误解除其他记录或市场暂停 |
| L14 I | 市场/紧急 TRADE 暂停下完整 LP 生命周期；LP 暂停下 direct exact-in/out 与 Adapter 双向 Swap；Hook 与 Ledger 独立门禁 | 另一类操作成功，实际 V4 流动性、资产结算和计量符合预期；收费前先产生手续费，避免 NoFees 掩盖暂停行为 |
| L15 U/I | 单项暂停下轮换 W owner；不同暂停状态下替换 U 股数 Adapter；暂停期间建池 | owner 轮换须该 W 的两类操作暂停；Adapter 替换不要求暂停，但仍须角色、接口和 U 绑定有效；建池仍只看准入 |

### 3.5 治理与升级

| ID / 层级 | 输入和动作 | 期望结果 |
| --- | --- | --- |
| G01 U/I | CREATE2 部署 Hook 代理、错误 salt、实现升级前后读 `tsvImplementation()`；真实 V4 下触发预留的 afterAdd/afterRemove 回调 | **代理**地址低 14 位为 `0x3FFF`；实现地址无需具备该位；V1 四种返回 delta 均为零、donate 仍回滚；升级不变 Hook 地址与池 PoolId |
| G02 U/I | Governor 单次 upgradeToAndCall 携带初始化；初始化写入后回滚；坏实现；批量升级第二项初始化失败 | 实现与初始化同笔成功，无排期/等待；失败回滚实现槽与全部存储；批量失败连同前项升级全部回滚 |
| G03 U/I | Guardian 冻结后对六代理逐个/批量升级；绑定前升级；Swap/LP/退出 | 所有升级以 UpgradeFrozen 回滚；冻结不暂停 Swap、LP 或退出 |
| G04 U/I | 非 Guardian 冻结/解冻；未冻结时解冻；重复冻结；旧 freezeId；正常 Guardian 解冻 | 只有当前 Guardian 能切换；拒绝无冻结/重复冻结/过期 ID；解冻恢复直接及批量升级 |
| G05 U/I | Council proposeRecovery、Governor/Guardian 越权提案；当前 Guardian 批准/撤回；Guardian 取消 | 仅 Council 提案/取消；未经当前 Guardian 批准或已撤回不得执行；无延迟、无任意调用权限 |
| G06 U/I | 取消已批准恢复；完整轮换；旧 epoch 批准继续使用 | 失败全部回滚；成功同笔更新 Anchor 内身份并保留升级冻结，旧 Governor 立即失去业务 admin 和升级权，旧 Guardian 失去冻结/批准权；旧提案失效 |
| G07 U/I | 业务角色、Guardian、Council 直接升级；绕过 Guardian 批准恢复；Anchor 在上下文外升级；批量错长度/重复/未绑定目标 | 全部拒绝；只有当前 Governor 或有效批量上下文中的 Anchor 在全局未冻结时可升级 |
| G08 I | 每个 TSV 代理升级前后保存 PoolKey、额度、报告、暂停、position、Receipt；旧 `TokenConfig` 字段槽位不重排；升级后执行 wTSLAx 直结 Swap | 状态及权限位一致；新 Router/Hook 布局不含 Swap nonce 或 `operationId` 状态；旧 `version="1"` 授权失效、新 `version="2"` 授权有效；禁止不兼容 layout 的候选实现进入发布清单 |
| G09 U/I | 单个固定 Anchor 保存身份；一次 Governor 恢复后六代理继续操作；非法 Anchor 身份初始化；冻结中恢复 | 六代理动态读取同一 Anchor，新 Governor 接管默认管理员、旧身份立即失权；身份不独立或为空则代理初始化拒绝；全局冻结、代理地址、业务状态及运营角色保留 |
| G10 U | 默认管理员 grant/revoke/renounce 和内部角色路径；业务角色撤销/放弃；恢复后授予/撤销/配置 | 默认管理员始终只能由 Anchor 当前 Governor 动态决定；业务角色按权限正常管理；旧 Governor 失去管理权，新 Governor 接管 |
| G11 U | 三身份零地址/重叠；绑定错 Anchor/缺代码/重复/顺序/逐项交叉链接；重复绑定与失败重试 | 非法部署/绑定拒绝；失败不留下部分代理地址；修正后可重试，成功绑定后不可重绑 |
| G12 U | 重复提案、未知 ID、取消后重提、仅 Governor 轮换后的旧审批、候选/旧 Guardian 越权 | 重提必须重新批准；任何身份轮换使旧 epoch 提案失效；只有当前 Guardian 批准/撤回；获批执行可由任意账户触发但不可重放 |
| G13 U/I | 空/超长/错长度批次；坏实现/UUID；任意位置迁移失败；合约 Governor 回调嵌套批次；初始化中冻结 | 拒绝非法输入；整批实现/迁移/外部写入回滚；批量上下文不泄漏；嵌套批量拒绝；冻结阻止后续升级，外层失败则全部事务回滚 |
| G14 U | 绑定、批量、冻结/解冻、提案/批准/撤回/取消、身份恢复事件 | 校验事件发出地址、indexed 身份/ID、数量和 Guardian epoch |
| G15 U | 部署输入校验与部署清单 verifier；错链/无代码依赖/SBT ABI/治理身份/绑定状态/实现地址 | 有效环境和清单通过；每项不符拒绝；身份恢复后旧清单失效，更新后通过；实际广播与生产多签另行验收 |

准入回归还须覆盖：准入失败后证券、Tier 名额和 Token 配置全部回滚；重复证券/Currency、Tier 超额、无代码、decimals/Adapter 不匹配均拒绝；未登记资产不能建池；重新上市保留市场暂停状态。真实 V4 用例验证缺 ADTV 时可提供 LP，但 Swap 的余额、价格、费用与用量全部回滚，提交有效 ADTV 后可成交；初始化失败不留下注册记录；历史池不因下架或暂停被删除。

## 4. 三个外部协议的专项集成

| ID | 本地源码/实际实例 | 必须复核的具体行为 |
| --- | --- | --- |
| X-V4 | `lib/v4-core` 的 PoolManager/Hook 类型；固定 fork 官方 PoolManager | `initialize` Hook 两回调、`modifyLiquidity` 的 callerDelta 含本金与费用、零 liquidity 领费限制、`swap` 的 afterSwap delta 与手续费、`sync/settle/take` 清算和 `donate` 拒绝；直连绕过尝试失败 |
| X-SBT | `lib/soul-bound-token-1155` SmartWalletSbt 实际编译产物/代理 | `verify` 只反映持有余额，`paused()` 独立生效；撤证、停用、AA 钱包 ERC-1155 接收分别测试 |
| X-BACKED | 本地来源/Wrapped 行为 mock及 fork 真实代理（只读） | 核对 `getUnderlyingAmountByShares(rawShares)`、底层 multiplier、wTSLAx raw 稳定和双侧精确转账、发行方托管及 Wrapper 外部赎回限制；当前 Adapter 不调用该发行方转换方法，wTSLAx 路径须先完成兼容 Adapter 与准入审查；TSV 新交易不调用 `transferSharesFrom/mint/redeem` |

X-BACKED 必须覆盖 multiplier=`1e18`、低于 `1e18`、会跨一个费率周期、正 raw 返回零显示量的边界；包含账户已有余额时的 floor 差额。对实际代理只读查 `getUnderlyingAmountByShares()`、`asset()`、`decimals()`、`getCurrentMultiplier()`、`sharesOf()`、代码哈希与可核验管理员/制裁列表；写路径只有测试地址和发行方允许的受控环境才能执行。真实代理未完成写路径验证，生产报告必须将其列为未通过门禁，不能用本地实例通过替代。

## 5. 性质测试与随机序列

| ID | 生成条件 | 每一步必须保持的不变量 |
| --- | --- | --- |
| P01 | 随机 open/increase/decrease/collect/close/forceExit、tick、owner | 每个活跃 position 的 `(PoolId,ticks,salt)` V4 liquidity 与 TSV ledger 相等；Receipt 恰好一个且 owner 不变；关闭后不可再领取 |
| P02 | 随机单池 exact-in/out、股票/quote 方向、滑点、fee、来源 multiplier、配额更正 | `usedWad[securityId][day]` 等于**所有成功 Swap** 逐笔按实际 delta 调用来源转换方法的返回值之和；每次成功成交均满足成交时两种上限，更正下调上限后禁止继续超额成交；LP 操作不计量 |
| P03 | 随机报告提交、来源时间、UTC 日切偏移排期/取消、过渡日、ADTV、quota SET/CLEAR、未来日系数排期/更正/取消 | 任意时间只归属一个计量日，历史边界不变；无适用 ADTV 时不会成功 Swap，无 quota 时可按硬上限交易；已用额度不因报告或日切排期重置；按来源月与目标日选择绝对因子，reportId/时间与独立模型一致 |
| P04 | 随机权限、scope/target/mode 暂停叠加与逐条解除、市场部分恢复、SBT revoke/paused、池停用 | 交易仅受 TRADE/ALL、普通 LP 仅受 LP/ALL 阻断；紧急与市场暂停独立叠加；清除单条记录不清除其他条；强退仍按原 owner 交付 |
| P05 | 随机直接 Token 故障、报价边界和回调重入 | 失败路径完全等于 `S_pre`；成功路径 V4 所有 Currency delta 为零，Router/LP Manager 不积累本笔余额 |
| P06 | 随机 Governor/Guardian/Council 操作序列 | 直接/批量升级仅全局未冻结且当前 Governor 发起可执行；冻结/解冻仅当前 Guardian；身份恢复保持冻结；恢复要求 Council 提案和当前 Guardian 批准；批量升级初始化中不得执行身份恢复；根身份唯一 |

Fuzz 输入需包含 `0/1/max`、`int128.max` 周围、`2**256-1` 附近但受范围约束的值、`1e18` 前后、tick 边界、UTC 日切 `startUTC-1/startUTC` 与 20/28 小时过渡日端点。`fuzz` 的无效输入应明确定义为预期 revert，不用无条件 `vm.assume` 大量跳过。股数换算以**独立 BigInt 参考函数**复算，不能用被测 Adapter 的输出当预期值。记录每次失败的 seed 和最小复现序列；性质测试不得用旧原型的 `testKnownGap` 充当通过证明。

## 6. 回归、执行顺序与通过标准

当前 V1 测试位于 `test/unit/v1/` 和 `test/integration/local/`，按治理、交易、流动性、准入、报告、运营和部署分组；目录规则、公共 fixture 和定向命令见[测试维护说明](../test/README.md)。治理随机序列已落地在 `unit/v1/governance/StatefulGovernance.t.sol`；`test/integration/xlayer/` 已有固定区块真实 DEX 流程，真实生产资产/TSV 与治理账户验收仍待 `test/integration/governance/` 和发布清单闭合。交易与 LP 混合随机序列已在 `local/trading/StatefulTradingLP.t.sol` 落地，覆盖 P01/P02/P04/P05 的本地核心模型及七个连续日；P03 已在 `unit/v1/reports/StatefulOperations.t.sol` 建立单证券季度日历/报告模型，并由专门 unit 和真实 V4 `local/operations/` 用例验证边界、跨月和更正；具体模型范围与尚缺生产/链下证据见[运营测试 review](./OPERATIONS_TEST_REVIEW_V1.md)。不得把已移除的旧原型 `testKnownGap_*` 问题复现计入 V1 通过数量。

公共 fixture 不包含测试方法；测试套件不得继承其他可执行套件，Position ID 只继承无用例的协议 fixture。新版本迁移替身覆盖六代理同批升级、已有资金/配置/报告/暂停/仓位保留及失败回滚，不能替代每个生产候选实现的布局验证。

当前可执行命令：

```sh
python3 script/check-test-layout.py
forge test --summary
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary
FOUNDRY_PROFILE=unit forge build --skip test --sizes
```

`unit` 与 `local` profile 使用 Solidity `0.8.26` 编译 TSV V1，并分别选择对应测试目录。`test/helpers/v1/` 中的 SBT 与发行方行为 mock 不能代替固定源码的 SmartWalletSbt `^0.8.29`、Backed `0.8.9` 独立构建和集成；固定区块 X Layer DEX fork 套件已存在，真实生产资产/SBT/官方 PoolManager 与目标 TSV 配置的验收仍待完成。

执行顺序：先 U，再 I，再 P，最后固定区块 F 与 G。每次候选实现升级后重跑全部相关 U/I/P/F；涉及 Token/Adapter/Hook 的改动至少重跑 X-V4、X-BACKED 与 G08。CI 记录编译器、优化参数、依赖 commit、fork block、部署清单哈希、随机 seed、gas 报告和测试结果。不要使用实时最新区块生成会随市场状态漂移的必过断言。

V1 **代码验收**要求：上述所有适用 ID 已落地且通过；没有跳过/预期失败的关键路径；关键完整交易用真实 V4 PoolManager 测过；失败原子性快照与六项性质测试通过；Router 直接调用者约束、报告直接角色 ABI、事件和错误可复算；代理布局和 Hook 权限位通过升级回归。**生产启用**另外要求固定区块 fork/真实代理核验、wTSLAx 股数口径的发行方/法务书面批准、实际制裁/暂停/精确转账与强退可达性、最坏 gas 余量及独立安全审计。缺任一项时不宣称 wTSLAx 生产测试完成，也不得调用准入入口登记资产。

当前场景与实现文件、固定区块 DEX 边界及最新执行记录见[覆盖矩阵](./TEST_COVERAGE_V1.md)。
