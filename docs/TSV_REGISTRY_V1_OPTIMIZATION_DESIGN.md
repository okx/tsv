# TSVRegistryV1 优化方案：Security 聚合操作状态与全局 Emergency Pause

> 历史设计稿。2026-10-12 起，当前报告 ABI 已移除 reporter `sequence` 字段及 Registry 序号检查；本稿中的序号相关设计不再作为当前行为依据。以[编码规格 §7](./CODING_SPEC_V1.md#7-角色报告计量日和额度)为准。

## 1. 目标

本文描述一组只针对 `TSVRegistryV1` 领域模型和接口的优化方案，不包含代码实现。

目标变更：

1. `SecurityStateRecord` 成为 `SecurityRecord` 的成员 `securityState`，删除独立 `marketStates` mapping。
2. `PauseMode` 更名为 `SecurityPauseMode`。
3. `MarketAction` 更名为 `SecurityOperationType`。
4. `MarketStatus` 更名为 `SecurityOperationStatus`。
5. 删除 `EmergencyPauseRecord`、`PauseScope`、`emergencyPauses`、`activePauseCounts`、`nextPauseId` 以及 scoped emergency pause 相关接口，改为一个全局 `bool public emergencyPauseEnable`。
6. `_isOperationAllowed` 简化为只检查全局 emergency pause 和证券级 operation pause。
7. 新增 `SecurityOperationCheckType`，只包含 `LP` 和 `TRADE` 两类。
8. `_isPaused(PauseScope scope, bytes32 target, SecurityPauseMode operation)` 更新为 `_isPaused()`，直接返回 `emergencyPauseEnable`。
9. `isAllowed(PermissionFlag permission, address account)` 更名为 `isSbtAllowed(PermissionFlag permission, address account)`。
10. `_registerPermissionedCurrency` 删除 `PermissionedValidationLib.validatePolicy` 和 `validateInitialInventory` 校验。

## 2. 当前代码事实

当前 `TSVRegistryV1` 的运行态门禁由三类状态共同决定：

| 状态 | 当前位置 | 用途 |
| --- | --- | --- |
| 证券 operation pause | `mapping(bytes32 => SecurityStateRecord) marketStates` | DataInbox 提交证券操作状态报告后，按证券保存 `sequence` 和 `SecurityPauseMode`。目标重构后该记录并入 `SecurityRecord.securityState`。 |
| scoped emergency pause | `emergencyPauses` + `activePauseCounts` | 支持 GLOBAL / SECURITY / TOKEN / POOL 四种范围的人工暂停。 |
| pool lifecycle | `PoolRecord.lifecycle` | 控制 pool 是否 LIST / PAUSE / DELIST。 |

当前 `_isOperationAllowed(poolId, operation)` 会同时检查：

- pool 是否已登记；
- pool lifecycle；
- 两侧资产是否仍准入；
- GLOBAL / POOL / TOKEN / SECURITY emergency pause；
- security operation pause。

本方案保留 pool 登记、lifecycle、资产准入检查，删除 scoped emergency pause，只保留全局 emergency pause 和证券级 operation pause。

## 3. 目标类型模型

### 3.1 枚举命名

| 当前类型 | 目标类型 | 值保持 |
| --- | --- | --- |
| `MarketStatus` | `SecurityOperationStatus` | `OPEN, HALTED` |
| `MarketAction` | `SecurityOperationType` | `HALT, RESUME` |
| `PauseMode` | `SecurityPauseMode` | `NONE, TRADE, LP, ALL` |

建议保持 enum 值顺序不变，降低 DataInbox、测试和链下编码迁移成本。

新增：

| 类型 | 值 | 用途 |
| --- | --- | --- |
| `SecurityOperationCheckType` | `LP, TRADE` | `_isOperationAllowed` 的内部检查类型，避免继续把 pause mode 当作 operation type 传入。 |

`SecurityOperationCheckType` 建议只用于 Registry 内部逻辑，不作为对外 ABI 的必要接口类型。

### 3.2 SecurityRecord 聚合操作状态

目标结构关系：

```text
SecurityRecord
  securityId
  tierId
  listed
  poolIds
  listedPoolCount
  securityState
    sequence
    pauseMode
```

`SecurityStateRecord` 不再通过 `marketStates[securityId]` 独立保存，而是成为 `securities[securityId].securityState`。

目标含义：

| 字段 | 含义 |
| --- | --- |
| `SecurityRecord.securityState.sequence` | 该证券最后接受的 security operation report sequence。 |
| `SecurityRecord.securityState.pauseMode` | 该证券当前操作暂停模式，类型为 `SecurityPauseMode`。 |

## 4. Registry Storage 变更

### 4.1 删除

删除以下状态：

| 状态 | 删除原因 |
| --- | --- |
| `mapping(bytes32 => SecurityStateRecord) marketStates` | security state 改为 `SecurityRecord` 成员。 |
| `mapping(uint256 => EmergencyPauseRecord) public emergencyPauses` | 不再保存逐条 emergency pause 记录。 |
| `mapping(bytes32 => mapping(uint8 => uint256)) activePauseCounts` | 不再支持 scope/target/mode 计数。 |
| `uint256 public nextPauseId` | 不再分配 pause record id。 |

### 4.2 新增

新增：

| 状态 | 含义 |
| --- | --- |
| `bool public emergencyPauseEnable` | 全局 emergency pause 开关；为 true 时阻断普通 trade 和 LP。 |

## 5. 接口变更

### 5.1 Security State 接口

保留业务语义，替换类型名和读取来源：

| 当前接口 | 目标接口                                                                                                     |
| --- |----------------------------------------------------------------------------------------------------------|
| `marketStatus(bytes32 securityId) returns (SecurityOperationStatus)` | `getSecurityStatus(bytes32 securityId) returns (SecurityOperationStatus)`                                   |
| `marketSequence(bytes32 securityId) returns (uint64)` | `getSecuritySequence(bytes32 securityId) returns (uint64)`，读取 `securities[securityId].securityState.sequence` |
| `marketPauseMode(bytes32 securityId) returns (SecurityPauseMode)` | `getSecurityPauseMode(bytes32 securityId) returns (SecurityPauseMode)`                                      |
| `applyMarketStatus(bytes32, MarketAction, PauseMode, uint64, bytes32)` | `applySecurityStatus(bytes32, SecurityOperationType, SecurityPauseMode, uint64, bytes32)`                |
| 原 market-status 变更事件 | `SecurityStatusChanged` event |

`applySecurityStatus` 的状态转移规则保持不变：

- `mode == NONE` 仍应拒绝；
- `sequence <= currentSequence` 仍应拒绝；
- `HALT` 按位增加暂停模式；
- `RESUME` 按位清除暂停模式；
- 没有产生状态变化时仍应拒绝；
- 成功后更新 `SecurityRecord.securityState.sequence` 和 `pauseMode`。

### 5.2 Emergency Pause 接口

删除以下接口：

| 删除接口 | 替代方式 |
| --- | --- |
| `addEmergencyPause(PauseScope scope, bytes32 target, SecurityPauseMode mode, bytes32 reasonCode)` | 使用全局开关接口。 |
| `clearEmergencyPause(uint256 recordId, bytes32 reasonCode)` | 使用全局开关接口。 |
| `activePauseCount(uint8 scope, bytes32 target, uint8 mode)` | 不再支持 scoped pause 计数。 |
| `emergencyPauses(uint256 recordId)` | 不再保存链上 pause record。 |

建议新增一个统一写入口：

| 新接口 | 权限 | 行为 |
| --- | --- | --- |
| `setEmergencyPauseEnable(bool enabled, bytes32 reasonCode)` | `enabled=true` 使用 `EMERGENCY_PAUSER_ROLE`；`enabled=false` 使用 `EMERGENCY_RESUMER_ROLE` | 非零 `reasonCode`，状态未变化时回滚，发事件记录打开或关闭。 |

事件建议：

| 事件 | 字段 |
| --- | --- |
| `EmergencyPauseChanged` | `enabled`、`operator`、`reasonCode` |

链上不再保留逐条暂停记录；审计历史依赖事件。

### 5.3 isPaused / _isPaused

目标行为：

| 接口 | 返回 |
| --- | --- |
| `isPaused()` | `emergencyPauseEnable` |
| `_isPaused()` | `emergencyPauseEnable` |

`_isPaused(PauseScope scope, bytes32 target, SecurityPauseMode operation)` 更新为无参 `_isPaused()`，直接返回 `emergencyPauseEnable`。`isPaused()` 也不再检查 GLOBAL TRADE / GLOBAL LP / GLOBAL ALL 计数，因为这些计数会被删除。

### 5.4 SBT 权限接口

当前 `isAllowed(PermissionFlag permission, address account)` 容易和 vendor `PermissionsAdapter.isSbtAllowed(account, permission)` 混淆。

目标：

| 当前接口 | 目标接口 |
| --- | --- |
| `isAllowed(PermissionFlag permission, address account)` | `isSbtAllowed(PermissionFlag permission, address account)` |

行为保持不变：

- 只接受 `SWAP_ALLOWED` 或 `LIQUIDITY_ALLOWED`；
- 通过 `permissionsOf(account)` 检查 SBT 权限并集；
- SBT 全局 paused 时 `permissionsOf` 返回空权限。

需要同步更新 Router、LPManager、Hook 测试和所有文档中的调用。

## 6. _isOperationAllowed 目标逻辑

### 6.1 保留的前置检查

为避免扩大本次优化的行为面，建议保留当前 `_isOperationAllowed` 的这些检查：

| 检查 | TRADE | LP |
| --- | --- | --- |
| pool 已登记 | 必须 | 必须 |
| pool lifecycle | 必须为 `LIST` | 不能为 `DELIST` |
| 两侧资产仍准入 | 必须 | 必须 |

### 6.2 删除的 pause 检查

删除以下 scoped pause 检查：

- GLOBAL scoped pause；
- POOL scoped pause；
- TOKEN scoped pause；
- SECURITY scoped emergency pause；
- `_isPaused(scope, target, operation)`，替换为无参 `_isPaused()`；
- `_pauseKey(scope, target)`。

### 6.3 新 pause gate

新增 `SecurityOperationCheckType` 后，pause gate 只检查：

| checkType | 返回 false 条件 |
| --- | --- |
| `LP` | `emergencyPauseEnable == true`，或 `SecurityPauseMode` 为 `LP` / `ALL` |
| `TRADE` | `emergencyPauseEnable == true`，或 `SecurityPauseMode` 为 `TRADE` / `ALL` |

推荐拆分为一个内部判断：

```text
_isSecurityOperationAllowed(securityId, checkType)
```

该内部判断只处理全局 emergency pause 和证券 operation pause；pool lifecycle 和资产准入仍由 `_isOperationAllowed(poolId, checkType)` 负责。

### 6.4 对外查询

| 接口 | 内部调用 |
| --- | --- |
| `isTradable(poolId)` | `_isOperationAllowed(poolId, SecurityOperationCheckType.TRADE)` |
| `isLPAllowed(poolId)` | `_isOperationAllowed(poolId, SecurityOperationCheckType.LP)` |

## 7. replaceUnderlyingLegalShareAdapter 的处理建议

当前决策：`replaceUnderlyingLegalShareAdapter` 不要求暂停，可由 `SYMBOL_ADMIN_ROLE` 随时调用；新 Adapter 通过接口及 U 绑定校验后立即用于后续 Swap。历史 `usedWad` 不迁移。若新旧 Adapter 的换算尺度不同，当日累计用量及限额判断会即时体现该变化，这是接受的计量行为。拆并股的 ADTV 硬上限通过目标日 `splitFactor` 调整，Quota 仍作为目标日绝对额度独立上报。

## 8. _registerPermissionedCurrency 准入校验调整

目标删除：

| 当前校验 | 删除后的影响 |
| --- | --- |
| `PermissionedValidationLib.validatePolicy(currency, underlying)` | 不再链上校验 W 的 wrapper/Hook policy；无调用方后库函数和只服务它的 helper 一并删除。 |
| `PermissionedValidationLib.validateInitialInventory(permissionedPoolManager, currency, underlying)` | 不再链上校验首次准入时 W totalSupply、PM W 余额、W 持有 U 余额、PM protocol fee；无调用方后库函数一并删除。 |
| `PermissionedValidationLib.validateLegalShareAdapter(adapter, underlying)` | 保留为库外部入口；Registry 直接调用该方法执行 adapter interface / `poolCurrency()` 绑定校验。 |

保留校验建议：

- `_requireEnvironment()`；
- W 未注册且 security 已 listed；
- `candidateUnderlying(currency)`；
- W/U decimals 一致且不超过 18；
- canonical U 的 `securityId/rawDecimals/legalShareAdapter` 一致；
- `PermissionedValidationLib.validateLegalShareAdapter(registerParam.legalShareAdapter, underlying)`；
- `underlying != legalShareAdapter` 且 `currency != legalShareAdapter`；
- 写入 `underlyings[underlying]` 和 `currencyUnderlying[currency]`。

风险说明：

- wrapper / hook allowlist 不再在 Registry 准入时强制验证，需由链下准入流程或后续实际调用失败来兜底；
- 初始库存异常不再阻断准入，部署/运营清单需要承担这部分检查；
- 相关测试应从“Registry 准入拒绝”改为“链下检查项”或删除。

## 9. DataInbox 和 Report 类型影响

`MarketReport` 的字段类型需要同步改名：

| 字段 | 当前类型 | 目标类型 |
| --- | --- | --- |
| `action` | `SecurityOperationType` | `SecurityOperationType` |
| `mode` | `SecurityPauseMode` | `SecurityPauseMode`     |

`TSVDataInboxV1.submitMarketStatus` 的校验语义保持不变：

- `securityId != 0`；
- `mode != SecurityPauseMode.NONE`；
- `reasonCode != 0`；
- report metadata 校验；
- 调用 Registry 的 `applySecurityStatus`。

## 10. ABI 和存储影响

### 10.1 ABI 影响

会发生 ABI breaking changes：

| 变化 | 影响 |
| --- | --- |
| `isAllowed` 改名为 `isSbtAllowed` | selector 改变，Router/LPManager/前端/脚本必须同步。 |
| 删除 `addEmergencyPause` / `clearEmergencyPause` / `activePauseCount` | 运营脚本和监控必须改用全局 pause 开关。 |
| 新增 `emergencyPauseEnable()` getter | 由 public bool 自动生成。 |
| enum internalType 改名 | ABI JSON 中 `internalType` 会变；链下类型绑定需要重新生成。 |

`SecurityPauseMode`、`SecurityOperationType`、`SecurityOperationStatus` 如果值顺序不变，底层 ABI 编码仍是 `uint8`，但类型绑定和文档必须更新。

### 10.2 Storage 影响

这是 storage layout breaking change：

- `SecurityRecord` 增加 `securityState`；
- 独立 `marketStates` mapping 删除；
- `emergencyPauses`、`activePauseCounts`、`nextPauseId` 删除；
- 新增 `emergencyPauseEnable`。

如果当前代理已经部署，不应直接升级到该布局。需要：

1. 明确当前目标链是否已有生产代理；
2. 若已部署，设计显式迁移版本，不删除旧 slot，只新增字段并提供一次性迁移；
3. 若尚未部署，可以直接按目标模型重排。

## 11. 测试调整清单

需要新增或改造的测试：

| 测试方向 | 覆盖点 |
| --- | --- |
| security state 聚合 | `applySecurityStatus` 更新 `getSecurity(securityId).securityState`，`getSecuritySequence` / `getSecurityPauseMode` 从 SecurityRecord 读取。 |
| enum rename | 所有 MarketReport、Registry market 查询和 helper 使用新类型名。 |
| global emergency pause | `setEmergencyPauseEnable(true)` 后 `isPaused/isTradable/isLPAllowed` 均返回暂停结果；关闭后恢复。 |
| no scoped emergency pause | 删除 GLOBAL/SECURITY/TOKEN/POOL pause 相关测试，或改为 lifecycle / operation pause 测试。 |
| operation gate | TRADE 只被 TRADE/ALL 阻断，LP 只被 LP/ALL 阻断，global emergency pause 阻断两者。 |
| SBT 权限接口 | Router/LPManager 从 `isAllowed` 改为 `isSbtAllowed`。 |
| currency registration | 删除 validatePolicy / validateInitialInventory 相关 revert 测试。 |
| adapter replacement | 验证只有 `emergencyPauseEnable` 或 security operation `ALL` 时允许替换。 |

## 12. 推荐实施顺序

1. 修改 `TSVTypes.sol`：重命名 enum，新增 `SecurityOperationCheckType`，将 `SecurityStateRecord` 放入 `SecurityRecord`，删除 `EmergencyPauseRecord` 和 `PauseScope`。
2. 修改 `TSVReports.sol` 和 `TSVDataInboxV1`：使用 `SecurityOperationType` / `SecurityPauseMode`。
3. 修改 `TSVRegistryV1` storage：删除 `marketStates`、`emergencyPauses`、`activePauseCounts`、`nextPauseId`，新增 `emergencyPauseEnable`。
4. 修改 security state 查询和 `applySecurityStatus`：读写 `securities[securityId].securityState`。
5. 删除 scoped emergency pause 接口和 helper，新增全局 emergency pause 开关接口与事件。
6. 重写 `_isOperationAllowed` pause gate，保留 pool/lifecycle/asset 前置检查。
7. 将 `isAllowed` 改名为 `isSbtAllowed`，同步所有调用方。
8. 删除 `_registerPermissionedCurrency` 中的 `validatePolicy` 和 `validateInitialInventory` 调用；`validateInitialInventory` 无其他调用方后删除库函数本体；`validateLegalShareAdapter` 保留为 Registry 直接调用的库外部入口。
9. 更新接口、事件名、ABI artifact、文档和测试。
10. 跑 Registry、DataInbox、Router、LPManager、Hook 相关测试。

## 13. 结论

该方案会显著简化 Registry 的运行态门禁模型：

- emergency pause 从多 scope、多 record、多 counter 收敛为一个全局 bool；
- security operation pause 成为 Security 聚合根的一部分；
- `_isOperationAllowed` 的 pause 分支从多维计数查询收敛为 “global emergency + security pause mode”；
- SBT 权限接口命名与 vendor permissioned adapter 的 `isAllowed` 区分开；
- W 准入链上校验减少，部分检查转移到链下准入流程。

代价是 ABI 与 storage layout 都会发生破坏性变化，并且不再支持按 pool、token、security 的人工 emergency pause。若这些细粒度运营能力仍是生产需要，应保留 scoped pause；若目标是降低 Registry 复杂度和减少运行态状态面，本方案适合在首次部署前实施。
