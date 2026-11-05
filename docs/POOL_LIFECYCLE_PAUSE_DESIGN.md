# TSVRegistryV1 Pool Lifecycle 与协议级 Pause 改造设计

> **历史设计稿，不描述当前 ABI。** 本文记录过渡期目标，包含被后续实现替换的接口与流程。当前状态、枚举和操作门禁以 [`src/v1/core/TSVRegistryV1.sol`](../src/v1/core/TSVRegistryV1.sol)、[`src/v1/types/TSVTypes.sol`](../src/v1/types/TSVTypes.sol) 及 [`SYSTEMS_OVERVIEW.md`](./SYSTEMS_OVERVIEW.md) 为准；当前没有 DataInbox、市场报告或可配置日切。

## 1. 目标

本文定义对 `TSVRegistryV1` 的接口和状态改造：

- 删除 `admitPermissionedSecurity(uint8 tierId, PermissionedAdmission admission)`。
- 优化 `registerPermissionedCurrency`，承接新证券首个 W 准入能力，避免保留两个股票准入入口。
- 删除 `PermissionedCurrencyConfig` 和 `PermissionedAdmission.expectedOwner`，Registry 不再保存或校验 W 的 expected owner。
- `_registerPermissionedCurrency` 不再依赖外部传入 rawDecimals 或 owner；需要固化的 underlying、rawDecimals 和 adapter 绑定关系都从对应合约读取后写入。
- 使用独立 `currencyUnderlying[w]` 索引保存 permissioned stock W 到 canonical underlying U 的关系，`UnderlyingRecord` 继续按 U 保存证券级 canonical 配置。
- 保持现有 `registerPool(PoolKey calldata key)` 接口不变。
- 注册 Pool 时由 Registry 内部推导股票 `securityId`，并固化该证券当前 `tierId`。
- 增加 Pool 生命周期查询与更新、Pool Tick 数量检查入口，以及协议级全局 Pause 查询。
- 调整 `delistSecurity(securityId)` 下架策略：只有该证券关联的所有 pool 生命周期都为 `DELIST` 时，才允许将证券下架；进入 `DELIST` 前仍要求对应 pool 的 `poolTickCount == 0`。

本方案区分两类 pause：

- 协议级全局 Pause：由 `isPaused()` 表达，影响整个协议的普通 swap 和普通 LP。
- Pool 业务生命周期 PAUSE：由 `updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE)` 设置，只阻断该 pool 的 swap，普通 LP 继续进入后续门禁。

## 2. Registry 接口变更

### 2.1 删除接口

```solidity
function admitPermissionedSecurity(uint8 tierId, PermissionedAdmission calldata admission) external;
```

删除原因：

- 该接口与 `registerPermissionedCurrency` 都在处理 W/U/证券准入，入口重复。
- 删除后，证券首次上市和首个 W 准入应由优化后的 `registerPermissionedCurrency` 原子完成。
- 避免出现“证券已上市但首个 W 准入失败”的半成品业务理解。

### 2.2 保留并优化股票 W 准入接口

推荐将现有：

```solidity
function registerPermissionedCurrency(PermissionedAdmission calldata admission) external;
```

优化为：

```solidity
function registerPermissionedCurrency(PermissionedAdmission calldata admission, uint8 tierId) external;
```

语义：

- 当 `admission.securityId` 从未登记时：该调用同时完成证券上市、占用 tier 名额、登记 U、登记首个 W。
- 当 `admission.securityId` 已登记且已上市时：该调用只为已有证券新增 W，`tierId` 必须与证券已保存的 tier 一致。
- 当 `admission.securityId` 已登记但已下架时：拒绝新增 W，不通过该接口隐式重新上市。

这样可以删除 `admitPermissionedSecurity`，并保留“证券 + 首个 W 原子准入”的能力。

### 2.3 删除 expectedOwner 相关接口和字段

`PermissionedAdmission` 同步删除 `expectedOwner`：

```solidity
struct PermissionedAdmission {
    address currency;
    bytes32 securityId;
    address legalShareAdapter;
}
```

`PermissionedAdmission` 只保留无法从链上 adapter 自发现的治理输入：

- `currency`：待准入的 permissioned stock W。
- `securityId`：业务证券 ID。
- `legalShareAdapter`：经运营审核的法律份额转换 adapter 地址；Registry 会从该 adapter 读取 `poolCurrency()` 做绑定校验。

不再通过 admission 传入或校验：

- `rawDecimals`：从 W/U token 的 `decimals()` 读取并固化。
- `owner` / `expectedOwner`：不读取、不校验、不保存。

