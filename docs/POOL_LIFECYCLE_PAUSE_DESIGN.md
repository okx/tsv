# TSVRegistryV1 Pool Lifecycle 与协议级 Pause 改造设计

## 1. 目标

本文定义对 `TSVRegistryV1` 的接口和状态改造：

- 删除 `admitPermissionedSecurity(uint8 tierId, PermissionedAdmission admission)`。
- 优化 `registerPermissionedCurrency`，承接新证券首个 W 准入能力，避免保留两个股票准入入口。
- 保持现有 `registerPool(PoolKey calldata key)` 接口不变。
- 注册 Pool 时由 Registry 内部推导股票 `securityId`，并固化该证券当前 `tierId`。
- 增加 Pool 生命周期查询与更新、Pool Tick 数量检查入口，以及协议级全局 Pause 查询。

本方案区分两类 pause：

- 协议级全局 Pause：由 `isPaused()` 表达，影响整个协议的普通 swap 和普通 LP。
- Pool 业务生命周期 PAUSE：由 `updatePoolLifeCycle(key, PoolLifecycle.PAUSE)` 设置，只阻断该 pool 的 swap，普通 LP 继续进入后续门禁。

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

### 2.3 Pool 注册接口

Pool 注册接口保持现有签名：

```solidity
function registerPool(PoolKey calldata key) external returns (bytes32 poolId);
```

说明：

- `key` 沿用现有完整 V4 PoolKey。
- `securityId` 不作为接口参数传入，继续由 Registry 根据 `key.currency0/key.currency1` 的 W/Q 配置推导。
- `tierId` 不作为接口参数传入，由 Registry 根据推导出的 `securityId` 读取 `securities[securityId].tierId`。
- 注册成功后，Pool 配置中应保存该股票 `securityId` 和 `tierId`，后续查询和门禁不再重复从资产映射里临时拼装 tier。

### 2.4 新增接口

本方案只新增以下接口：

```solidity
function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle);
function updatePoolLifeCycle(PoolKey calldata key, PoolLifecycle lifecycle) external returns (bool);
function updatePoolTickCount(PoolKey calldata key) external returns (bool);
function isPaused() external view returns (bool);
```

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

### 4.3 Pool 生命周期与 Tick 数量

```solidity
/// @notice 每个已注册池的显式生命周期状态。
/// @dev registerPool 将新池初始化为 LIST。
mapping(bytes32 poolId => PoolLifecycle lifecycle) public poolLifecycle;

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
    // 伪代码，具体校验复用现有 _registerPermissionedCurrency。
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
5. 复用现有 `_registerPermissionedCurrency(admission)` 的 W/U 校验：
   - 环境已绑定。
   - W 未注册。
   - W 是 Factory 已验证的 PermissionsAdapter。
   - U 与 W decimals 一致且不超过 18。
   - U 的 canonical `securityId/rawDecimals/legalShareAdapter` 一致。
   - `expectedOwner` 已批准且是 W owner。
   - W 允许 Router 和 Hook。
   - exitAdmin 已配置且与 owner 分离。
   - 首次库存检查通过。
6. 任一校验失败时，证券写入、tier 计数和 W/U 写入全部回滚。

这个优化保留了原 `admitPermissionedSecurity` 的原子性，但只暴露一个股票 W 准入入口。

## 6. registerPool 优化流程

`registerPool(key)` 推荐流程：

1. 校验调用者必须是 `lpManager`。
2. 校验 `key.hooks == hook`。
3. 校验 `currency0/currency1` 非零且按地址排序。
4. 校验 fee、tickSpacing、资产准入等现有 PoolKey 条件。
5. 从 `currency0/currency1` 读取已准入 W/Q 配置。
6. 推导 `securityId0` 和 `securityId1`。
7. 要求恰好一侧是股票，即 `(securityId0 == 0) != (securityId1 == 0)`。
8. 推导 `securityId = securityId0 == 0 ? securityId1 : securityId0`。
9. 校验 `securities[securityId].listed == true`。
10. 读取 `tierId = securities[securityId].tierId`。
11. 计算 `poolId = PoolId.unwrap(key.toId())`。
12. 校验 pool 尚未注册。
13. 写入 Pool 配置，至少包含 `key`、`securityId`、`tierId`。
14. 设置 `poolLifecycle[poolId] = PoolLifecycle.LIST`。
15. 初始化或确认 `poolTickCount[poolId] == 0`。
16. 发出 `PoolRegistered`。

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
function getPoolLifeCycle(PoolKey calldata key) external view returns (PoolLifecycle lifecycle);
```

推荐语义：

