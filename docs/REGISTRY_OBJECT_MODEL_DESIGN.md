# TSVRegistryV1 领域对象关系设计

> 历史设计稿。2026-10-12 起，当前报告 ABI 已移除 reporter `sequence` 字段及 Registry 序号检查；本稿中的序号相关设计不再作为当前行为依据。以[编码规格 §7](./CODING_SPEC_V1.md#7-角色报告计量日和额度)为准。

## 1. 背景

当前 `TSVRegistryV1` 中的 `TierPolicyRecord`、`SecurityRecord`、`UnderlyingRecord`、`QuoteTokenRecord`、`PoolRecord`、`MarketStateRecord` 和 `EmergencyPauseRecord` 已统一收敛到 `TSVTypes.sol` 中。它们本质上不是同一层级的配置，而是存在明确的业务归属关系：

- `Tier` 定义证券上市容量和交易额度策略。
- `Security` 表示一只股票或证券，是 permissioned stock 业务的主聚合根。
- `Underlying` 表示某只证券的 canonical stock token，即 U。
- `PermissionedCurrency` 表示 U 的 V4 permissioned adapter，即 W；存储上只需要用 W -> U 准入索引表达。
- `Pool` 表示某只证券的 W/Q V4 池。
- `QuoteToken` 表示全局 quote 资产，不归属于某只证券。
- `MarketState`、`EmergencyPauseRecord`、`PauseCounter` 表示运行态门禁，不属于资产准入配置。

本文只给结构设计方案，不包含代码实现。

本版决策：

- `SecurityRecord` 只保留 `listedPoolCount`，不再保留证券级 `activePoolCount`。
- `QuoteTokenRecord` 不需要保存 quote token address；address 已经是 `quoteTokens[address]` 的 key。
- `EmergencyPauseRecord` 与当前 `EmergencyPause` 结构保持一致，不额外加入关闭侧字段。
- `PauseCounter` 将 `(scope, target)` 归一成 `pauseKey`，再按 `mode` 计数。
- 不新增 `mapping(address currency => PermissionCurrencyRecord) currencies`，也不保留 U -> W 反向索引；只保留 `mapping(address => address) private currencyUnderlying` 作为 W -> U 准入索引。
- 数据结构调整只改变字段归属和索引形态；所有 function 的业务流程、校验顺序和事件语义应严格保持一致。

## 2. 领域层级

推荐关系如下：

```text
Tier
  └── Security 0..n
        ├── Underlying(U) 1..n
        │     └── PermissionedCurrency(W) 1..n
        └── Pool 0..n

QuoteToken(Q)
  └── global asset, referenced by Pool, not owned by Security

Runtime Gates
  ├── MarketState(securityId)
  ├── EmergencyPauseRecord(recordId)
  └── PauseCounter(pauseKey, mode)
```

核心语义：

- `Tier` 是容量和策略层，不直接拥有资产或池子，但拥有多个 `Security` 的上市名额。
- `Security` 是股票业务的聚合根，证券上下架、tier 变更、pool lifecycle 聚合计数都应围绕它表达。
- `Underlying` 是 `Security` 下的 canonical U 配置，保存法律份额转换和 decimals；不维护链上 U -> W 列表。
- `PermissionedCurrency` 是业务概念，不需要独立 storage record；W 到 U 通过 `currencyUnderlying[w]` 反查，U 到 W 枚举需求由 `PermissionedCurrencyRegistered` 事件或链下索引满足。
- `Pool` 永久归属于一个 `Security`，注册时固化 `securityId` 和当时的 `tierId`。
- `QuoteToken` 是全局可用资产，可以被多个证券的池子引用，不应被嵌入任意一个 `Security`。
- `MarketState` 记录 market report 驱动的证券级运行状态。
- `EmergencyPauseRecord` 记录人工安全暂停的历史。
- `PauseCounter` 维护当前仍生效的 pause 聚合计数，用于 O(1) 查询。

## 3. 推荐对象模型

### 3.1 TierRecord

`TierRecord` 表示证券分层策略和容量状态。

概念字段：

```text
TierRecord
  tierBps
  maxListed
  listedCount
  securityIds
```

职责：

- 限制一个 tier 下最多可上市多少证券。
- 保存该 tier 当前 listed security 数量。
- 可选维护 `securityIds`，用于链下枚举和运营审计。

说明：

- `listedCount` 是链上强约束字段。
- `securityIds` 如果维护，建议 append-only 或只用于查询，不建议作为无上限状态变更循环的基础。
- `Security` 的当前 tier 仍应保存在 `SecurityRecord.tierId`，避免只靠数组关系反推。

### 3.2 SecurityRecord

`SecurityRecord` 是 permissioned stock 业务的主聚合根。

概念字段：

```text
SecurityRecord
  tierId
  listed
  underlyings
  poolIds
  listedPoolCount
```

职责：

- 表示证券是否 listed。
- 记录证券所属 tier。
- 聚合该证券下的 U 和历史 pool。
- 维护 pool lifecycle 聚合计数，用于 `delistSecurity` 快速判断。

说明：

- `listedPoolCount` 对应当前方案里的 `listPoolCountBySecurity`，表示生命周期不是 `DELIST` 的 pool 数。
- 不保留 `activePoolCount`：证券下架只依赖 `listedPoolCount == 0`；pool 进入 `DELIST` 前已经要求自身 `tickCount == 0`，因此不需要再维护证券级 tick-active 聚合计数。
- 如果运营需要查询“还有哪些 pool 未清 tick”，应通过 `poolIds` 枚举后查询 `PoolRecord.tickCount`，或由链下索引维护看板，不把该指标作为 Registry 的核心链上聚合字段。
- `poolIds` 建议 append-only，证券下架、重新上市、pool pause 都不删除历史 pool。

### 3.3 UnderlyingRecord

`UnderlyingRecord` 表示某个 canonical underlying U 的证券配置。

概念字段：

```text
UnderlyingRecord
  securityId
  legalShareAdapter
  rawDecimals
```

职责：

- 绑定 U 到 `Security`。
- 固化 U/W 的 raw decimals。
- 保存 canonical legal share adapter。
- 不内嵌 W 列表，也不维护独立 U -> W 反向索引。

说明：

- 当前运行逻辑不读取 U -> W 反向列表；如需枚举某个 U 下已准入 W，推荐通过 `PermissionedCurrencyRegistered` 事件由链下索引完成。
- `securityId` 仍必须保留，便于从 U 直接反查所属 `Security`。

### 3.4 PermissionedCurrency 索引

`PermissionedCurrency` 表示 W adapter 的准入身份，但当前字段只有 `underlying`，不需要再包一层 `PermissionCurrencyRecord`。

推荐索引：

```text
currencyUnderlying[w] = u
```

职责：

- 从 W 反查 U。
- 通过 U 进一步反查 `Security`。
- 避免重复保存 expected owner、raw decimals、underlying 等可以从 U 或 adapter 校验链路得到的信息。

说明：

- 当前 `currencyUnderlying[w]` 已经是 W 的最小身份实现。
- 因此 `mapping(address currency => PermissionCurrencyRecord) currencies` 属于过度包装，可以删除；U -> W 反向列表当前没有链上读取路径，也可以删除。
- 如果未来需要记录 admission 时间、operator、版本号等 W 级元数据，再重新引入专门 record；在当前需求下不需要。

### 3.5 PoolRecord

`PoolRecord` 表示一个已注册 V4 pool 的永久身份。

概念字段：

```text
PoolRecord
  key
  securityId
  tierIdAtRegistration
  lifecycle
  tickCount
  poolSecurityIndex
```

职责：

- 保存完整 `PoolKey`。
- 永久绑定单一 `securityId`。
- 固化注册时的 tier，用于审计和历史解释。
- 保存 pool lifecycle。
- 保存 pool tick/NFT count。
- 维护它在 `SecurityRecord.poolIds` 中的位置。

说明：

- 重构前的 `PoolConfig`、`poolLifecycle`、`poolTickCount`、`poolSecurityIndex` 可以视作 `PoolRecord` 的拆分存储；重构后统一由 `PoolRecord` 表达。
- `tierIdAtRegistration` 不应随 `Security` 后续 tier 变更自动变化；否则历史 pool 审计会变得不稳定。
- 当前业务里一个 pool 只允许一侧是 W，另一侧是 Q，因此一个 pool 只归属于一个 `Security`。

### 3.6 QuoteTokenRecord

`QuoteTokenRecord` 表示全局 quote token。

概念字段：

```text
QuoteTokenRecord
  rawDecimals
  registered
```

职责：

- 表示某个 Q 是否可作为池子的 quote leg。
- 保存 Q 的 decimals。

说明：

- Q 不归属于任何 `Security` 或 `Tier`。
- 一个 Q 可以服务多个 securities 的 pools。
- 因此 Q 只应被 pool 引用，不应被嵌入 `SecurityRecord`。
- `QuoteTokenRecord` 不需要保存 `address` 字段；quote token 地址已经是 `quoteTokens[quote]` 的 mapping key。
- 只有在需要返回“带 key 的分页列表”或链下快照 struct 时，才考虑在返回对象中附带 address；链上 storage record 不需要重复保存。

### 3.7 MarketStateRecord

`MarketStateRecord` 表示某个 security 当前由 DataInbox market report 驱动的市场运行状态。

概念字段：

```text
MarketStateRecord
  sequence
  pauseMode
```

职责：

- 保存该 security 最后接受的 market report sequence。
- 保存该 security 当前市场暂停 mask。
- 支持 `marketStatus(securityId)`、`applyMarketStatus(...)` 和 operation gate 的证券级市场状态判断。

说明：

- 当前 `marketSequence[securityId]` 和 `marketPauseMode[securityId]` 可以收敛为 `MarketStateRecord`。
- `MarketStateRecord` 是运行态对象，不建议直接塞进 `SecurityRecord`。
- `SecurityRecord` 描述证券身份、tier 和 pool 聚合关系；`MarketStateRecord` 描述数据源上报的市场状态。两者按 `securityId` 关联即可。

### 3.8 EmergencyPauseRecord

`EmergencyPauseRecord` 表示一次人工安全暂停的归档记录。

概念字段：

```text
EmergencyPauseRecord
  scope
  target
  mode
  reasonCode
  openedBy
  openedAt
  active
```

职责：

- 记录 pause 的作用域、目标和影响模式。
- 记录打开 pause 的原因、操作者和时间。
- 记录当前是否仍 active。
- 支持通过 `recordId` 查询 pause 打开侧状态；关闭侧原因继续由 `EmergencyPauseClosed` event 表达。

说明：

- `EmergencyPauseRecord` 与当前代码中的 `EmergencyPause` 保持一致即可。
- 不额外补充 `closeReasonCode`、`closedBy`、`closedAt`，避免增加 storage 写入和布局复杂度。
- 清除 pause 时仍通过 `EmergencyPauseClosed(recordId, reasonCode)` event 记录关闭原因。

### 3.9 PauseCounter

`PauseCounter` 表示当前生效 pause 的聚合索引。

概念字段：

```text
PauseCounter
  pauseKey
  mode
  count
```

职责：

- 支持 `isPaused()`、`isTradable(poolId)`、`isLPAllowed(poolId)` 的 O(1) pause 判断。
- 在 `addEmergencyPause` 时递增。
- 在 `clearEmergencyPause` 时递减。

说明：

- 将 `(scope, target)` 归一成 `pauseKey = keccak256(abi.encode(scope, target))`。
- 推荐使用 `activePauseCount[pauseKey][mode]`，比三层 mapping 更容易封装和传递。
- helper 必须保证 `scope == GLOBAL` 时 target 为 0，`scope != GLOBAL` 时 target 非 0，避免不同语义生成相同或无效 key。
- `PauseMode.ALL` 应继续作为覆盖 TRADE 和 LP 的聚合模式，在查询时和具体 mode 一并检查。

## 4. 聚合根和所有权边界

推荐聚合根：

```text
Tier       controls capacity for Security
Security   owns Underlying and Pool relationship
Underlying is referenced by PermissionedCurrency through currencyUnderlying
QuoteToken is global asset registry
Pool       is directly indexed by poolId
MarketState is runtime state keyed by securityId
EmergencyPauseRecord is audit record keyed by recordId
PauseCounter is active runtime gate index
```

具体边界：

- `Tier` 不直接管理 pool、underlying、currency。
- `Security` 管理证券级生命周期和所有 pool 聚合状态。
- `Underlying` 管理 U 级法律份额转换和 decimals；W 身份由 `currencyUnderlying` 准入索引维护。
- `Pool` 管理自己的 lifecycle 和 tick count；tick count 变化不再同步证券级 active 聚合计数。
- `QuoteToken` 独立注册，池子只引用它。
- `MarketState` 管理 DataInbox 上报的证券级市场暂停状态。
- `EmergencyPauseRecord` 管理人工安全暂停的历史归档。
- `PauseCounter` 管理当前生效的人工安全暂停聚合索引。

## 5. Storage 组织建议

不建议把所有对象直接深度嵌套成一个大 struct。Solidity 更适合主 mapping + 必要索引：

```text
mapping(uint8 tierId => TierRecord) tiers;
mapping(bytes32 securityId => SecurityRecord) securities;
mapping(address underlying => UnderlyingRecord) underlyings;
mapping(address currency => address underlying) currencyUnderlying;
mapping(bytes32 poolId => PoolRecord) pools;
mapping(address quote => QuoteTokenRecord) quoteTokens;

mapping(bytes32 securityId => MarketStateRecord) marketStates;
mapping(uint256 recordId => EmergencyPauseRecord) emergencyPauseRecords;
mapping(bytes32 pauseKey => mapping(uint8 mode => uint256 count)) activePauseCount;
```

原因：

- pool、currency、underlying 都有高频直接查询路径。
- 深层数组内查找成本高，不适合链上状态变更。
- 外部 getter 对嵌套动态数组不友好。
- 审计时直接索引更容易验证不变量。

当前平铺 mapping 可以逐步收敛为上述对象模型，但不需要一次性改变所有 storage layout。

## 6. 当前字段到目标对象的映射

| 当前字段 | 目标归属 |
| --- | --- |
| `tiers[tierId]` | `TierRecord` |
| `securities[securityId]` | `SecurityRecord` |
| `underlyings[u]` | `UnderlyingRecord` |
| `currencyUnderlying[w]` | W -> U 准入索引 |
| `pools[poolId]` | `PoolRecord` |
| `poolLifecycle[poolId]` | `PoolRecord.lifecycle` |
| `poolTickCount[poolId]` | `PoolRecord.tickCount` |
| `poolsBySecurity[securityId]` | `SecurityRecord.poolIds` |
| `poolSecurityIndex[poolId]` | `PoolRecord.poolSecurityIndex` |
| `listPoolCountBySecurity[securityId]` | `SecurityRecord.listedPoolCount` |
| `quoteTokens[q]` | `QuoteTokenRecord` |
| `marketSequence[securityId]` | `MarketStateRecord.sequence` |
| `marketPauseMode[securityId]` | `MarketStateRecord.pauseMode` |
| `emergencyPauses[recordId]` | `EmergencyPauseRecord` |
| `activePauseCount[pauseKey][mode]` | `PauseCounter.count` |
| `nextPauseId` | Emergency pause record ID allocator |

## 7. 关键不变量

### 7.1 Tier 不变量

- `tiers[tierId].listedCount <= tiers[tierId].maxListed`。
- `SecurityRecord.listed == true` 的证券必须占用且只占用一个 tier slot。
- `SecurityRecord.tierId` 变更时，旧 tier `listedCount` 递减，新 tier `listedCount` 递增。
- 已注册 pool 的 `tierIdAtRegistration` 不随证券 tier 变更而修改。

### 7.2 Security 不变量

- 每个 listed security 必须有非零 `tierId`。
- `delistSecurity(securityId)` 只能在 `SecurityRecord.listedPoolCount == 0` 时执行。
- `SecurityRecord.poolIds` append-only，不因 pool delist、security delist 或 pause 删除历史记录。
- `SecurityRecord` 不维护 `activePoolCount`；`updatePoolTickCount` 只更新 `PoolRecord.tickCount`，不再同步证券级 active 聚合计数。

### 7.3 Underlying/Currency 不变量

- 每个 U 只能归属一个 `Security`。
- 每个 W 只能归属一个 U。
- `currencyUnderlying[w] != address(0)` 表示 W 已准入。
- U 不能同时是 quote token、W adapter 或系统组件。
- W 必须是 Factory verified adapter，且 adapter 内部指向的 permissioned token 必须等于 U。

### 7.4 Pool 不变量

- 每个 pool 必须且只能包含一个已准入 W 和一个已准入 Q。
- 每个 pool 永久归属一个 `securityId`。
- `PoolLifecycle.DELIST` 前必须要求 `PoolRecord.tickCount == 0`。
- `PoolLifecycle.PAUSE` 阻断 swap，但普通 LP 继续进入后续门禁。
- `PoolLifecycle.LIST` 允许 swap 和普通 LP 继续进入后续门禁。

### 7.5 QuoteToken 不变量

- Q 是全局资产，不属于任何 security。
- Q 不能同时是 U、W adapter 或系统组件。
- Q 的 decimals 在注册时固化，恢复校验时应保持一致。

### 7.6 MarketState 不变量

- `MarketStateRecord.sequence` 只能由绑定的 DataInbox 递增更新。
- `applyMarketStatus` 必须拒绝小于或等于当前 sequence 的 report。
- `MarketStateRecord.pauseMode == PauseMode.NONE` 表示该 security 的市场状态为 OPEN。
- `MarketStateRecord.pauseMode != PauseMode.NONE` 表示该 security 的市场状态为 HALTED。
- Market pause 只表达 DataInbox 上报的证券级状态，不替代 emergency pause。

### 7.7 EmergencyPause 不变量

- `recordId` 单调递增分配，不复用。
- active record 只能关闭一次。
- `scope == GLOBAL` 时，`target` 必须为 0。
- `scope != GLOBAL` 时，`target` 必须非 0。
- `mode` 不能为 `PauseMode.NONE`。
- 打开 pause 时对应 `PauseCounter` 递增；关闭 active pause 时对应 `PauseCounter` 递减。

### 7.8 PauseCounter 不变量

- `PauseCounter.count` 表示当前仍 active 的 pause record 数量，不是历史累计数量。
- `pauseKey` 必须由 `(scope, target)` 唯一派生；业务逻辑不得直接拼装任意 bytes32 作为 pause key。
- `PauseMode.ALL` 查询应覆盖 TRADE 和 LP。
- `isPaused()` 只检查 GLOBAL TRADE、GLOBAL LP 和 GLOBAL ALL。
- `isTradable(poolId)` 需要同时检查 GLOBAL、POOL、TOKEN、SECURITY emergency pause，以及 security 的 `MarketStateRecord.pauseMode`。
- `isLPAllowed(poolId)` 和 `isTradable(poolId)` 类似，但使用 LP operation gate。

## 8. 操作归属建议

### Tier 操作

- `setTierPolicy`
- `setSecurityTier`
- tier capacity check

### Security 操作

- `registerPermissionedCurrency` 中首次 security listing
- `relistSecurity`
- `delistSecurity`
- `batchUpdatePoolLifeCycle` 针对某个 security 的批量生命周期变更可以作为后续扩展

### Underlying 操作

- 首次绑定 U
- `replaceUnderlyingLegalShareAdapter`
- U/W decimals 和 policy recovery check

### Currency 操作

- W admission
- W 到 U 反查
- W provenance recovery check

### Pool 操作

- `registerPool`
- `updatePoolLifeCycle`
- `batchUpdatePoolLifeCycle`
- `updatePoolTickCount`
- `getPoolLifeCycle`

说明：

- `updatePoolTickCount` 的职责只是在 `PoolRecord.tickCount` 上应用 signed delta。
- 它不再维护 `SecurityRecord.activePoolCount`，因为该字段不再存在。
- `PoolLifecycle.DELIST` 前的 `tickCount == 0` 校验仍保留，确保 `listedPoolCount == 0` 能作为 security 下架的最终门禁。

### QuoteToken 操作

- `registerQuoteToken`
- quote identity recovery check

### MarketState 操作

- `marketStatus`
- `applyMarketStatus`
- market report sequence check
- market pause mask update

### EmergencyPause 操作

- `addEmergencyPause`
- `clearEmergencyPause`
- emergency pause record query

### PauseCounter 操作

- active pause count increment
- active pause count decrement
- `_isPaused(scope, target, operation)`
- `_operationPaused(poolId, operation)` 或等价 operation gate helper

## 9. Function 流程保持约束

数据结构收敛只调整字段归属和索引表达，所有 function 的业务流程必须严格保持一致：

- `registerPermissionedCurrency`：仍按环境绑定、security/tier、W/U 身份、decimals、legalShareAdapter、policy、首次库存、写入 U/W 映射的顺序执行。
- `registerPool`：仍由 LP Manager 调用，校验 PoolKey、资产准入、单一 stock security、security listed、pool 未注册后写入 pool，并追加到 `SecurityRecord.poolIds` / `poolsBySecurity`。
- `updatePoolLifeCycle` / `batchUpdatePoolLifeCycle`：仍只按 poolId 更新 lifecycle；切到 `DELIST` 前必须要求 `PoolRecord.tickCount == 0`；只维护 `listedPoolCount`。
- `updatePoolTickCount`：仍由 LP Manager 调用并从完整 PoolKey 派生 poolId；只更新 `PoolRecord.tickCount`，不得改变 `listedPoolCount` 或 pool lifecycle。
- `delistSecurity`：仍只在 security listed 且 `listedPoolCount == 0` 时成功，不遍历 `poolIds`，不自动修改 pool lifecycle。
- `addEmergencyPause` / `clearEmergencyPause`：仍分配 `recordId`、写入或关闭 `EmergencyPauseRecord`、维护 `PauseCounter`；只是 counter 索引从 `(scope,target,mode)` 三层 mapping 收敛为 `(pauseKey,mode)`。
- `isTradable` / `isLPAllowed` / `isPaused`：仍按 lifecycle、资产准入、GLOBAL/POOL/TOKEN/SECURITY emergency pause、market pause 的原有门禁组合判断，不能因数据结构变化改变允许/拒绝结果。

## 10. 推荐演进路径

### 阶段一：文档和命名收敛

先在文档和注释中统一领域名：

- `TierPolicyRecord` -> tier record / tier policy
- 旧 `SecurityConfig` -> 已删除，由 `SecurityRecord` 替代
- `UnderlyingRecord` -> 底层资产记录
- `currencyUnderlying` -> permissioned currency admission index
- `QuoteTokenRecord` -> 报价资产记录
- 旧 `PoolConfig` -> 已删除，由 `PoolRecord` 替代

这一阶段不要求改 storage layout。

### 阶段二：聚合计数字段归属收敛

将语义上属于 security 的计数统一解释为 `SecurityRecord` 的字段：

- `listPoolCountBySecurity`
- `poolsBySecurity`

如果要改代码，可以逐步迁移为 `securities[securityId].listedPoolCount`、`securities[securityId].poolIds`。

 `updatePoolTickCount` 维护 pool 自身 `tickCount`。

### 阶段三：Underlying 附属字段收敛

将 U 级字段统一表达为 `UnderlyingRecord` + W -> U 准入索引：

- `currencyUnderlying`

`UnderlyingRecord` 保存 U 的 `legalShareAdapter` 和 `rawDecimals`；`currencyUnderlying` 继续作为独立 W -> U 准入索引。不嵌入 W 列表，不额外引入 `PermissionCurrencyRecord`，也不维护 U -> W 反向列表。

### 阶段四：Pool 附属字段收敛

将 pool 级字段统一收敛到 `PoolRecord`：

- `poolLifecycle`
- `poolTickCount`
- `poolSecurityIndex`

需要注意：如果这是 upgradeable proxy，任何 storage layout 收敛都必须经过 layout 兼容性设计，不能直接重排或删除已有 mapping。

### 阶段五：MarketState 运行态字段收敛

将 security 级市场运行态统一收敛到 `MarketStateRecord`：

- `marketSequence`
- `marketPauseMode`

推荐目标：

```text
mapping(bytes32 securityId => MarketStateRecord) marketStates;
```

这样 `applyMarketStatus` 可以围绕一个 storage record 更新 sequence 和 pause mode，语义比两个平行 mapping 更清晰。

### 阶段六：EmergencyPause 命名收敛

将 `EmergencyPause` 命名为 `EmergencyPauseRecord`，字段与当前 `EmergencyPause` 保持一致：

- `scope`
- `target`
- `mode`
- `reasonCode`
- `openedBy`
- `openedAt`
- `active`

关闭原因继续通过 `EmergencyPauseClosed(recordId, reasonCode)` event 审计，不新增关闭侧 storage 字段。

### 阶段七：PauseCounter 索引封装

将当前三层 mapping 的 pause count 查询封装为统一 helper：

```text
_pauseKey(scope, target)
_activePauseCount(pauseKey, mode)
_isPaused(scope, target, operation)
```

可选迁移目标：

```text
mapping(bytes32 pauseKey => mapping(uint8 mode => uint256 count)) activePauseCount;
```

这一步主要提升可读性，不改变业务语义。

## 11. 结论

推荐采用“Tier 管容量，Security 做聚合根，Underlying 管 U，currencyUnderlying 管 W -> U 准入索引，Pool 独立索引，QuoteToken 全局注册；MarketState、EmergencyPauseRecord、PauseCounter 单独表达运行态门禁”的模型。

这能让当前散落的配置关系变成清晰的业务对象关系，同时保留 Solidity 适合的直接 mapping 查询方式。实际代码实现时，不建议深度嵌套所有 struct，而应通过主 mapping、append-only 索引和聚合计数维护对象关系。
