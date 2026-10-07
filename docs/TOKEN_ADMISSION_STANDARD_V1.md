# TSV V1 代币准入标准

> **2026-10-07 Wrapped Swap 更新：** Registry 与单池 Wrapped Swap 已实现，用户收付 U/Q，池内结算 W/Q。当前 ABI、库链接与验收边界见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)，当前运营步骤见 [W/U/Q 开通流程](./OPENING_A_STOCK_MARKET_V1.md)。下文旧 DIRECT、TokenConfig/getToken、DEX 与 LP 成功路径属于历史版本；生产 Wrapped LP 及真实资产/目标链验收仍待交付，历史测试数量不代表当前覆盖。

状态：**Backed AutoFee 直算路径已接入本地 Hook 集成测试；真实发行方 wTSLAx 生产证据仍待完成**，2026-10-02。系统流程与交易/运营/治理边界见[三系统总览](./SYSTEMS_OVERVIEW.md)。V1 每个池内 Currency **只允许直接 ERC-20 结算**：Swap 和 LP 用户支付、接收的 Token 与 `PoolKey` 中该侧 Currency 是同一个地址。TSLAx 是 xStock 系列中的一个实例；其发行方 Wrapped `wTSLAx` 可按本标准审查为池内股票 Currency，TSLAx 原币不进入 TSV 的 Swap/LP 入口。代码目前只提供 `BackedAutoFeeLegalShareAdapter`；它和本地 Backed 行为 mock 不等同于已获准的真实发行方资产。当前没有通用固定比例或 ERC-8056 股数 Adapter。具体生产差异见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

## 1. 两项独立准入判断

1. **V4 能否正确结算和持有：**池内 Currency 的 raw `balanceOf()` 不因费率、拆股、展示系数等外部状态自行变化；每次 ERC-20 转账发送方恰扣 `x`、接收方恰增 `x`；Swap 双方向及 LP 开/加/减仓、领费、关闭、强退均可按同一 Currency 交付。
2. **监管股数能否正确计算：**股票 Currency 的每笔实际 V4 Swap delta 能在交易时按发行方与法务批准的公式换成统一的 `legalSharesWad`，并与同单位 ADTV、日硬上限及可选日配额比较。Token 名称、`balanceOfUI()` 或 ERC-4626 `convertToAssets()` 本身不证明法定股数。

结算和计股分别审查。同一 Token 可以 raw 余额稳定、但每 raw 单位代表的股票权益随链上系数变化；这类 Token 可直接入池，但只有存在经审核并兼容的直接换算 Adapter 时才能作为股票 Currency。`1e18 legalSharesWad = 1 股`。每个池最多一侧为股票 Currency；同证券不同池的成功 Swap 汇入同一 `securityId` 日账本。

| 资产场景 | 池内 Currency（用户直接收付） | 计股来源 | V1 目标结论 |
| --- | --- | --- | --- |
| 普通非股票 ERC-20 | 该 ERC-20 地址 | 无 | 经 raw 稳定与精确转账审查后作为配对币 |
| 固定比例股票 ERC-20 | 该 ERC-20 地址 | 当前无通用实现；须另行审核并部署实现 `IDirectLegalShareAdapter` 的 Adapter | 还需发行方/法务批准逐笔股数公式 |
| raw 稳定的 UI Multiplier 股票 | 该 ERC-20 地址 | 当前无 ERC-8056 股数 Adapter | Token 的 multiplier 接口本身不构成可用的股数换算实现或生产准入依据 |
| 发行方 `wTSLAx` | wTSLAx / wTSLAx | `BackedAutoFeeLegalShareAdapter` 调用来源 Token 的 `getUnderlyingAmountByShares(rawShares)` | 生产目标是用户直接收付 wTSLAx，按批准的发行方权益公式对实际 V4 delta 计股；真实代理和法律证据仍待准入 |
| TSLAx 可变余额原币 | 不适用 | 不适用 | 不直接入池；用户如需持有 TSLAx，可在 TSV 之外使用发行方自己的包装/赎回流程 |
| Rebase 原币，无合格稳定 Wrapped | 不适用 | 不适用 | V1 不准入 |