- Registry 内部通过 `PoolId.unwrap(key.toId())` 派生 `poolId`。
- 未注册 pool：返回默认值 `DELIST`，或按实现选择 revert。若返回默认值，调用方不能只靠该接口区分“未注册”和“已 DELIST”。
- 已注册且 `DELIST`：普通 swap 和普通 LP 不允许。
- 已注册且 `LIST`：生命周期维度允许普通 swap 和普通 LP。
- 已注册且 `PAUSE`：生命周期维度允许普通 LP，但不允许 swap；协议级全局 Pause 另看 `isPaused()`。

## 8. Pool 生命周期更新接口

```solidity
function updatePoolLifeCycle(PoolKey calldata key, PoolLifecycle lifecycle) external returns (bool);
```

推荐语义：

- Registry 内部通过 `PoolId.unwrap(key.toId())` 派生 `poolId`。
- 调用方必须具备 SYMBOL_ADMIN 或专门的 POOL_ADMIN 权限。
- pool 必须已注册，且传入的完整 `PoolKey` 必须与注册时保存的 `pools[poolId].key` 一致。
- `lifecycle == PoolLifecycle.LIST`：恢复普通 swap 和普通 LP 的生命周期门禁。
- `lifecycle == PoolLifecycle.PAUSE`：Pool 业务暂停 swap，但保留普通 LP 能力；这不改变 `isPaused()`。
- `lifecycle == PoolLifecycle.DELIST`：阻断普通 swap 和普通 LP，但保留 pool 历史身份，退出和强退路径不应依赖 LIST。
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

## 9. Pool Tick 数量接口

```solidity
function updatePoolTickCount(PoolKey calldata key) external returns (bool);
```

推荐语义：

- Registry 内部通过 `PoolId.unwrap(key.toId())` 派生 `poolId`。
- 该接口是写接口，可以同步或更新 `poolTickCount[poolId]`。
- 返回 `true`：Tick 数量同步成功，或当前记录已经是最新状态。
- 返回 `false`：pool 不存在、PoolKey 不匹配，或外部 Tick 状态暂不可同步。
- 具体 `+1/-1` 或重算逻辑由 LP Manager / NFT 设计决定；Registry 必须保证不会把未知 pool 的 Tick 数量更新为有效状态。

## 10. 协议级全局 Pause

```solidity
function isPaused() external view returns (bool);
```

推荐语义：

- `false`：协议级全局 Pause 未生效。
- `true`：协议级全局 Pause 生效，整个协议的普通 swap 和普通 LP 都应被阻断。

该接口不表达 Pool 生命周期，`PoolLifecycle.PAUSE` 也不影响 `isPaused()` 的返回值。Pool 的业务 PAUSE 必须通过 `updatePoolLifeCycle(key, PoolLifecycle.PAUSE)` 设置。

## 11. 交易门禁组合

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

## 12. 兼容影响

需要同步更新：

- `ITSVPermissionedRegistry`：删除 `admitPermissionedSecurity`，调整 `registerPermissionedCurrency` 签名，保留 `registerPool(key)` 签名，并增加查询接口。
- `TSVRegistryV1`：删除 `admitPermissionedSecurity` 实现，改造 `registerPermissionedCurrency` 和 `registerPool`。
- `TSVTypes.sol`：增加 `PoolLifecycle`，并按最终结构调整 `PoolConfig`。
- 测试 fixture：原来调用 `admitPermissionedSecurity` 的路径改为 `registerPermissionedCurrency(admission, tierId)`。
- LP Manager 或建池调用方：继续调用 `registerPool(key)`，不需要传入 tier。
- ABI artifact 和文档：更新删除和变更后的接口。

## 13. 不变量

- `admitPermissionedSecurity` 不再存在。
- 新证券首个 W 准入必须通过 `registerPermissionedCurrency(admission, tierId)` 原子完成。
- 已有证券新增 W 时，传入 `tierId` 必须等于证券已保存 tier。
- `registerPool(key)` 注册成功后，Pool 必须固化股票 `securityId` 和从该证券读取的 `tierId`。
- `registerPool` 成功后，新 pool 生命周期必须是 `LIST`。
- Pool 生命周期维度下，只有 `LIST` 允许普通 swap。
- Pool 生命周期维度下，`LIST` 和 `PAUSE` 允许普通 LP，`DELIST` 阻断普通 LP。
- `PoolLifecycle.PAUSE` 不是协议级全局 Pause。
- `PoolLifecycle.PAUSE` 必须通过 `updatePoolLifeCycle(key, PoolLifecycle.PAUSE)` 设置。
- `isPaused()` 是协议级全局 Pause 查询接口。
- `getPoolLifeCycle(key)`、`updatePoolLifeCycle(key,lifecycle)` 和 `updatePoolTickCount(key)` 都必须从完整 PoolKey 派生 poolId，不接受外部直接传入的 poolId。
- `updatePoolTickCount(key)` 是写接口，可以同步 `poolTickCount`。
- 强退、退出和历史查询路径不应要求 pool 生命周期仍为 `LIST`。
