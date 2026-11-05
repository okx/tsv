# TSV 池监听与 W/U 映射查询

本文说明后端如何发现绑定 TSV Hook 的 V4 池、如何监听 Factory 创建的 W，以及如何查询 W 对应的 U。接口名称按当前 `src/v1/` 合约代码；若封装成后端 HTTP API，路由属于后端约定，不是 Solidity ABI。

## 1. 监听绑定 TSV Hook 的池

监听方式与普通 Uniswap V4 池相同：监听目标链上配置的 V4 `PoolManager` 的 `Initialize` 事件，解码完整事件后，只保留 `hooks` 等于当前 TSV Hook **代理地址**的记录。不要拿 Hook implementation 地址比较。实际地址可从部署清单或 Registry 的 `hook()` getter 获取，并应按链分别配置。

```solidity
event Initialize(
    PoolId indexed id,
    Currency indexed currency0,
    Currency indexed currency1,
    uint24 fee,
    int24 tickSpacing,
    IHooks hooks,
    uint160 sqrtPriceX96,
    int24 tick
);
```

`hooks` 在事件 data 中而不是 indexed topic 中。因此 RPC 日志订阅可按 PoolManager 地址和 `Initialize` 的 event topic 缩小范围，但要在服务端解码日志，再按 `hooks == registry.hook()` 过滤。事件的 `id` 是该完整 PoolKey 的 poolId；currency 顺序、fee、tickSpacing 和 hooks 一起构成池身份。

### 建议的校验与落库步骤

1. 从目标链的 PoolManager 接收 `Initialize`，解码 `id`、currency0/1、fee、tickSpacing、hooks 和区块/交易信息。
2. 过滤 `hooks` 不等于 TSV Hook 代理地址的事件。
3. 调用 `registry.isKnownPool(id)` 和 `registry.getPool(id)`，确认 Registry 已登记该 poolId，并核对返回的完整 PoolKey 与事件字段一致。
4. 校验资产身份：两侧恰有一侧满足 `registry.getCurrencyUnderlying(W) != address(0)`；另一侧应是已登记的 Q，可用 `registry.getQuoteToken(Q)` 检查。通过 `getPool(id)` 读取 `securityId`、tier 快照和生命周期。
5. 按 `(chainId, poolId)` 去重保存。使用区块号、交易哈希和 log index 保留来源；处理区块重组，并从配置的起始区块补扫历史日志，避免服务重启期间漏池。

TSV 当前的标准初始化入口是 `TSVLPManagerV1.initializePool`：它先调用 Registry 的 `registerPool(key)`，再在同一笔交易中调用 PoolManager `initialize`。因此成功的标准初始化会同时产生 Registry `PoolRegistered` 与 PoolManager `Initialize` 日志；初始化回滚时，注册日志也会回滚。若后端更关心“TSV 已登记的池”，也可以监听 Registry 的 `PoolRegistered`，再用 `getPool(poolId)` 取完整 PoolKey；若要按 V4 通用方式发现已初始化池，则以上述 PoolManager `Initialize` 为入口。

仅匹配 Hook 地址可以识别“使用 TSV Hook 的池”这一候选集合。`isKnownPool`/`getPool` 用来确认 Registry 登记；生命周期可能是 `LIST`、`PAUSE` 或 `DELIST`，若业务需要判断当前是否可交易，再读 `isTradable(poolId)`，并另行考虑全局暂停 `isPaused()`。

## 2. 监听 Factory 创建和验证的 W

配置 Registry 绑定的 `permissionsAdapterFactory()` 地址，监听该 Factory 的两个事件：

| 事件 | 关键字段 | 含义 |
| --- | --- | --- |
| `PermissionsAdapterCreated(W indexed, U indexed)` | `permissionsAdapter`、`permissionedToken` | 创建了一个 W，并记录其包装的 U。此时只表示 Factory 创建，不代表 W 已验证或已获 TSV 准入。 |
| `PermissionsAdapterVerified(W indexed, U indexed)` | `permissionsAdapter`、`permissionedToken` | Factory 已将 W 标记为 verified；当前实现要求 W 中有底层 token 余额。 |

Factory 提供以下只读映射：

| 调用 | 返回值 | 解释 |
| --- | --- | --- |
| `permissionsAdapterOf(W)` | U 或零地址 | W 是否由该 Factory 创建，以及创建时登记的底层 U。 |
| `verifiedPermissionsAdapterOf(W)` | U 或零地址 | W 是否已通过 Factory 验证；零地址表示尚未验证或该 W 不属于此 Factory。 |