删除以下 Registry 接口和事件：

```solidity
function updatePermissionedExpectedOwner(address w, address newOwner) external;
event PermissionedExpectedOwnerChanged(address indexed currency, address oldOwner, address newOwner);
```

同步删除以下 owner approval 接口和事件：

```solidity
function setPermissionedOwnerApproval(address owner, bool approved) external;
function isPermissionedOwnerApproved(address owner) external view returns (bool);
event PermissionedOwnerApprovalChanged(address indexed owner, bool approved);
```

语义调整：

- Registry 不再存储 W 的 `expectedOwner`。
- Registry 不再提供 expected owner 更新入口。
- W owner 变更不再需要通过 Registry 暂停后改写 expected owner；owner 合规性改由 W/issuer 自身治理或外部运维流程保证。
- 准入校验不再读取或校验 W owner。
- 准入校验仍应验证 W 是 Factory 已验证的 PermissionsAdapter、W 指向的 U 正确、W 允许 Router 和 Hook、U/legalShareAdapter/decimals 一致、首次库存检查通过。
- rawDecimals 不作为 `PermissionedAdmission` 字段传入；Registry 从 W/U token 合约读取 decimals，并将通过校验的 canonical decimals 固化到 `UnderlyingRecord.rawDecimals`。

### 2.4 Pool 注册接口

Pool 注册接口保持现有签名：

```solidity
function registerPool(PoolKey calldata key) external returns (bytes32 poolId);
```

说明：

- `key` 沿用现有完整 V4 PoolKey。
- `securityId` 不作为接口参数传入，继续由 Registry 根据 `key.currency0/key.currency1` 的 W/Q 配置推导。
- `tierId` 不作为接口参数传入，由 Registry 根据推导出的 `securityId` 读取 `securities[securityId].tierId`。
- 注册成功后，Pool 配置中应保存该股票 `securityId` 和 `tierId`，后续查询和门禁不再重复从资产映射里临时拼装 tier。

### 2.5 新增接口

本方案只新增以下接口：

```solidity
function getCurrencyUnderlying(address w) external view returns (address underlying);
function getPoolLifeCycle(bytes32 poolId) external view returns (PoolLifecycle lifecycle);
function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle);
function listPoolCountBySecurity(bytes32 securityId) external view returns (uint32 count);
function activePoolCountBySecurity(bytes32 securityId) external view returns (uint32 count);
function poolTickCount(bytes32 poolId) external view returns (uint256 count);
function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle) external returns (bool);
function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle)
    external
    returns (uint256 changedCount);
function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool);
function isPaused() external view returns (bool);
```

`getCurrencyUnderlying(w)` 替代原 `getCurrency(w)` 返回 `PermissionedCurrencyConfig` 的查询方式，因为 `PermissionedCurrencyConfig` 将被删除。

同步删除旧查询接口：

```solidity
function getCurrency(address w) external view returns (PermissionedCurrencyConfig memory);
```

### 2.6 delistSecurity 约束变更

现有证券下架接口保持签名不变：

```solidity
function delistSecurity(bytes32 securityId) external;
```

语义调整：

- `delistSecurity(securityId)` 不再负责批量修改 pool 生命周期。
- 调用前，必须确保该证券下所有 pool 生命周期都已经切到 `DELIST`。
- Registry 必须校验 `listPoolCountBySecurity[securityId] == 0`，否则拒绝下架；该计数表示生命周期不是 `DELIST` 的 pool 数量。
- 如需在证券下架前显式关闭 pool 业务生命周期，管理员可通过 `updatePoolLifeCycle(poolId, PoolLifecycle.DELIST)` 或
  `batchUpdatePoolLifeCycle(poolIds, PoolLifecycle.DELIST)` 设置；设置 `DELIST` 时要求对应 pool 的 `poolTickCount == 0`。
- 证券下架后，历史 pool 仍保留在 `pools` 和 `poolsBySecurity` 中，强退、退出和审计查询仍可识别其历史身份。
- `relistSecurity(securityId)` 只恢复证券上市状态，不自动恢复历史 pool 生命周期；如需重新开放 pool，必须显式调用 `updatePoolLifeCycle(poolId, PoolLifecycle.LIST)` 或 `PAUSE`。

## 3. Pool 生命周期

