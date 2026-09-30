# TSV V1 代币准入标准

状态：**目标规范；ERC8056 本地标准夹具已接入，发行方 wTSLAx 生产证据仍待完成**，2026-10-01。V1 每个池内 Currency **只允许直接 ERC-20 结算**：Swap 和 LP 用户支付、接收的 Token 与 `PoolKey` 中该侧 Currency 是同一个地址。TSLAx 是 xStock 系列的一个实例；其发行方 Wrapped `wTSLAx` 可按本标准审查为池内股票 Currency，TSLAx 原币不进入 TSV 的 Swap/LP 入口。`ERC8056TestToken` 是本地标准股票测试代币，用于验证 raw 稳定、UI multiplier 动态计股和直接结算；它不等同于任何真实发行方资产。具体生产差异见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

## 1. 两项独立准入判断

1. **V4 能否正确结算和持有：**池内 Currency 的 raw `balanceOf()` 不因费率、拆股、展示系数等外部状态自行变化；每次 ERC-20 转账发送方恰扣 `x`、接收方恰增 `x`；Swap 双方向及 LP 开/加/减仓、领费、关闭、强退均可按同一 Currency 交付。
2. **监管股数能否正确计算：**股票 Currency 的每笔实际 V4 Swap delta 能在交易时按发行方与法务批准的公式换成统一的 `legalSharesWad`，并与同单位 ADTV、日硬上限及可选日配额比较。Token 名称、`balanceOfUI()` 或 ERC-4626 `convertToAssets()` 本身不证明法定股数。

结算和计股分别审查。同一 Token 可以 raw 余额稳定、但每 raw 单位代表的股票权益随链上系数变化；这类 Token 可直接入池并用动态计股 Adapter。`1e18 legalSharesWad = 1 股`。每个池最多一侧为股票 Currency；同证券不同池的成功 Swap 汇入同一 `securityId` 日账本。

| 资产场景 | 唯一用户 Token / 池内 Currency | 计股方式 | V1 目标结论 |
| --- | --- | --- | --- |
| 普通非股票 ERC-20 | 同地址 | 无 | 经 raw 稳定与精确转账审查后作为配对币 |
| 固定比例股票 ERC-20 | 同地址 | `STATIC_RATIO` | 还需发行方/法务批准逐笔股数公式 |
| raw 稳定的 UI Multiplier 股票 | 同地址 | `ONCHAIN_DYNAMIC` | `ERC8056TestToken` + `ERC8056LegalShareAdapter` 已作为本地标准夹具；真实发行方仍需逐实例批准系数、公式和公司行动规则 |
| 发行方 `wTSLAx` | wTSLAx / wTSLAx | `ONCHAIN_DYNAMIC` | 生产目标是用户直接收付 wTSLAx，按批准的发行方权益公式对实际 V4 delta 计股；真实代理和法律证据仍待准入 |
| TSLAx 可变余额原币 | 不适用 | 不适用 | 不直接入池，也不作为 TSV 用户结算 Token；用户如需持有 TSLAx，可在 TSV 之外使用发行方自己的包装/赎回流程 |
| Rebase 原币，无合格稳定 Wrapped | 不适用 | 不适用 | V1 不准入 |

“raw 余额稳定”指**没有明确转账/铸造/销毁到该地址时**，`balanceOf()` 不会自行改变；正常转账时余额变化当然允许。wTSLAx 虽名为 Wrapped，V4 持有和用户直接收付的仍是它的稳定 ERC-20 份额；其权益系数动态变化不要求 TSV 同笔接触 TSLAx 原币。其他 xStock 必须逐实例审查，不能自动套用 Tesla 的 shares 接口或公式。

## 2. 池内 Currency 的必过条件

1. **raw 余额稳定。**费率、拆股、反射分配、自动扣费、强制没收或地址差异化余额不能在无明确转账时改写 `balanceOf(PoolManager)`。发行方也不能无授权地改写 PoolManager 持仓。一次余额读取不足以证明该性质；须审查实际实现、权限和升级机制。
2. **双侧精确转账。**`transfer/transferFrom(from,to,x)` 成功且 `from != to` 时，发送者 raw 恰减少 `x`，接收者 raw 恰增加 `x`；不得发送方额外扣税、接收方少收或静默成功。Router/LP Manager 的入池和出池路径均核对发送方、PoolManager 和最终接收方的余额差，`settle()` 返回值也须等于应付 raw。任一不符整笔回滚。标准测试与本地故障币已覆盖发送方额外扣费；真实发行方 Token 仍需逐实例准入验证。
3. **接口与版本可审查。**地址有代码，实际 `decimals()` 与配置一致且 `poolDecimals <= 18`；所用 ERC-20 方法可调用，失败可识别。记录代理 runtime、实际实现、管理员、暂停/制裁权限及变化方式。代理 runtime codehash 不等于实现版本证明。
4. **完整 LP 交付。**同一 Currency 必须可用于 Swap 双方向和 LP 全生命周期，强退只把该 Currency 交付原 owner。发行方拒转时按方案 A 整笔回滚，保留原仓位与 Receipt；准入演练不能保证未来发行方永不拒转。

V4 的 `sync/settle/take` 和 Hook delta 都使用 Currency 的 raw 单位。改变股数 Adapter 不能修复 PoolManager raw 余额自行变化，也不能修复转账税造成的账实差异。

## 3. 股票成交股数

每个股票 Currency 绑定**一套**经审查、版本化的 `LegalShareAdapter`；非股票配对币不绑定。Adapter 以 `beforeSwap` 快照和成功 Swap 股票腿的**实际 V4 raw delta**正向换算为非零 `legalSharesWad`。输入腿按当前已选的含费 caller 总支出、输出腿按净收到计股；LP、单纯 ERC-20 转账或发行方在 TSV 外的包装/赎回不计为 TSV Swap。此技术口径仍须发行方与法务书面确认，不能直接称为 SEC 批准。