建议将 Factory 的 `Created` 事件作为新 W 的发现信号，`Verified` 作为状态更新信号。若只需要可用作 TSV 股票资产的 W，不要把 `Created` 直接当成准入完成：Registry 注册时会再次核验 Factory 来源、verified 状态及 W/U 元数据。

## 3. 查询 W/U 映射与 `factory/{w}/register`

当前合约分两层保存/暴露 W/U 关系：

| 数据来源 | 查询接口/事件 | 可以证明什么 |
| --- | --- | --- |
| Factory | `permissionsAdapterOf(W)`、`verifiedPermissionsAdapterOf(W)`；并可监听上述 Factory 事件 | Factory 创建的 W 指向哪个 U；W 是否已验证。 |
| TSV Registry | `getCurrencyUnderlying(W)`；并可监听 `PermissionedCurrencyRegistered(W indexed, U indexed, securityId indexed, reasonCode)` | W 已完成 TSV 登记及 Registry 采用的 W/U/securityId 映射。W 未登记时返回零地址。 |

`registerPermissionedCurrency(param, tierId, reasonCode)` 是 Registry 上的**写入准入方法**，不是 Factory 的方法。成功执行后，Registry 写入 `currencyUnderlying[W] = U` 并发出 `PermissionedCurrencyRegistered`。后端查询时以 Registry 的 `getCurrencyUnderlying(W)` 作为“是否已登记”的权威结果；可同时读取 Factory 两个 getter 展示创建/验证状态，并读取 `getUnderlying(U)` 补充 `securityId`、legal-share adapter、decimals 和新池注册状态。

如果 `factory/{w}/register` 指后端提供的查询路由，它应明确作为后端 API 约定，而非现有链上函数。建议该查询聚合并返回至少以下字段：

- `w`：请求的 W 地址。
- `factoryUnderlying`：`permissionsAdapterOf(W)` 的结果。
- `verifiedUnderlying`：`verifiedPermissionsAdapterOf(W)` 的结果。
- `registryUnderlying`：`getCurrencyUnderlying(W)` 的结果；非零表示已登记到 TSV Registry。
- 当 `registryUnderlying != 0` 时，再返回 `getUnderlying(registryUnderlying)` 中的证券和资产配置。

接口应保留链 ID 和查询区块（或明确标记使用最新状态），因为这些都是链上状态读取。若 Factory 返回的 U 与 Registry 返回的 U 不一致，应报告映射不一致并停止将此 W 作为正常登记资产使用；正常准入流程中二者应相同。

## 4. 状态关系速查

```text
Factory PermissionsAdapterCreated(W, U)
        │  Factory.permissionsAdapterOf(W) = U
        ▼
Factory PermissionsAdapterVerified(W, U)
        │  Factory.verifiedPermissionsAdapterOf(W) = U
        ▼
Registry registerPermissionedCurrency(...)
        │  Registry.getCurrencyUnderlying(W) = U
        ▼
Registry PoolRegistered(poolId, ...)
        │  标准路径中同一交易继续初始化
        ▼
PoolManager Initialize(..., hooks = TSV Hook proxy, ...)
```

前两步代表 Factory 生命周期，第三步代表 TSV 资产准入，最后两步代表池登记和 V4 初始化。W 被创建或验证都不意味着已经有 TSV 池；反过来，池监控应以 PoolManager/Registry 的池事件为准，而不是仅从 Factory 的 W 事件推断。

## 5. 当前代码依据

- Factory 事件和映射：[`IPermissionsAdapterFactory.sol`](../src/v1/vendor/permissionedPools/interfaces/IPermissionsAdapterFactory.sol)、[`PermissionsAdapterFactory.sol`](../src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol)
- Registry 的 W/U 读写与池登记：[`TSVRegistryV1.sol`](../src/v1/core/TSVRegistryV1.sol)、[`ITSVPermissionedRegistry.sol`](../src/v1/interfaces/ITSVPermissionedRegistry.sol)
- V4 `Initialize` 事件：[`IPoolManager.sol`](../lib/v4-core/src/interfaces/IPoolManager.sol)
- LP Manager 的池初始化路径：[`TSVLPManagerV1.sol`](../src/v1/periphery/TSVLPManagerV1.sol)、[`TSVLPManagerLib.sol`](../src/v1/libraries/TSVLPManagerLib.sol)