```solidity
/// @notice TSV 池在完成注册后的显式生命周期状态。
/// @dev DELIST 是未注册池的默认枚举值，但未注册池必须通过内部 pool 记录区分。
///      LIST 表示该池处于上市状态。PAUSE 是业务层标记，不等同于协议级全局 Pause；
///      按当前策略，PAUSE 可以继续通过普通 LP 门禁，但不能通过 swap 门禁。
///      DELIST 表示池仍保留历史身份，但普通 swap 和普通 LP 操作都会被阻断。
enum PoolLifecycle {
    DELIST, // 普通 swap 和普通 LP 都不能做。
    LIST,   // 普通 swap 和普通 LP 可以继续进入后续门禁。
    PAUSE   // 业务标记状态；普通 LP 可以继续进入后续门禁，swap 被阻断。
}
```

`PoolLifecycle.PAUSE` 不是协议级全局 Pause。协议级全局 Pause 只由 `isPaused()` 查询结果表达。

## 4. 存储改造

### 4.1 Security / W / U

现有 `SecurityConfig` 可以继续保存证券的全局上市状态和 tier：

```solidity
mapping(bytes32 => SecurityConfig) private securities;
```

优化后的 `registerPermissionedCurrency(admission, tierId)` 负责在新证券首次出现时写入：

```solidity
securities[admission.securityId] = SecurityConfig(admission.securityId, tierId, true);
```

并在后续新增同证券 W 时复用已有证券配置。

`PermissionedCurrencyConfig` 删除后，不再为 W 保存 struct。W 到 U 的关系使用独立索引保存：

```solidity
/// @notice permissioned stock W 对应的 canonical underlying U。
/// @dev 0 表示 W 未注册。该索引是 Registry 从 W 判断其股票身份、
///      再通过 U 找到 securityId 的最小状态。
mapping(address w => address underlying) private currencyUnderlying;
```

`UnderlyingRecord` 继续按 U 保存 canonical 配置，不需要额外保存 `underlying` 字段，因为 mapping key 本身就是 U：

```solidity
/// @notice canonical underlying U 的证券、精度和法律份额转换配置。
struct UnderlyingRecord {
    bytes32 securityId;
    address legalShareAdapter;
    uint8 rawDecimals;
}

mapping(address underlying => UnderlyingRecord config) private underlyings;
```

对应查询接口：

```solidity
function getCurrencyUnderlying(address w) external view returns (address underlying);
function getUnderlying(address u) external view returns (UnderlyingRecord memory);
```

说明：

- `currencyUnderlying[w] != address(0)` 表示 W 已注册。
- `underlyings[u].securityId != 0` 表示 U 已绑定 canonical security。
- 从 W 推导证券时，先读 `u = currencyUnderlying[w]`，再读 `underlyings[u].securityId`。
- 删除 `getCurrency(w) returns (PermissionedCurrencyConfig)`，调用方改用 `getCurrencyUnderlying(w)`。
- 删除 `PermissionedAdmission.expectedOwner` 后，Registry 不再保存 W owner 的镜像状态。
- `underlyings[u].rawDecimals` 必须由 Registry 从 W/U token 合约读取后固化，不由 admission 传入。
- `underlyings[u].legalShareAdapter` 保存的是经过验证的 legal-share adapter 地址；Registry 必须从该 adapter 合约读取 `poolCurrency()`，确认其绑定的 pool Currency 与 U 一致。

### 4.2 Pool 配置

Pool 配置收敛为只保存完整 PoolKey、股票 security 和 tier：

```solidity
struct PoolConfig {
    PoolKey key;
    bytes32 securityId;
    uint8 tierId;
}
```

`registerPool(key)` 必须在注册时固化：

- `securityId`：从 W/Q 资产配置中推导出的唯一非零 securityId。
- `tierId`：从 `securities[securityId].tierId` 内部读取。

### 4.3 Pool 反向索引、生命周期与 Tick 数量