“raw 余额稳定”指**没有明确转账/铸造/销毁到该地址时**，`balanceOf()` 不会自行改变；正常转账时余额变化当然允许。wTSLAx 虽名为 Wrapped，V4 持有和用户直接收付的仍是它的稳定 ERC-20 份额；其权益系数动态变化不要求 TSV 同笔接触 TSLAx 原币。其他 xStock 必须逐实例审查，不能自动套用 Tesla 的 shares 接口或公式。

## 2. 池内 Currency 的必过条件

1. **raw 余额稳定。**费率、拆股、反射分配、自动扣费、强制没收或地址差异化余额不能在无明确转账时改写 `balanceOf(PoolManager)`。发行方也不能无授权地改写 PoolManager 持仓。一次余额读取不足以证明该性质；须审查实际实现、权限和升级机制。
2. **双侧精确转账。**`transfer/transferFrom(from,to,x)` 成功且 `from != to` 时，发送者 raw 恰减少 `x`，接收者 raw 恰增加 `x`；不得发送方额外扣税、接收方少收或静默成功。Router/LP Manager 的入池和出池路径均核对发送方、PoolManager 和最终接收方的余额差，`settle()` 返回值也须等于应付 raw。任一不符整笔回滚。标准测试与本地故障币已覆盖发送方额外扣费；真实发行方 Token 仍需逐实例准入验证。
3. **接口与版本可审查。**地址有代码，实际 `decimals()` 与配置一致且 `poolDecimals <= 18`；所用 ERC-20 方法可调用，失败可识别。记录代理 runtime、实际实现、管理员、暂停/制裁权限及变化方式。代理 runtime codehash 不等于实现版本证明。
4. **完整 LP 交付。**同一 Currency 必须可用于 Swap 双方向和 LP 全生命周期，强退只把该 Currency 交付原 owner。发行方拒转时按方案 A 整笔回滚，保留原仓位与 Receipt；准入演练不能保证未来发行方永不拒转。

V4 的 `sync/settle/take` 和 Hook delta 都使用 Currency 的 raw 单位。改变股数 Adapter 不能修复 PoolManager raw 余额自行变化，也不能修复转账税造成的账实差异。

## 3. 股票成交股数

每个股票 Currency 绑定**一套**经审查、版本化的直接换算 Adapter；非股票配对币不绑定。Hook 在 `afterSwap` 依据成功 Swap 股票腿的**实际 V4 raw delta**调用 Adapter 的 `toLegalShares(currency,rawAmount)`，并将返回的非零 `legalSharesWad` 交给 Ledger 记账。输入腿按当前已选的含费 caller 总支出、输出腿按净收到计股；LP、单纯 ERC-20 转账或发行方在 TSV 外的包装/赎回不计为 TSV Swap。此技术口径仍须发行方与法务书面确认，不能直接称为 SEC 批准。

当前接口 `IDirectLegalShareAdapter` 暴露绑定的 `poolCurrency()`、`adapterVersion()` 和 `toLegalShares(currency,rawAmount)`，不携带 rate、nonce、快照或反向换算参数。Registry 通过 ERC-165 检查接口声明，并核对 Adapter 的 Currency 和版本；它不验证换算公式或结果。Hook 在 `afterSwap` 只调用一次 Adapter；若外部换算调用 revert、正 raw 返回零或额度不通过，整笔交易回滚。历史成交不因后续系数变化重算。用户股数输入仍由前端换算为现有 raw 参数。

### 3.1 D-36 直接换算接口与实现边界

