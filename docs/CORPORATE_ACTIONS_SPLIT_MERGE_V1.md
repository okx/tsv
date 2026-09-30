# TSV V1 拆股/合股计量设计讨论稿

状态：**待决策讨论稿，不是最终编码规格**。V1 只处理会改变交易量记账单位的公司行动，当前纳入的具体事件是正向拆股和反向拆股。它们可能通过切换同一 `LegalShareAdapter` 的已批准参数/计量 epoch 实现，也可能在计量公式发生变化时更换 Adapter。Adapter 可以自动读取发行方参数；如果参数在日内变化，后续交易使用新的 snapshot，前序交易保留旧 snapshot，由运营负责拆分、换算和额度报告处理。现金分红、配股、并购、分拆、赎回、停牌、退市、名称变化和一般 Token 升级均标记为 **V1 无需考虑**，不进入本合约的公司行动流程。最终规则冻结前，本文中的字段、时间和状态不能直接生成生产合约。

## 1. 先确定事件属于谁

拆股或合股是底层证券的公司行动，事件主体是 `securityId`，不是某一个 Token 地址，也不是某一个 V4 PoolId。

```text
securityId = TESLA
├── wTSLAx        -> LegalShareAdapter A
├── 另一个 UI Token -> LegalShareAdapter B
└── quote 交易池   -> 多个 PoolId
```

公司行动会影响同一 `securityId` 下所有代表该证券的 Token 和所有池。每个 Token 可以有不同的 raw 数量、份额模型和 Adapter，但最终必须转换成同一个 `legalSharesWad` 单位，汇入同一个证券日账本。

因此：

- `securityId` 是公司行动的主键。
- `poolCurrency` 是具体 Token 的结算地址。
- `LegalShareAdapter` 负责把该 Token 的实际 raw 数量转换为公司行动前后对应的法定股数；公司行动可以只更新 Adapter 使用的已批准参数，也可以更换 Adapter 实现。
- `PoolId` 只决定交易发生在哪个池，不决定拆股范围。

如果只是 Wrapped Token 自身的兑换系数变化，但底层证券的法律股数单位没有改变，这属于 Token 表示层变化，可以只更新该 Token 的 Adapter。如果变化代表证券本身的拆股或合股，则必须按 `securityId` 范围处理。

## 2. 交易所通常怎样处理

“公司宣布拆股”和“市场开始按拆股后单位交易”不是同一个时间。

通常至少有以下时间点：

| 时间 | 含义 | TSV 是否立即切换计股 |
| --- | --- | --- |
| `announcedAt` | 发行方公布公司行动 | 否 |
| `legalEffectiveAt` | 公司法律文件生效 | 不一定 |
| `marketEffectiveAt` / `exDate` | 交易所开始按新股数和新价格交易 | 仍需等待 TSV 规则 |
| `tsvEffectiveTradeDay` | TSV 开始使用新 Adapter 或新参数 epoch 和新单位的计量日 | 是 |

普通正向拆股通常在指定日期切换到拆股后价格和数量，不一定有长时间停牌。反向拆股更可能在生效前后安排交易暂停或开盘竞价。具体处理由交易所、发行方和上市地规则决定，TSV 不能自行推断。

参考：