```solidity
/// @notice 按单一股票 securityId 分组保存的历史池 ID 列表。
/// @dev 当前 TSV 池准入要求一侧是 permissioned stock，另一侧是 quote token，
///      因此每个池只归属于一个非零 securityId。该数组建议只追加不删除：
///      证券下架、池停用、证券重新上市和暂停状态变化都不应移除历史 poolId。
///      该索引用于链下运营枚举、迁移和审计查询，不应用于无上限的状态变更循环。
mapping(bytes32 securityId => bytes32[] poolIds) private poolsBySecurity;

/// @notice poolId 在 `poolsBySecurity[securityIdOfPool]` 中的 1-based 下标。
/// @dev 0 表示该 pool 尚未写入反向索引。实际保存值为 `index + 1`，
///      用来区分数组下标 0 和“不存在”。在推荐的 append-only 模型下，
///      该 mapping 主要用于存在性保护和迁移一致性检查；如果未来支持删除，
///      需要和数组一起按 swap-and-pop 方式同步更新。
mapping(bytes32 poolId => uint256 indexPlusOne) private poolSecurityIndexPlusOne;

/// @notice 每个已注册池的显式生命周期状态。
/// @dev registerPool 将新池初始化为 LIST。
mapping(bytes32 poolId => PoolLifecycle lifecycle) public poolLifecycle;

/// @notice 某个 securityId 下生命周期不是 DELIST 的池数量。
/// @dev 这是 O(1) 聚合计数，用于在 `delistSecurity` 中快速判断
///      “该证券下所有池都已经完成生命周期下架”。registerPool 初始化为 LIST 时递增；
///      `updatePoolLifeCycle` 从 DELIST 切回 LIST/PAUSE 时递增，从 LIST/PAUSE 切到 DELIST 时递减。
///      该计数只表达运营生命周期，不表达 pool 内 Tick/NFT 或流动性数量。
mapping(bytes32 securityId => uint32 listCount) public listPoolCountBySecurity;

/// @notice 某个 securityId 下 `poolTickCount > 0` 的池数量。
/// @dev 这是 O(1) 聚合计数，只由 `updatePoolTickCount` 根据 `poolTickCount`
///      的 0/非 0 迁移维护。registerPool 初始化时 tickCount 为 0，因此不递增该计数；
///      生命周期变更不维护该计数。
mapping(bytes32 securityId => uint32 activeCount) public activePoolCountBySecurity;

/// @notice 每个 pool 当前绑定的 Tick 数量。
/// @dev 该数量只表示绑定 Tick 个数，不表示池内流动性大小。
mapping(bytes32 poolId => uint256 tickCount) public poolTickCount;
```

## 5. registerPermissionedCurrency 优化流程

```solidity
function registerPermissionedCurrency(PermissionedAdmission calldata admission, uint8 tierId)
    external
    onlyRole(SYMBOL_ADMIN_ROLE)
{
    // 伪代码：证券 tier 处理完成后，调用 _registerPermissionedCurrency(admission)。
}
```

推荐流程：

1. 校验 `admission.securityId != 0`。
2. 读取 `SecurityConfig storage security = securities[admission.securityId]`。
3. 如果证券不存在：
   - 校验 `tierId` 已配置且有名额。
   - 调用 `_takeTierSlot(tierId)`。
   - 写入 `SecurityConfig(admission.securityId, tierId, true)`。
   - 发出 `SecurityListed(admission.securityId, tierId)`。
   - 继续执行 W/U 准入。
4. 如果证券已存在：
   - 要求 `security.listed == true`。
   - 要求 `security.tierId == tierId`。
   - 不重复占用 tier 名额。
   - 继续执行 W/U 准入。
5. 执行 `_registerPermissionedCurrency(admission)` 的 W/U 校验与写入。

`_registerPermissionedCurrency(admission)` 推荐流程：

1. 校验环境已绑定。
2. 读取 `currency = admission.currency`，要求 `currencyUnderlying[currency] == address(0)`，即 W 未注册。
3. 从 Factory 和 W adapter 读取并交叉校验 underlying：
   - `factoryUnderlying = IPermissionsAdapterFactory.verifiedPermissionsAdapterOf(currency)`。
   - `adapterUnderlying = IPermissionsAdapter(currency).PERMISSIONED_TOKEN()`。
   - 两者都必须非零且相等。
   - `IPermissionsAdapter(currency).POOL_MANAGER()` 必须等于 Registry 绑定的 `permissionedPoolManager`。
4. 从 W adapter 读取 policy 绑定关系：
   - `allowListChecker()` 必须是实现 `IAllowlistChecker` 的合约。
   - `allowedWrappers(router) == true`。
   - `allowedHooks(hook) == true`。
   - 不读取、不校验、不存储 `owner()`。
5. 从 W/U token 合约读取 decimals：
   - `wDecimals = IERC20Metadata(currency).decimals()`。
   - `uDecimals = IERC20Metadata(underlying).decimals()`。
   - 两者必须相等，且不得大于 18。
   - `rawDecimals = uDecimals`，后续写入 `UnderlyingRecord.rawDecimals`。
6. 校验 legal-share adapter：
   - `admission.legalShareAdapter` 必须是合约。
   - 该合约必须支持 `IDirectLegalShareAdapter`。
   - 从该 adapter 读取 `poolCurrency()`，必须等于 `underlying`。
   - 通过校验后，`legalShareAdapter = admission.legalShareAdapter` 作为 canonical adapter 写入。