`STATIC_RATIO` 使用经批准的固定逐笔比例及舍入。`ONCHAIN_DYNAMIC` 从发行方实际链上状态读取当前系数、版本/nonce，按获批公式换算；不依赖心跳交易，也不允许用户自报比率。wTSLAx 和其他 UI Multiplier Token 可分别使用动态 Adapter，公式和舍入不必相同。快照不可读取、公式不可复算、读取 gas 过高、零股或同一交易内版本不一致，交易回滚；历史成交不因后续系数变化重算。`ILegalShareAdapter` 同时提供正向 `toLegalShares` 和只读 `rawForLegalShares`，但用户股数输入仍由前端换算为现有 raw 参数。

### 3.1 D-36 双向 Adapter 规范与实现边界

当前 Registry **不把 `sharesPerWholeTokenWad` 或 `ratioEvidenceHash` 作为计股来源**；这两个旧字段仅为 ABI/存储兼容保留，登记时必须为零。Registry 绑定已审查 Adapter 的地址、版本、运行代码哈希、计股模式、策略摘要和权益依据。静态比例是静态 Adapter 的不可变参数；动态 Adapter 读取发行方状态。两者在同一快照下提供：

- 正向 `raw → legalSharesWad`：仅此结果有权写入 `usedWad` 与 `SwapAccounted`。
- 只读反向 `legalSharesWad → raw`：供前端显示和估计 raw 上下限；分别定义“达到至少目标股数的最小 raw”和“不超过股数上限的最大 raw”。整数舍入可能没有精确逆解，前端展示不是链上股数保证。

正反向必须使用同一已审逐笔函数、快照和舍入规则，满足单调性、边界最小/最大性及有界 gas。当前 `ILegalShareAdapter` 已提供正向和只读反向方法；前端若展示“用户当前持有多少股”，须使用发行方批准的**账户持仓权益**定义，并自行完成显示单位到 raw 参数的换算。按账户总余额舍入的 `balanceOfUI(account)` 可能不同于单笔 `toLegalShares(rawAmount)`。V1 不新增股数输入合约入口，成交后的监管数量始终按 Hook 实际 delta 正向计算。

## 4. 公司行动与数据单位

raw 余额不变而股数权益系数变化时，V4 技术结算可以仍正确；若该变化代表拆股、合股等**法律股数单位**切换，ADTV、可选日配额与 `usedWad` 必须按报告口径统一。Adapter 直接读取发行方当前参数并返回交易快照；同一 UTC 计量日内允许不同 `rateEpoch` 的成功交易并存，事件和链下账本按快照分段汇总，历史成交不静默重算或清零。只有参数/法律映射无法验证、Token 语义变得不安全或数据无法读取时才暂停；公司行动后的来源 ADTV 如需折算，由数据服务提交有版本的更正和依据；已设置的配额也同步审查。

同一 `securityId` 下的多个 Token 可能由不同发行方在不同时间完成拆股实现。Adapter 可以直接读取各自发行方的参数；同一日出现不同 `rateEpoch` 不要求合约强制停牌，但每笔交易必须记录 snapshot/rateId，运营负责按统一报告口径分段汇总。只有参数或法律映射无法验证的 Token 才必须暂停；治理如需同步市场上线，可额外暂停整个 `securityId`。

如果 Adapter 只是读取发行方合约的 multiplier，拆股时不要求人工写入新比例或替换 Adapter 地址。Adapter 应返回发行方参数的 snapshot/nonce；参数按发行方合约的预定生效时间自动采用。若只能读取一个没有版本和生效边界的实时数值，无法审计交易归属时暂停该 Token，直到发行方提供可验证边界或运营完成人工分段方案。

固定比例拆并股若只更新 Adapter 参数，可保留 Adapter 地址并由 Adapter 返回新的 rate epoch；若确实需要替换 Adapter，则必须暂停、递增版本并重新批准。日内生效的历史 used 不折算、不清零，由运营按快照和报告单位处理。若 PoolManager raw 余额本身随公司行动变化，该 Currency 不符合第 2 节，单纯更换计股 Adapter 或参数不足以准入。

## 5. 注册、持续准入与当前迁移

目标注册以 `poolCurrency` 为主键，保存证券身份、股数模式与 Adapter/版本/依据；`userToken` 若保留在 ABI 中，必须恒等于 `poolCurrency`，`settlementMode` 必须为 `DIRECT_ERC20`，`settlementAdapter` 必须为零。**不登记 `(poolCurrency,userToken)` 多路径映射，不提供路径选择、路径专用签名或 LP 路径字段。**`UNREVIEWED→APPROVED→DISABLED→APPROVED` 的复审仍需证据与版本；停用阻止新 Swap/用户 LP，既有仓位强退按其原始资产交付规则处理。

旧 `TSLAx → wTSLAx` 的包装结算配置在当前准入测试中明确拒绝。目标生产操作直接登记 `wTSLAx` 为 `userToken == poolCurrency`，清理结算 Adapter 和底层显示限额；本部署没有旧 LP 仓位或旧账本，因此不实现旧结算兼容分支，也不提供 TSLAx 退出路径。

已批准 Token 的代理实现、法律公式、转账或限制规则变化时，由链下监控发现并先暂停相关新交易，再以新证据复审。V1 不在链上读取发行方代理实现地址或 codehash，也不把链上旧批准自动视为已失效；监控、告警、暂停、复审和重新批准必须形成可审计运维记录。生产准入还必须核对实际发行方代理、法定股数定义、制裁/暂停、最坏 gas、强退可用性和独立测试证据；详见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。
