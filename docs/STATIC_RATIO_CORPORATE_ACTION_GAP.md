# 固定比例股票拆并股与计量单位切换

状态：**部分实现，不能宣称已完成公司行动自动化**（2026-10-01）。

当前 Registry 不把 `TokenConfig.sharesPerWholeTokenWad` 或 `ratioEvidenceHash` 作为计股来源；这两个字段仅为 ABI/存储兼容保留，`registerToken` 要求它们为零。真实比例和舍入由已批准的 `LegalShareAdapter` 提供。

## 1. 当前实现

### 固定比例 Adapter

`StaticLegalShareAdapter` 将比例作为不可变参数返回：

```text
legalSharesWad = ceil(rawAmount × adapter.numerator / adapter.denominator)
denominator = 10^poolDecimals
```

如果拆股或合股改变固定比例，必须部署新 Adapter、递增 `legalAdapterVersion`，并通过 `replaceLegalShareAdapter` 替换。替换前必须满足资产处于可替换状态：相关 Currency 没有活跃池，或已经有足够范围的暂停。替换不会重算历史 `usedWad`、历史事件或已有 LP 仓位。

### 动态 Adapter

如果发行方只更新 multiplier，而 Adapter 代码不变，Adapter 可以继续读取发行方当前参数。`ERC8056LegalShareAdapter` 就是这种本地标准路径：raw 余额保持稳定，`uiMultiplier()` 变化后由新的 `rateId` 计量。这里不需要人工写入 Registry 比例，也不需要为了每次 multiplier 变化替换 Adapter。

当前代码没有单独的 `unitEpoch`、公司行动生效日或“禁止旧单位在新日继续记账”的链上状态机。因而动态参数在同一 UTC 计量日内变化时，允许不同 `rateId` 的成交共存；历史交易不重算，运营和索引器必须按事件中的 `rateId` 分段汇总。

## 2. 拆股/合股的业务事实

公司行动法律上影响的是 `securityId` 对应的证券权益单位；技术上，每个池内股票 Currency 都由自己的 Adapter 读取或实现该证券权益公式。不同 Token 的发行方切换时间可以不同，不要求合约等待所有 Token 同步。

必须分别确认：

- 新旧每 raw 单位对应的法定股数；
- 舍入规则和最小股数单位；
- 发行方参数的生效时间、nonce 或其他可验证版本；
- ADTV、可选日 quota 和 `usedWad` 是否已经切换到同一法律单位；
- 发行方是否改变 PoolManager 持有的 raw 余额。

如果 PoolManager 的 raw `balanceOf()` 会自行变化，Token 首先违反 V4 Currency 准入，单纯更新 Adapter 不能修复。

## 3. 推荐运营流程

### 3.1 Adapter 参数自动变化

适用于发行方提供有版本或生效边界的链上参数：

1. 运营监听发行方公告、参数更新和 Adapter 可读状态；
2. 在参数切换前确认新的 `rateId`、公式、舍入和法定单位证据；
3. 如果 raw 余额仍稳定，允许 Adapter 在后续交易读取新快照；
4. Hook 将每笔交易的 `rateId`、版本和 `legalSharesWad` 写入 `SwapAccounted`；
5. 运营按新旧 `rateId` 对 ADTV、quota 和日账进行分段核对；
6. 如果无法确定生效边界或无法读取新参数，立即暂停相关 Token 或整个 `securityId`。

### 3.2 固定比例需要更换 Adapter

适用于新比例无法由现有 Adapter 读取的情况：

1. 在生效前暂停相关 Token、Pool 或 Security；
2. 准备新 Adapter、代码哈希、版本、策略摘要和法务依据；
3. 确认没有活跃池，或确认暂停范围足以阻止新 Swap/用户 LP；
4. 调用 `replaceLegalShareAdapter`，递增版本并记录依据；
5. 提交与新法定单位一致的新 ADTV，重新审查当日 quota；
6. 验证快照、事件、额度和 LP 强退路径后恢复交易。

### 3.3 日内生效

当前链上代码允许同一计量日存在不同 `rateId`，但没有自动把旧 `usedWad` 换算为新单位的功能。若公司行动要求日内统一换算，必须先由业务/法务冻结：

- 换算基准和方向；
- 已用量、ADTV、quota 的换算和舍入；
- 生效前后交易的归属边界；
- 失败恢复和审计方式。

在这些规则没有编码和验收前，最安全的运营处置是暂停到下一个 UTC 计量日，并从新单位提交 ADTV/必要 quota。暂停不影响原 owner 的强退入口；强退仍交付池内 Currency，并按直接结算规则核对 raw 差额。

## 4. 不支持的推断

- 不能从 Token 名称、`balanceOfUI()` 或 `convertToAssets()` 自动推断法定股数；
- 不能把 Registry 中旧兼容字段当成第二份比例配置；
- 不能因为两个 Token 映射同一 `securityId` 就假设它们在同一时刻完成拆股；
- 不能在没有生效边界的情况下把不同单位的 ADTV、quota 和 `usedWad` 直接相加；
- 不能通过替换 Adapter 追溯重写历史成交。

## 5. 当前缺口

GAP-03 仍为部分实现：Adapter 正向/反向换算、动态 multiplier 快照和事件记录已经存在，但日内公司行动的统一单位换算、报告更正和自动生效状态机尚未编码。生产启用前应把发行方参数证据、运营 runbook、暂停范围和单位核对结果纳入准入清单。