7. 校验 W/U 资产身份：
   - W 和 U 不能相同。
   - W/U 不能是系统组件。
   - W/U 不能已注册为 quote token。
   - W 不能已绑定为 canonical underlying。
   - U 不能已注册为 W。
   - U 不能是 Factory 已知 permissions adapter。
8. 执行首次库存检查：
   - W totalSupply 必须为 0。
   - PoolManager 对 W 的余额必须为 0。
   - W 合约持有的 U 余额必须大于 0。
   - PoolManager 对 W 的 protocol fee 必须为 0。
10. 如果 U 首次出现，写入：
    `underlyings[underlying] = UnderlyingRecord(admission.securityId, legalShareAdapter, rawDecimals)`，
    并发出 `UnderlyingBound`。
11. 如果 U 已存在，要求已有 `securityId/rawDecimals/legalShareAdapter` 与本次从合约读取和校验得到的值完全一致。
12. 写入 `currencyUnderlying[currency] = underlying`，并将 W 追加到 `currenciesByUnderlying[underlying]`。
13. 发出 `PermissionedCurrencyRegistered(currency, underlying, admission.securityId)`。
14. 任一校验失败时，证券写入、tier 计数和 W/U 写入全部回滚。

这个优化保留了原 `admitPermissionedSecurity` 的原子性，但只暴露一个股票 W 准入入口。

## 6. registerPool 优化流程

`registerPool(key)` 推荐流程：

1. 校验调用者必须是 `lpManager`。
2. 校验 `key.hooks == hook`。
3. 校验 `currency0/currency1` 非零且按地址排序。
4. 校验 fee、tickSpacing、资产准入等现有 PoolKey 条件。
5. 从 `currency0/currency1` 读取 `currencyUnderlying[currency]` 或 quote token 配置。
6. 对 W 侧按 `underlyings[currencyUnderlying[currency]].securityId` 推导 `securityId0/securityId1`；Q 侧 securityId 为 0。
7. 要求恰好一侧是股票，即 `(securityId0 == 0) != (securityId1 == 0)`。
8. 推导 `securityId = securityId0 == 0 ? securityId1 : securityId0`。
9. 校验 `securities[securityId].listed == true`。
10. 读取 `tierId = securities[securityId].tierId`。
11. 计算 `poolId = PoolId.unwrap(key.toId())`。
12. 校验 pool 尚未注册。
13. 写入 Pool 配置，至少包含 `key`、`securityId`、`tierId`。
14. 将 `poolId` 追加到 `poolsBySecurity[securityId]`。
15. 设置 `poolSecurityIndexPlusOne[poolId] = poolsBySecurity[securityId].length`。
16. 设置 `poolLifecycle[poolId] = PoolLifecycle.LIST`。
17. 递增 `listPoolCountBySecurity[securityId]`，因为新 pool 生命周期不是 `DELIST`。
18. 初始化或确认 `poolTickCount[poolId] == 0`；不递增 `activePoolCountBySecurity[securityId]`。
19. 发出 `PoolRegistered`。

推荐事件：

```solidity
event PoolRegistered(
    bytes32 indexed poolId,
    bytes32 indexed securityId,
    uint8 indexed tierId,
    PoolLifecycle lifecycle
);
```

## 7. Pool 生命周期查询

```solidity
function getPoolLifeCycle(bytes32 poolId) external view returns (PoolLifecycle lifecycle);
function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle);
```

推荐语义：

- 调用方可以直接传入 `poolId`，也可以传入完整 `PoolKey`，由 Registry 内部派生 `poolId` 后查询。
- `bytes32 poolId` 重载适合已保存注册返回值、事件索引或链下已派生 poolId 的调用方。
- `PoolKey calldata key` 重载适合 Router、LPManager、前端或脚本已经持有完整 PoolKey、但不希望重复派生 poolId 的调用方。
- 未注册 pool：返回默认值 `DELIST`，或按实现选择 revert。若返回默认值，调用方不能只靠该接口区分“未注册”和“已 DELIST”。
- 已注册且 `DELIST`：普通 swap 和普通 LP 不允许。
- 已注册且 `LIST`：生命周期维度允许普通 swap 和普通 LP。
- 已注册且 `PAUSE`：生命周期维度允许普通 LP，但不允许 swap；协议级全局 Pause 另看 `isPaused()`。

## 8. Pool 生命周期更新接口

```solidity
function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle) external returns (bool);
```

推荐语义：