当前 `TokenConfig` 不含独立比例字段或固定/动态比例分类。Registry 用 `securityId == 0` 表示非股票配对币；非零 `securityId` 表示股票资产，必须绑定已审查 Adapter 的地址和版本；权益依据保存在链下。`toLegalShares(currency,rawAmount)` 是 Hook 在 `afterSwap` 对真实 delta 的唯一逐笔换算入口；只有 Hook 传入 Ledger 的结果写入 `usedWad` 与 `SwapAccounted`。当前 ABI 不提供反向 `legalSharesWad → raw` 函数。前端若展示“用户当前持有多少股”，须使用发行方批准的**账户持仓权益**定义，并自行完成账户余额/显示单位换算。V1 不新增股数输入合约入口。

## 4. 公司行动与数据单位

拆股/并股按公告对应的**未来计量日开始**调整额度，不依赖代币什么时候完成更新。保留上月日均 `adtvWad` 和 Tier rate；硬上限为 `floor(adtvWad × tierBps × numerator / (10000 × denominator))`。`VOLUME_ORACLE_ROLE` 使用 `DataInbox.submitSplitFactor(SplitFactorReport)` 提前排期，链上按该日 `dayStartUTC` 自动选择系数，不需要激活交易。当天、历史日和日内时刻均不可选择。

系数是相对该来源月 ADTV 基准单位的**绝对累计比例**，一拆二为 `2/1`，五合一为 `1/5`；同月再一拆三应报告 `6/1`。上月 ADTV 使用来源月结束时的股数单位，同月更正保持同一基准，不随排期事件反复改写。新的来源月已经反映事件时默认系数 `1/1`，避免重复乘入。按月末单位归一化市场源数据由报告服务负责，合约无法判别市场原始数据的单位。

新日独立累计，旧日 `usedWad`、历史成交、LP 仓位和 raw 余额不重算。可选 quota 是目标日单位下的**绝对上限**，不会再乘系数；上限仍取调整后硬上限与覆盖值的较小者。排期时应复核已有未来 quota，按需更正或清除。

额度排期与成交计股是两项独立行为：Hook 仍逐笔调用获准的实时 LegalShareAdapter。若 Token 提前或推迟更新，额度切换时间仍由计量日决定，实际换算仍遵从来源。系统不新增通用 Token 单位归一化或 `unitEpoch`，不根据 multiplier 自动识别拆股，也不会提前修改外部 Token。对日内法律单位突变、来源含义不确定或多个 Token 单位不一致，运营须暂停受影响证券/Token，确认计量口径再恢复。同一法律单位内的正常计股率变化可继续使用实时转换。

### 4.1 排期与发行方变更的运营步骤

1. 保存拆/并股公告与法律/市场依据，确定 `securityId`、未来 `effectiveTradeDayId`、目标日开始 UTC 和适用 `sourceMonth`。若治理改排未来日切起点，重新核对公告与 `dayStartUTC`。
2. 确认来源月 ADTV 基准单位，计算绝对累计分子/分母，检查目标日 quota；通过 `VOLUME_ORACLE_ROLE` 提交带递增版本/序号、唯一 ID 的 SET 报告。允许先排系数再上报 ADTV，缺 ADTV 时 Swap 仍被拒绝。
3. 生效前可更正/取消**最后一个待生效检查点**。取消也消耗版本/序号，不复用报告 ID；修改更早项时先依次取消后面的待生效项。生效后不可修改历史。查询未来日系数用于预检查，不表示当前日已经生效。
4. 在日开始前后核对 `currentTradeDay`、`splitFactorOf`、`remaining`、报告事件和来源单位；额度自动切换，不等待 Token 更新或人工激活。保存 Token 提前/推迟更新证据，单独判断是否允许继续按实时 Adapter 成交。
5. 来源单位或映射异常时使用现有暂停入口。更换活跃 Currency 的 Adapter 仍须 `GLOBAL/TOKEN` 紧急记录共同覆盖交易和 LP；`SECURITY/POOL` 单独不能满足替换门槛。`SYMBOL_ADMIN_ROLE` 按递增版本更换，审查依据在链下归档，并在新计量日及口径一致后恢复。raw 池余额随事件发生变化的 Token 不符合第 2 节，额度系数不能补救其结算能力。
6. 新来源月 ADTV 已使用月末股数单位时，不重复排上月事件；需要更正来源数据时保留该月基准和递增版本。历史用量不清零，强退继续按原池 Currency 交付原 owner。