- [Investor.gov：Stock Split](https://www.investor.gov/introduction-investing/investing-basics/glossary/stock-split)
- [NYSE Corporate Actions and Trading Halts](https://www.nyse.com/regulation/corporate-actions-market-watch-proxy-compliance)
- [Nasdaq Listing Center Rules](https://listingcenter.nasdaq.com/rulebook/nasdaq/rules/nasdaq-5200-series)

## 3. TSV V1 的候选生效方案

### 方案 A：下一个 UTC 计量日生效（当前推荐）

发行方或链下数据源确认公司行动后，先锁定该证券的目标 `unitEpoch`，不在日内切换 Adapter。若某个 Token 的发行方实现时间或新旧公式无法确认，只暂停该 Token；若无法确认整个证券的统一单位，则治理可暂停整个 `securityId`，待下一个 TSV UTC 计量日边界处理。

例如日切时间为 UTC 04:00：

```text
2026-10-10 15:00 UTC    发行方宣布 1 拆 2
2026-10-10 15:00 UTC    链下监控确认事件，暂停 TESLA 新 Swap
2026-10-11 04:00 UTC    新计量日开始
2026-10-11 04:00 UTC    新 Adapter 或新参数、新单位、新 ADTV/配额开始生效
```

优点：

- 一个 TSV 计量日只使用一套 `legalSharesWad` 单位。
- `usedWad` 不需要在日内换算。
- ADTV 和可选日配额可以在新计量日前按新单位提交。
- 不需要在 Hook 中同时维护拆股前后两套当日单位。

代价：

- TSV 可能比市场晚一段时间恢复交易。
- 如果市场已经按新单位交易，TSV 仍必须保持暂停，直到自己的计量日边界。

### 方案 B：市场生效时间立即切换

在 `marketEffectiveAt` 到达后立即切换 Adapter。交易可在同一个 TSV 日内使用旧单位和新单位。

这要求 VolumeLedger 至少保存：

```text
usedBeforeAction
usedAfterAction
unitEpoch
```

并定义：

- 切换前成交量如何换算成新单位。
- 当日 ADTV 是否按新单位重新提交。
- 已提交 quota 是否自动换算。
- 切换交易本身使用旧单位还是新单位。
- 切换时间附近的交易排序和重组如何处理。

该方案更接近市场实时状态，但会显著增加账本、报告和审计复杂度。V1 暂不建议采用。

### 方案 C：不暂停，只在下一个计量日切换

市场可以继续交易，TSV 在公告后不暂停，但直到下一个计量日仍使用旧 Adapter/旧参数 epoch。

该方案实现简单，但存在 TSV 与市场法律单位在同一时间段不一致的风险。除非发行方和法务明确允许，否则不建议作为默认方案。

## 4. 拆股/合股的 Token 语义

### 4.1 raw 余额稳定的 Wrapped Token

这是 TSV 最容易处理的情况。

例如原来：

```text
1 wTSLAx raw = 1 股
```

发生 1 拆 2 后：

```text
1 wTSLAx raw = 2 股
```

如果 wTSLAx 的 `balanceOf()` 不变，V4 池中的 raw 余额不变，TSV 只需在新生效日切换 `LegalShareAdapter` 的参数/rate epoch；只有计量公式代码变化时才更换 Adapter。新交易按新 Adapter/参数计股，历史成交保留旧版本和旧参数结果，不追溯重算。

### 4.2 Rebase 原币

如果拆股导致原币 `balanceOf()` 自动增加或减少，PoolManager 的持仓余额会自行变化。这类 Token 不符合当前 V4 直接结算准入标准，不能通过更换 LegalShareAdapter 解决。

### 4.3 UI Multiplier Token

如果 raw `balanceOf()` 稳定，而 `balanceOfUI()` 或内部 multiplier 变化，必须区分两种情况：

1. 只是显示或兑换估值变化，法律股数单位没有改变：属于 Token 级 Adapter 更新。
2. 发行方确认法律股数单位发生拆股/合股变化：属于 `securityId` 级公司行动。

不能仅根据函数名称 `balanceOfUI()`、`convertToAssets()` 或 multiplier 变化自动判断法律事件。

## 5. 多个 Token 代表同一证券时

假设同一 `securityId` 下有两个 Token：

```text
TESLA
├── wTSLAx -> Adapter v2
└── UIx    -> Adapter v5
```

一次 1 拆 2 事件应当产生一个证券级公司行动，但需要分别批准两个 Token 的新 Adapter 或新参数 epoch：

```text
corporateActionId = TESLA-SPLIT-2026-10
effectiveTradeDay = 2026-10-11

wTSLAx -> Adapter v2, actionId
UIx    -> Adapter v5, actionId
```

这里要区分三个时间：

- `securityEffectiveTradeDay`：该证券开始使用拆股后法定股数单位的统一 TSV 计量日。
- `tokenImplementationReadyAt`：某个发行方 Token 已实际完成余额/兑换公式或 multiplier 更新，并通过链下核验的时间。
- `tokenActivationTradeDay`：该 Token 的新 Adapter 或新参数 epoch 真正允许写入账本的计量日。

发行方可以在不同时间完成实现，且参数可以在日内变化；账本需要满足：

- 公司行动只有一个 `securityId` 级的 `corporateActionId` 和目标 `unitEpoch`。
- 每笔成功 Swap 都使用当时从发行方读取的 Adapter snapshot，并记录 `rateId`/参数 nonce；前序交易不被新参数追溯改写。
- 发行方提前或延迟更新参数本身，不自动导致 Token 禁止交易；只要 Adapter 仍能读取并验证当前法律股数映射，后续交易即可使用新 snapshot。
- 如果参数、兑换公式或底层余额语义无法读取或无法验证，才将受影响 Token 置为 `DISABLED`；如果业务要求所有代表 Token同步处理，治理可以扩大为整个 `securityId` 暂停。
- `unitEpoch` 和 `rateEpoch` 主要用于事件审计、日账分段和运营换算，不作为“不同就必须回滚”的硬门禁。

因此，允许“一个 Token 先更新参数、另一个 Token 稍后更新”，也允许同一日账本存在多个参数 snapshot；每笔交易必须带有可审计的 rate 信息，运营负责把不同 snapshot 的成交量转换到报告使用的统一口径。暂停 Token 的现有 LP 强退路径不因参数未更新而消失；强退本身不计入 Swap 成交量。

### 5.1 Token 实现时间不一致时的推荐状态

```text
证券级公司行动：TESLA-SPLIT-2026-10
目标计量日：2026-10-11 04:00 UTC

wTSLAx：发行方已在 2026-10-10 更新 multiplier
       -> Adapter 自动读取 rateEpoch=2，后续交易使用新 snapshot

UIx：发行方预计 2026-10-12 才完成公式升级
     -> 2026-10-11 仍使用旧 snapshot，后续交易继续记录旧 rateEpoch
     -> 2026-10-12 后自动读取新 rateEpoch；运营按 snapshot 分段处理日账
```

这样每笔交易都有明确的参数依据；`usedWad[securityId][tradeDayId]` 的跨 epoch 汇总和额度口径由运营按报告单位换算处理，而不是由合约强制禁止日内参数变化。

### 5.2 参数无法读取或验证时的处理

只有在 Adapter 无法读取发行方参数、无法确认法律股数映射，或 Token 的 raw 转账语义发生未知变化时，才采用 fail-closed：

- 该 Token 的新 Swap 和新增 LP 被拒绝，不产生新的 `usedWad`。
- 同一 `securityId` 下其他参数可验证的 Token 仍可交易；如果业务要求整体停牌，治理可以暂停整个 `securityId`。
- 如果该证券只有一个 Token（例如当前 Tesla 仅使用 wTSLAx），则该证券的所有新 Swap 和新增 LP 暂停，直到参数/公式恢复可验证。
- 已存在的 LP 仓位不因参数不可验证而丢失。普通用户 LP 变更可按暂停策略被拒绝；只要 Pool Currency 的 raw 转账语义仍然可验证，原 owner 的强退路径仍可用，且不写入 Swap 成交量。若 Token 转账本身失败，交易整体回滚，仓位和 Receipt 保留，待后续重试。

因此，禁止交易是针对“无法计量”的异常，而不是针对“项目方尚未手工切换参数”的正常情况。

### 5.3 参数变化后继续交易的记账要求

如果同一日出现多个参数 snapshot，V4 的 raw 转账可以继续正常执行，但监管报表不能把不同 snapshot 的数值未经处理直接视为同一口径。这里的“旧 Adapter”也包括同一 Adapter 仍读取旧 multiplier/参数 epoch：

| 情况 | 未记录 snapshot 或未做运营换算的结果 |
| --- | --- |
| 1 拆 2，旧公式为 `1 raw = 1 股`，新公式为 `1 raw = 2 股` | 实际 100 raw 应记 200 股，却只记 100 股；日额度可能被实际使用量的约两倍突破 |
| 10 合 1，旧公式为 `1 raw = 1 股`，新公式为 `1 raw = 0.1 股` | 实际 100 raw 应记 10 股，却记成 100 股；合法交易可能被错误拒绝，额度被过早耗尽 |
| Token 已先改变 multiplier/余额语义，但 Adapter 仍按旧参数快照 | 可能低计或高计；如果 `balanceOf()` 还发生 rebase，V4 持仓和结算本身也可能失真 |

因此，允许参数变化后继续交易是可以的，但必须由运营处理两个账务要求：

1. 每笔成功 Swap 必须记录当时的 `rateId`/参数 nonce。
2. `usedWad`、ADTV 和 quota 在对外报告或额度判断时，必须换算到当期规定的法定股数口径。

若运营无法取得旧/新 snapshot 的换算依据，才必须暂停受影响 Token。单纯让交易继续但不记录参数依据、事后也无法换算，不能满足审计要求。

### 5.4 项目方长期不完成拆股实现

“项目方没有修改 Token 合约”本身不能直接判断失败。需要区分：

| 情况 | 是否可以恢复交易 | 处理方式 |
| --- | --- | --- |
| Token raw 余额保持稳定，但项目方确认拆股后的法律权益映射已经成立 | 可以 | 发行方提供可验证依据；治理批准同一 Adapter 的新参数/rate epoch，或批准新的 `LegalShareAdapter`。参数 epoch 更新本身就是 TSV 的实现切换 |
| Token 合约和 raw 余额不变，项目方也不确认新的法律股数、赎回或底层权益映射 | 不可以 | Token 持续 `DISABLED`，不能用旧 Adapter 继续交易 |
| 项目方明确不会让 Token 继续代表拆股后的证券 | 不可以 | 终止该 Token 的新交易；未来如有新 Token，必须重新登记、准入和建池 |
| 发行方无法提供证据，或 Adapter 公式无法复算/边界不确定 | 不可以 | 保持 `DISABLED`，不允许治理凭猜测覆盖公式 |

如果项目方长期不完成实现，V1 不自动替换 Token、不自动转换 LP 仓位、不自动把旧 Token 兑换成其他资产，也不设置超时后强行放行。只要 raw 转账仍然可验证，原 owner 的强退路径保留；若 Token 转账或赎回也失败，强退交易回滚并等待人工处置。该 Token 的未使用额度不会结转，也不会因为长期禁用而被视为已成交。

### 5.5 参数自动读取，不等于日内无边界切换

当 Adapter 的代码已经固定为“读取发行方当前 multiplier 并计算法定股数”时，TSV 不需要人工调用 `setRate`，也不需要替换 Adapter 地址。每笔交易可由 Adapter 直接读取发行方合约的当前参数、参数 nonce 和生效时间，并返回本次计量使用的 rate snapshot。

但自动读取仍需保留审计边界：

- 发行方合约如果提供参数 nonce 和预定生效时间，Adapter 可以自动识别参数版本；后续交易自动使用新参数，不需要治理手工写入 multiplier。
- 如果发行方在日内直接改变参数，Adapter 仍可读取新值并继续交易；Hook/Ledger 必须把新旧 snapshot 分别写入交易事件，运营再按报告口径换算日账和额度。
- 如果合约没有可验证的版本、参数值或生效时间，运营无法重建不同 snapshot 的关系时，才暂停受影响 Token。
- `unitEpoch` 表示证券法律股数单位，`rateEpoch` 表示发行方参数 snapshot；Adapter 地址和代码版本可以不变，两个 epoch 的关系必须能被交易事件审计。

以本仓库的 BackedAutoFee 接口为例，`getCurrentMultiplier()`、`multiplierNonce()` 和 `newMultiplierActivationTime()` 可作为参数 snapshot 的来源；这不代表 TSV 自动批准发行方的任意参数变化，参数的法律含义和生效边界仍必须满足准入规则。

## 6. 状态和报告的候选模型

以下结构只是讨论用，不是已冻结 ABI：

```solidity
enum CorporateActionType {
    FORWARD_SPLIT,
    REVERSE_SPLIT
}

enum CorporateActionStatus {
    ANNOUNCED,
    SCHEDULED,
    PAUSED,
    ACTIVE,
    CANCELLED
}

struct CorporateActionReport {
    bytes32 securityId;
    bytes32 corporateActionId;
    CorporateActionType actionType;
    uint256 oldToNewNumerator;
    uint256 oldToNewDenominator;
    uint64 announcedAt;
    uint64 legalEffectiveAt;
    uint64 marketEffectiveAt;
    uint32 targetTradeDayId;
    uint64 sequence;
    bytes32 sourceHash;
    bytes32 evidenceHash;
}

// 讨论用：每个 Token 的就绪状态，不是已冻结 ABI
struct TokenActionReadiness {
    bytes32 corporateActionId;
    address poolCurrency;
    uint64 implementationReadyAt;
    uint32 activationTradeDay;
    uint64 newAdapterVersion; // Adapter 代码不变时可保持不变
    uint64 newRateEpoch;      // 由发行方参数 nonce/生效状态读取，不是人工写入 multiplier
    bytes32 evidenceHash;
}
```

仍需决定：

- 拆股比例是否作为链上审计元数据保存，还是只由 Adapter 代码和链下证据表达。
- `legalEffectiveAt` 和 `marketEffectiveAt` 由哪个角色提交。
- 报告提交者是 `VOLUME_ORACLE`、`HALT_REPORTER` 还是独立的公司行动角色。
- 是否允许在生效前取消或修改报告。
- 是否按 Token 分别记录 `implementationReadyAt`/`activationTradeDay`，还是要求同一 `securityId` 的所有 Token 一次性绑定新 Adapter/参数 epoch。

比例字段不能替代 Adapter 公式。动态 Wrapped Token 可能还涉及 multiplier、内部 shares、舍入和最小股单位，单独保存一个拆股比例不足以定义完整的计股逻辑。

## 7. ADTV、quota 和 usedWad

采用方案 A 时：

1. 公司行动前的已关闭计量日保留旧单位、旧 Adapter 版本和旧参数 epoch。
2. 新计量日开始后，新的 ADTV 报告必须声明新单位版本或对应的公司行动 ID。
3. 新日 quota 若存在，必须按新单位提交。
4. `usedWad` 不跨日换算，不清零历史数据。
5. 交易事件记录 `legalAdapterVersion` 和 `corporateActionId`，便于审计。

如果采用方案 B，则必须另行设计旧 `usedWad` 的转换算法；在该算法冻结前，日内生效应保持禁用。

## 8. 拆股/合股的链下监控与暂停

拆股/合股公告、法律生效时间和市场生效时间由链下监控发现。TSV 不依赖心跳交易，也不通过读取发行方代理实现地址自动判断拆股比例。

监控发现拆股/合股后的推荐操作：

```text
链下监控发现拆股/合股公告
    ↓
核对 securityId、Token、比例、法律生效时间和市场生效时间
    ↓
EMERGENCY_PAUSER 或业务运营角色暂停受影响 Token；必要时暂停该 securityId
    ↓
提交公司行动报告和新 Adapter/参数审查材料
    ↓
在目标 UTC 计量日绑定新版本
    ↓
EMERGENCY_RESUMER / 业务授权恢复交易
```

链下监控失败时，合约无法自行知道发行方已经宣布拆股/合股。因此生产系统必须记录：

- 监控数据源和订阅范围。
- 事件首次发现时间。
- 发行方公告、交易所公告和链上交易的证据哈希。
- 暂停提交交易哈希。
- 新 Adapter 审查和恢复交易哈希。

## 9. 拆股/合股专属待决策问题

以下问题确认前，拆股/合股部分不能升级为最终编码规格；最终编码待决策见 §17：

1. V1 是否固定采用“下一个 UTC 计量日生效”，还是必须支持市场生效时间即时切换。
2. 日内公司行动时，是否一律暂停到下一个计量日。
3. `marketEffectiveAt` 与 `legalEffectiveAt` 哪一个作为 TSV 暂停触发依据。
4. 公司行动报告由哪个角色提交和签名。
5. 是按 Token 分别就绪后启用各自的新 Adapter/参数 epoch，还是要求同一 `securityId` 下所有 Token 全部就绪后再恢复交易。
6. 拆股比例是否上链保存为审计数据。
7. ADTV 和 quota 报告是否必须显式携带 `unitEpoch` 或 `corporateActionId`。

当前推荐：采用 Token 级就绪和暂停，所有已启用 Token 在同一证券级 `unitEpoch` 下记账；不要求所有发行方必须在同一时刻完成实现，也不允许未就绪 Token 使用旧单位或旧参数 epoch 继续交易。

## 10. V1 公司行动范围

V1 不按“公司行动”这个宽泛的业务名称扩展功能，而只判断一件事：**该事件是否改变本证券在 VolumeLedger 中的法定股数计量单位**。

| 范围 | 事件 | V1 处理 |
| --- | --- | --- |
| **纳入** | 正向拆股（例如 1 拆 2） | 暂停相关证券，在下一个 UTC 计量日切换新 Adapter/参数 epoch 和新计量单位 |
| **纳入** | 反向拆股/合股（例如 10 合 1） | 同上，并额外处理零碎股和舍入规则 |
| **无需考虑** | 股票股利、现金分红、特别股息 | 不建立专门公司行动逻辑；若未来确认改变法律股数，按新增需求重新设计 |
| **无需考虑** | 配股、供股、认购权 | 不计入 `VolumeLedger`，不在 Hook 内执行认购或稀释计算 |
| **无需考虑** | 合并、收购、换股、公司重组 | 不做自动换股、`securityId` 替换或池迁移 |
| **无需考虑** | 分拆、剥离、新证券分派 | 不做多资产分派；新证券未来独立登记、独立建池 |
| **无需考虑** | 强制赎回、到期转换、发行方回购 | 不在 Swap/LP 内调用发行方赎回，不设计备用结算路径 |
| **无需考虑** | 市场停牌、退市、交易恢复 | 不作为公司行动计量逻辑；若属于事故，沿用既有紧急暂停流程 |
| **无需考虑** | 名称、代码、ISIN/CUSIP 变化 | 不改变 `securityId`、PoolKey 或记账单位 |
| **无需考虑** | 发行方代理升级、一般 multiplier 变化 | 不在公司行动模块处理；按 Token 准入和链下监控流程单独处理 |

“无需考虑”表示 V1 不为该事件新增专门的链上数据结构、计量公式或自动化操作；不表示发行方发生这些事件时系统会自动安全处置。若未来某事件实际改变 `legalSharesWad`，必须先立项扩展规格，再部署对应 Adapter 和测试。

## 11. 各类公司行动的具体操作

### 11.1 正向拆股（Forward Split）

**含义**：每一股拆成多股，例如 1 拆 2。每份旧股的法律权益被换算成更多份新股，单股价格通常相应下降。

**操作顺序**：

1. 链下监控记录发行方公告、法律生效日和市场生效日。
2. 将事件绑定到 `securityId`，为该证券下每个可交易 Token 指定新的 Adapter 版本或新的参数/rate epoch。
3. 如果公告已经确认某个 Token 的余额、multiplier 或赎回公式将改变，暂停该 Token 的新 Swap；若整个证券的新旧单位无法确认，再暂停该 `securityId`。现有 LP 保留原 owner 的强退路径。
4. 以目标 UTC 计量日作为 `tsvEffectiveTradeDay`，不能在一个计量日内同时写入新旧单位。
5. 新计量日开始前准备新的 ADTV 和可选日 quota；新日交易使用新 Adapter 或新参数 epoch，历史日账本不追溯重算。
6. 每个 Token 完成审查并到达自己的 `tokenActivationTradeDay` 后恢复交易；未完成的 Token 单独保持 `DISABLED`。治理可在业务需要时继续保持整个 `securityId` 暂停。

**禁止的自动动作**：不自动修改 PoolKey、不自动改变 Token 地址、不自动把旧 LP 仓位迁移到新 Token、不在同一笔交易里调用发行方赎回。

### 11.2 反向拆股/合股（Reverse Split）

**含义**：多股合成一股，例如 10 合 1。需要特别处理零碎股（fractional shares）和舍入规则。

**操作顺序**与正向拆股相同，但新增以下检查：

- Adapter 必须明确不足一股的部分如何计量，不能用 Solidity 默认向下取整掩盖法律权益损失。
- 若发行方将零碎股现金结算，TSV 不自动代发现金，也不把现金折算成另一种 Pool Currency。
- 如果合股导致某些 Token 余额归零、暂停转账或改变最小赎回单位，必须先 `HALT` 或 `DISABLED`，完成 Token 行为测试后才可恢复。

### 11.3 其他公司行动：V1 无需考虑

以下事件全部不进入 V1 公司行动计量流程：

| 事件 | V1 处理 | 原因 |
| --- | --- | --- |
| 股票股利、红股、面值调整 | 无专门逻辑 | 只有确认改变 `legalSharesWad` 后，才作为未来新增的单位变化需求 |
| 现金分红、特别股息 | 无专门逻辑 | 不改变交易量记账单位 |
| 配股、供股、认购权 | 无专门逻辑 | 不属于池内股票成交数量 |
| 合并、收购、换股、公司重组 | 无自动换股或池迁移 | 会改变证券身份，超出 V1 计量范围 |
| 分拆、剥离、新证券分派 | 无多资产分派 | 新证券应未来独立登记、独立建池 |
| 强制赎回、到期转换、发行方回购 | 不在 Swap/LP 中调用发行方操作 | 不属于交易量单位更新 |
| 市场停牌、退市、交易恢复 | 不进入公司行动模块 | 沿用既有 HALT/紧急暂停流程 |
| 名称、代码、ISIN/CUSIP 或 Token 地址变化 | 不改变现有计量逻辑 | 属于元数据或新 Currency 登记问题 |
| 发行方代理升级、一般 multiplier 变化 | 不在本文件实现 | 沿用 Token 准入和链下监控流程 |

“无需考虑”表示 V1 不新增该事件的链上字段、Adapter 公式、自动迁移或自动结算路径。未来如果确认某项实际上改变了法定股数计量，必须作为新的规格变更重新设计，不能直接套用本文件。

## 12. 事件到链上操作的映射

下表使用的是**抽象操作名**，用于定义行为顺序，不是已经冻结的 Solidity 函数名或 ABI：

| 事件 | 发现后链下动作 | 立即链上动作 | UTC 日切动作 | 恢复条件 |
| --- | --- | --- | --- | --- |
| 正向/反向拆股 | 核对比例、法律股数和每个 Token 的 Adapter/参数 | 参数无法读取或映射不明时 `PAUSE` | Adapter 自动读取新参数并记录 rateId；运营更新 ADTV/quota 口径 | 所有允许交易的 Token 公式、参数和审计证据齐全 |
| 其他公司行动 | 不建立公司行动报告 | 无 | 无 | V1 无需考虑 |

每个链上动作都必须先由运营记录 `corporateActionId`、证据哈希和影响范围，再由具有对应权限的角色提交。不存在“看到公告后自动调用发行方合约”的隐含路径。

## 13. 拆股/合股状态机

只有正向拆股和反向拆股进入本状态机：

```text
DETECTED
   ↓ 证据和 securityId 核对
VERIFIED
   ├── 无结算影响 → RECORDED → CLOSED
   └── 有不确定性/结算影响
          ↓
        PAUSED
          ↓ 分类、Adapter 和 Token 行为审查
        PREPARED
          ↓ 到达目标 UTC 计量日或人工确认终止
        ACTIVE / DISABLED
          ├── ACTIVE → RESUMED
          └── DISABLED → 保留强退/人工处置路径
```

每个事件的链下记录至少包含：

| 字段 | 用途 |
| --- | --- |
| `corporateActionId` | 事件唯一标识，禁止复用 |
| `securityId` | 事件影响的法律证券 |
| `actionType` | `FORWARD_SPLIT` 或 `REVERSE_SPLIT` |
| `affectedTokens[]` | 受影响的 Token 地址和各自 Adapter |
| `announcedAt` / `legalEffectiveAt` / `marketEffectiveAt` | 三个外部时间点 |
| `tsvEffectiveTradeDay` | TSV 计量边界 |
| `oldAdapterVersion` / `newAdapterVersion` | 计股公式代码变化；代码不变时版本可不变 |
| `oldRateEpoch` / `newRateEpoch` | multiplier/参数变化，即使 Adapter 地址和代码不变也必须留痕 |
| `oldUnitEpoch` / `newUnitEpoch` | ADTV、quota 和 usedWad 的单位审计 |
| `pauseScope` | Token、security、venue 或全局 Hook |
| `evidenceHash` | 公告、交易所通知和人工复核材料哈希 |
| `status` | 状态机当前状态 |

这些字段首先是运营和审计记录。是否全部进入链上 `CorporateActionReport`，应在编码规格中根据 gas、查询和不可篡改审计要求逐项冻结。

## 14. 拆股/合股发生时的标准操作顺序

```text
1. 监控发现事件
       ↓
2. 核对公告、市场规则、`securityId`、Token、拆股比例和时间点
       ↓
3. 确认该事件改变法律股数单位，并确定新旧 Adapter/参数 epoch
       ↓
4. 暂停受影响的 `securityId` 或 Token
       ↓
5. 准备新 Adapter 或新参数 epoch、`unitEpoch`、ADTV、quota 和证据
       ↓
6. 由授权角色提交报告并完成复核
       ↓
7. 按发行方参数的实际生效时间读取新 snapshot，并在交易事件中记录 rateId/epoch
       ↓
8. 复核通过则 RESUME；否则保持 PAUSED/DISABLED
       ↓
9. 归档交易哈希、报告、测试结果和监控证据
```

这里不要求多个 Token 或多个参数在同一笔交易中原子启用。每笔交易只需使用当时可读取的 Adapter snapshot，并记录对应的 `rateId`/epoch；同一 `securityId` 日内出现新旧 snapshot 由运营分段汇总和换算。如果某个 Token 的映射无法验证，可以保持单独暂停；其他 Token 可以继续交易。

## 15. V1 明确不自动做的事情

为了保持 V4 结算和 VolumeLedger 可审计，V1 不自动执行以下动作：

- 不改写已有 `PoolKey` 的 Currency 地址。
- 不把一个 `securityId` 自动改成另一个 `securityId`。
- 不跨证券、跨 Token 或跨池迁移 LP 仓位。
- 不在交易中调用发行方赎回、换股、配股或分红合约。
- 不把现金、零碎股补偿或新证券作为隐含的第二结算资产。
- 不通过聚合器、Permit 或 AA 钱包绕过 SBT、Token 准入或暂停检查。
- 不用心跳交易延长报告有效期；只有状态变化或新期间数据才上链。
- 不允许在没有 `rateId`/snapshot 记录和运营换算依据的情况下混用旧、新参数 epoch。
- 不为现金分红、配股、并购、分拆、赎回、停牌或名称变化新增公司行动逻辑。

## 16. 建议的 V1 范围冻结

若目标是先完成可编码且可审计的 V1，冻结为：

1. **只支持**：正向拆股和反向拆股，统一在下一个 UTC 计量日切换 Adapter。
2. **其他公司行动均无需考虑**：不新增链上报告、计量公式、自动迁移或自动结算路径。
3. **不支持**：日内新旧单位并存、自动跨证券换股、自动现金分红、自动旧池迁移和备用接收人结算。

这一范围只解决一个问题：拆股/合股后，V4 继续使用稳定的 Pool Currency，同时让 VolumeLedger 按新的法定股数单位准确记录交易量。

## 17. 扩展为最终编码规格前的待决策项

在本文件升级为正式编码规格前，还需冻结：

1. `actionType` 是否只保留 `FORWARD_SPLIT`、`REVERSE_SPLIT`，以及未知类型如何拒绝。
2. `HALT_REPORTER`、`VOLUME_ORACLE`、`EMERGENCY_PAUSER` 和业务审批角色的提交边界。
3. 报告是仅链下审计，还是把拆股最小字段写入 Registry/Hook。
4. 是否采用 Token 级就绪/暂停，还是要求同一 `securityId` 下所有 Token 全部就绪后才能恢复交易。
5. 发行方公告与交易所公告冲突时的优先级和暂停依据。
6. 零碎股、最小股单位和 Adapter 舍入导致的法律损益如何处理。
7. `unitEpoch`、ADTV、quota 和 `usedWad` 的精确 ABI 与事件字段。
8. 交易所持续交易但 TSV 暂停时，前端和运营如何展示双状态。

当前部署没有旧 LP 仓位，也没有旧 SIP 日账，因此本文不包含旧仓位交付迁移或旧账本迁移方案。