- 调用方直接传入 `poolId`。
- 调用方必须具备 SYMBOL_ADMIN 或专门的 POOL_ADMIN 权限。
- pool 必须已注册，即 `isKnownPool(poolId) == true`。
- `lifecycle == PoolLifecycle.LIST`：恢复普通 swap 和普通 LP 的生命周期门禁。
- `lifecycle == PoolLifecycle.PAUSE`：Pool 业务暂停 swap，但保留普通 LP 能力；这不改变 `isPaused()`。
- `lifecycle == PoolLifecycle.DELIST`：阻断普通 swap 和普通 LP，但保留 pool 历史身份，退出和强退路径不应依赖 LIST。
- 设置 `lifecycle == PoolLifecycle.DELIST` 时，必须要求 `poolTickCount[poolId] == 0`；仍有活跃 Tick/NFT 的 pool 不允许进入 DELIST。
- 如果目标状态不是 `DELIST`，该 pool 绑定的 `securityId` 必须仍处于 listed 状态；证券已下架时，不应把历史 pool 重新打开为 `LIST` 或 `PAUSE`。
- 生命周期变更维护 `listPoolCountBySecurity[securityId]`：从 `DELIST` 切到 `LIST`/`PAUSE` 时递增，从 `LIST`/`PAUSE` 切到 `DELIST` 时递减。
- 生命周期变更不维护 `activePoolCountBySecurity[securityId]`；该计数只由 `updatePoolTickCount` 根据 `poolTickCount` 的 0/非 0 迁移维护。
- 若目标状态等于当前状态，建议返回 `false` 或 revert；实现应选择一种并在测试中固定。

推荐事件：

```solidity
event PoolLifecycleChanged(
    bytes32 indexed poolId,
    bytes32 indexed securityId,
    PoolLifecycle oldLifecycle,
    PoolLifecycle newLifecycle
);
```

批量生命周期更新接口：

```solidity
function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle)
    external
    returns (uint256 changedCount);
```

推荐语义：

- 调用方必须具备与 `updatePoolLifeCycle` 相同的权限。
- `poolIds.length` 必须大于 0。
- 每个 `poolId` 都必须已注册。
- 对每个当前生命周期不同于目标 `lifecycle` 的 pool，按单池更新逻辑切换状态，并发出 `PoolLifecycleChanged`。
- 如果目标状态是 `DELIST`，每个 pool 的 `poolTickCount` 都必须为 0。
- 对已经处于目标状态的 pool 视为幂等 no-op，不计入 `changedCount`。
- 返回 `changedCount`，便于调用方确认本次批量实际改变了多少个 pool。
- 如果目标状态不是 `DELIST`，每个 pool 绑定的 `securityId` 必须仍处于 listed 状态；证券已下架时，不应把历史 pool 批量重新打开为 `LIST` 或 `PAUSE`。
- 批量生命周期变更逐个维护 `listPoolCountBySecurity`，但不维护 `activePoolCountBySecurity`。
- 推荐设置一个合理的批量上限，例如 `MAX_POOL_LIFECYCLE_BATCH_SIZE`，避免单笔交易因为 calldata 或 gas 过大失败。大量 pool 应由调用方分批提交。

证券下架场景下，调用方可以传入该证券下仍未 `DELIST` 的 `poolId` 列表，并将 `lifecycle` 设置为 `PoolLifecycle.DELIST`。进入 `DELIST` 前必须先通过 LP/NFT 流程把对应 pool 的 `poolTickCount` 清零；生命周期接口本身维护 `listPoolCountBySecurity`，但不维护 `activePoolCountBySecurity`。

## 9. Pool Tick 数量接口

```solidity
function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool);
```

推荐语义：

- Registry 内部通过 `PoolId.unwrap(key.toId())` 派生 `poolId`。
- `delta` 表示本次 Tick/NFT 数量变化：mint 或新增绑定传正数，burn 或解除绑定传负数。
- 该接口是写接口，按 `delta` 更新 `poolTickCount[poolId]`。
- `delta > 0` 时，如果 `poolTickCount[poolId]` 从 0 变为正数，递增 `activePoolCountBySecurity[securityId]`。
- `delta < 0` 时，如果 `poolTickCount[poolId]` 从正数变为 0，递减 `activePoolCountBySecurity[securityId]`。
- `delta < 0` 不允许把 `poolTickCount[poolId]` 减到 0 以下。
- 已经处于 `PoolLifecycle.DELIST` 的 pool 不允许通过正 `delta` 重新变成活跃 pool。
- 返回 `true`：Tick 数量同步成功，或当前记录已经是最新状态。
- 返回 `false`：pool 不存在、PoolKey 不匹配，或外部 Tick 状态暂不可同步。
- Registry 必须保证不会把未知 pool 的 Tick 数量更新为有效状态。