链下审计记录至少包含：

| 字段 | 记录内容 |
| --- | --- |
| `corporateActionId`、`actionType` | 唯一事件 ID；`FORWARD_SPLIT` 或 `REVERSE_SPLIT` |
| `securityId`、`affectedTokens` | 证券与受影响 Token/Adapter |
| `sourceMonth`、基准单位依据 | ADTV 来源月、月末单位及市场数据归一化证据 |
| `effectiveTradeDayId`、`dayStartUTC`、分子/分母 | 链上排期日、对应 UTC 开始时间与绝对累计比例 |
| 公告时间、法律/市场生效时间 | 公告与计量日选择依据 |
| Adapter 版本、发行方参数事件/快照 | 实际成交换算来源与 Token 更新时间，区别于额度切换时间 |
| 报告 ID/版本/序号、交易记录、来源材料 | SET/更正/CANCEL 及可选暂停/恢复的可追溯依据 |

`SplitFactorReport` 的准确 ABI、事件和版本范围见[编码规格 §7 D-37](./CODING_SPEC_V1.md#7-角色报告计量日和额度)。公告、审批、数据单位及 Token 监控的其余证据保存在链下。功能范围限于拆股/并股的额度系数；分红、配股、并购、换股、分拆、赎回、退市和一般代理升级不自动产生系数。

## 5. 注册、持续准入与当前迁移

目标注册以 `poolCurrency` 为唯一 Token 地址和 Registry 主键，保存证券身份及股数 Adapter/版本；`securityId == 0` 的配对币不绑定股数 Adapter，非零 `securityId` 的股票必须绑定股数 Adapter。用户直接支付和接收该池内 Currency；当前 ABI 不含独立用户 Token、结算模式或结算 Adapter 字段，也不提供多路径映射、路径选择、路径专用签名或 LP 路径字段。首次证券及首个 Currency 使用 `admitSecurity` 原子准入；报价币及已有上市证券新增 Currency 使用 `registerToken` 登记即批准。未登记资产为 `ABSENT`，审查未通过不得准入。准入后为 `APPROVED`，市场默认 OPEN，无需首次开市报告；后续 `APPROVED↔DISABLED` 的复审材料保存在链下；停用阻止新 Swap/用户 LP，既有仓位强退按其原始资产交付规则处理。

旧 `TSLAx → wTSLAx` 包装结算不属于当前注册 ABI。目标生产操作直接将 `wTSLAx` 登记为 `poolCurrency`；本部署没有旧 LP 仓位或旧账本，因此不实现旧结算兼容分支，也不提供 TSLAx 退出路径。

已批准 Token 的代理实现、法律公式、转账或限制规则变化时，由链下监控发现并先暂停相关新交易，再以新证据复审。V1 不在链上读取发行方代理实现地址或 codehash，也不把链上旧批准自动视为已失效；监控、告警、暂停、复审和重新批准必须形成可审计运维记录。生产准入还必须核对实际发行方代理、法定股数定义、制裁/暂停、最坏 gas、强退可用性和独立测试证据；详见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。


## 6. Tesla 实例：TSLAx 与 wTSLAx

TSLAx 是 xStock 系列中的 Tesla 实例。本节只限定 Tesla，不把其接口或公式推广到其他 xStock。

| 资产 | TSV 用途 | 准入重点 |
| --- | --- | --- |
| TSLAx | 底层权益与计股依据来源，不进入 TSV Swap/LP 收付 | `sharesOf(account)`、`getCurrentMultiplier()`、显示余额公式、代理实现/权限及发行方确认的法定股数依据 |
| wTSLAx | 目标池内 Currency，用户直接支付或收到的 Token | raw `balanceOf()` 稳定、两侧精确转账、份额托管、暂停/制裁及原 LP owner 强退可达性 |

V1 不在 Swap/LP 中调用 `TSLAx.transferSharesFrom`、`wTSLAx.mint` 或 `wTSLAx.redeem`。目标 Registry 以 wTSLAx 地址作为唯一 `poolCurrency` 并绑定已审的 LegalShareAdapter；池另一侧必须是已批准的非股票 Currency。用户若要将 TSLAx 包装为 wTSLAx，或将退出所得 wTSLAx 赎回为 TSLAx，均在 TSV 之外完成。

`BackedAutoFeeLegalShareAdapter` 绑定 TSLAx 来源合约和 wTSLAx 池内 Currency；构造时核验 Wrapped `asset()` 绑定和两侧 `decimals() == 18`。Hook 在 `afterSwap` 传入实际 wTSLAx shares 数量，Adapter 调用 TSLAx 的 `getUnderlyingAmountByShares(shares)` 并直接将返回值作为 `legalSharesWad`；不保存或验证 multiplier 快照、不调用 nonce getter，也不复制乘法公式。这只证明接入点沿用发行方转换方法，不能单独证明其输出的一单位等于一股。发行方与法务须确认该方法语义、舍入、输入含费/输出净到账口径，以及账户持仓权益定义。真实 wTSLAx/TSLAx 代理 ABI、实现和管理员、转换调用的最坏 gas、转账限制与原 owner 收款能力仍是生产准入门槛；本地行为 mock 不构成真实实例证据。

## 7. ERC-8056 与本地 `STDx` 夹具（当前不接入股数 Adapter）

[ERC-8056](https://eips.ethereum.org/EIPS/eip-8056) 是 ERC-20 UI multiplier 扩展标准，目前为 Draft。仓库中的 [`ERC8056TestToken`](../lib/TestToken/erc8056/ERC8056TestToken.sol)（测试符号 `STDx`）是本地夹具，不是已部署的发行方 Token，也不构成证券权益证明。

该夹具的 raw `balanceOf()`、转账和 V4 结算不随 multiplier 改写。它用于说明 ERC-8056 multiplier 语义，不属于当前 Backed Adapter 的输入类型；仓库未提供读取 ERC-8056 multiplier 的股数 Adapter，Registry 因而不会仅凭此 Token 实现这些接口就准许它作为当前股票资产。生产准入仍须按实际采用的 ERC-8056 版本核对 ERC-165 声明和 multiplier 行为；该 Draft 的接口 ID 为核心 `0xa60bf13d`、待生效系数 `0x4bd27648`，可选转换 `0x57854fc3`、可选 UI 余额 `0xd890fd71`。若未来为其编写直接换算 Adapter，应单独评审并使用发行方批准的逐笔公式，例如：

```text
legalSharesWad = floor(rawAmount × uiMultiplier / 10^decimals)
```

V4 价格、滑点边界、Swap/LP 参数和余额均继续使用 raw 数量；multiplier 不会自动进入 TSV 的额度换算。未来若加入适配器，运行时转换结果会反映 Token 在 `afterSwap` 调用时生效的参数；如果它改变法律股数单位，则按第 4.1 节核对额度排期和单位，必要时暂停处理。准入真实 ERC-8056 Token 还须独立核对接口/权限/代理、raw 稳定、双侧精确转账、multiplier 生效规则、有界 gas、法律单位和对应 ADTV/quota。

当前本地 Hook 集成测试直接接入 Backed Adapter 和 Backed 行为 mock，见 [`BackedAutoFeeLegalShareAdapter`](../src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol) 与 [`Trading.t.sol`](../test/integration/local/trading/Trading.t.sol)。本地测试覆盖不能替代真实 Token 的逐实例准入。