## 10. 证券下架流程

`delistSecurity(securityId)` 推荐流程：

1. 校验 `securityId` 已登记且当前 `listed == true`。
2. 校验 `listPoolCountBySecurity[securityId] == 0`。
3. 若计数不为 0，说明至少还有一个关联 pool 的生命周期不是 `DELIST`，必须拒绝下架。
4. 释放该证券占用的 tier 名额。
5. 设置 `securities[securityId].listed = false`。
6. 发出原有 `SecurityDelisted` 事件。

配套操作顺序：

1. 运营或治理方通过 `poolsBySecurity[securityId]` 离线枚举该证券的历史 pool。
2. 对仍有 Tick/NFT 绑定的 pool，先通过 LP Manager 调用 `updatePoolTickCount(key, delta)`，直到 `poolTickCount == 0`。
3. 对仍需关闭业务生命周期的 pool，优先按批次调用 `batchUpdatePoolLifeCycle(poolIds, PoolLifecycle.DELIST)`。
4. 如果只剩单个或需要精确处理，也可以调用 `updatePoolLifeCycle(poolId, PoolLifecycle.DELIST)`。
5. 待 `listPoolCountBySecurity[securityId] == 0` 后，再调用 `delistSecurity(securityId)`。

这样可以避免在 `delistSecurity` 中执行无上限循环，同时让“关闭所有 pool”这个高频运营动作具备批量入口。

## 11. 协议级全局 Pause

```solidity
function isPaused() external view returns (bool);
```

推荐语义：

- `false`：协议级全局 Pause 未生效。
- `true`：协议级全局 Pause 生效，整个协议的普通 swap 和普通 LP 都应被阻断。

该接口不表达 Pool 生命周期，`PoolLifecycle.PAUSE` 也不影响 `isPaused()` 的返回值。Pool 的业务 PAUSE 必须通过 `updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE)` 设置。

## 12. 交易门禁组合

swap 生命周期门禁：

```solidity
poolLifecycle[poolId] == PoolLifecycle.LIST
```

LP 生命周期门禁：

```solidity
poolLifecycle[poolId] != PoolLifecycle.DELIST
```

协议级全局 Pause 门禁：

```solidity
!isPaused()
```

最终普通 swap 门禁推荐组合：

```solidity
swapAllowed =
    poolLifecycle[poolId] == PoolLifecycle.LIST
        && !isPaused()
        && securities[pools[poolId].securityId].listed
        && assetsAllowed;
```

其中 `assetsAllowed` 对 W/Q 的判断应改为：

- W：`currencyUnderlying[token] != address(0)`，且 `securities[underlyings[currencyUnderlying[token]].securityId].listed == true`。
- Q：`quoteTokens[token].registered == true`。

最终普通 LP 门禁推荐组合：

```solidity
lpAllowed =
    poolLifecycle[poolId] != PoolLifecycle.DELIST
        && !isPaused()
        && securities[pools[poolId].securityId].listed
        && assetsAllowed;
```

含义：

- `DELIST`：不可交易不允许 LP。
- `LIST`：生命周期允许普通 swap 和普通 LP。
- `PAUSE`：生命周期允许普通 LP，但不允许 swap。
- `isPaused() == true`：协议级全局 Pause 生效，无论 Pool 生命周期为何，普通 swap 和普通 LP 均不可执行。

## 13. 兼容影响

需要同步更新：

- `ITSVPermissionedRegistry`：删除 `admitPermissionedSecurity`，调整 `registerPermissionedCurrency` 签名，保留 `registerPool(key)` 签名，并增加查询接口。
- `ITSVPermissionedRegistry`：删除 `getCurrency(w) returns (PermissionedCurrencyConfig)`，新增 `getCurrencyUnderlying(w)`。
- `ITSVPermissionedRegistry`：删除 `updatePermissionedExpectedOwner`、`setPermissionedOwnerApproval` 和 `isPermissionedOwnerApproved`。
- `TSVRegistryV1`：删除 `admitPermissionedSecurity` 实现，删除 expected owner 状态和更新逻辑，改造 `registerPermissionedCurrency`、`registerPool`、`updatePoolLifeCycle`、`batchUpdatePoolLifeCycle` 和 `delistSecurity`。
- `TSVTypes.sol`：删除 `PermissionedCurrencyConfig`，删除 `PermissionedAdmission.expectedOwner`，增加 `PoolLifecycle`，并按最终结构调整 `PoolConfig`。
- `PermissionedValidationLib`：移除基于 expected owner 的 `validateOwner/validatePolicy` 状态校验；保留 W/U/Factory/decimals、资产身份隔离和 legalShareAdapter 接口与 U 绑定等准入校验。legalShareAdapter 校验通过 `validateLegalShareAdapter(adapter,currency)` 供 Registry 调用；Hook/Router policy 和首次库存校验不再保留。
- `TSVHookV1`、`TSVSwapRouterV1`、`TSVVolumeLedgerV1` 和测试 mock：把 `registry.getCurrency(w).underlying` 改为 `registry.getCurrencyUnderlying(w)`。
- 测试 fixture：原来调用 `admitPermissionedSecurity` 的路径改为 `registerPermissionedCurrency(admission, tierId)`。
- LP Manager 或建池调用方：继续调用 `registerPool(key)`，不需要传入 tier。
- ABI artifact 和文档：更新删除和变更后的接口。

## 14. 不变量

- `admitPermissionedSecurity` 不再存在。
- `PermissionedCurrencyConfig` 不再存在。
- `PermissionedAdmission` 不再包含 `expectedOwner`。
- `updatePermissionedExpectedOwner` 和 `PermissionedExpectedOwnerChanged` 不再存在。
- W 到 U 的关系必须只通过 `currencyUnderlying[w]` 表达，`currencyUnderlying[w] == address(0)` 表示 W 未注册。
- U 的 canonical 配置必须只通过 `underlyings[u]` 表达，`underlyings[u].securityId == 0` 表示 U 未绑定。
- 所有原 `getCurrency(w).underlying` 调用点必须改为 `getCurrencyUnderlying(w)`。
- 新证券首个 W 准入必须通过 `registerPermissionedCurrency(admission, tierId)` 原子完成。
- 已有证券新增 W 时，传入 `tierId` 必须等于证券已保存 tier。
- `registerPool(key)` 注册成功后，Pool 必须固化股票 `securityId` 和从该证券读取的 `tierId`。
- `registerPool` 成功后，新 pool 生命周期必须是 `LIST`。
- `registerPool` 成功后，必须把 pool 追加到 `poolsBySecurity[securityId]`，并写入 `poolSecurityIndexPlusOne[poolId]`。
- `listPoolCountBySecurity[securityId]` 必须等于该证券下生命周期不是 `DELIST` 的 pool 数量。
- `activePoolCountBySecurity[securityId]` 必须等于该证券下 `poolTickCount > 0` 的 pool 数量。
- `delistSecurity(securityId)` 只有在 `listPoolCountBySecurity[securityId] == 0` 时才能成功。
- `delistSecurity` 不应循环修改 pool 生命周期，也不应从 `poolsBySecurity[securityId]` 删除历史 pool。
- `batchUpdatePoolLifeCycle(poolIds, lifecycle)` 必须只接收 poolId 列表，不接收 PoolKey。
- `updatePoolLifeCycle(..., DELIST)` 和 `batchUpdatePoolLifeCycle(..., DELIST)` 必须要求目标 pool 的 `poolTickCount == 0`。
- `updatePoolLifeCycle` 和 `batchUpdatePoolLifeCycle` 必须维护 `listPoolCountBySecurity`，但不应维护 `activePoolCountBySecurity`。
- `relistSecurity` 不应自动把历史 pool 从 `DELIST` 恢复为 `LIST` 或 `PAUSE`。
- Pool 生命周期维度下，只有 `LIST` 允许普通 swap。
- Pool 生命周期维度下，`LIST` 和 `PAUSE` 允许普通 LP，`DELIST` 阻断普通 LP。
- `PoolLifecycle.PAUSE` 不是协议级全局 Pause。
- `PoolLifecycle.PAUSE` 必须通过 `updatePoolLifeCycle(poolId, PoolLifecycle.PAUSE)` 设置。
- `isPaused()` 是协议级全局 Pause 查询接口。
- `getPoolLifeCycle` 必须同时保留 `bytes32 poolId` 和 `PoolKey calldata key` 两个查询重载；不得删除 `PoolKey` 查询重载。
- `updatePoolLifeCycle(poolId,lifecycle)` 和 `batchUpdatePoolLifeCycle(poolIds,lifecycle)` 是写接口，必须只接收 poolId，不接收 PoolKey。
- `updatePoolTickCount(key, delta)` 仍从完整 PoolKey 派生 poolId。
- `updatePoolTickCount(key, delta)` 是写接口，按 delta 更新 `poolTickCount`，并维护 `activePoolCountBySecurity`，不维护 `listPoolCountBySecurity`。
- 强退、退出和历史查询路径不应要求 pool 生命周期仍为 `LIST`。
