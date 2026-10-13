# TSV V1 当前合约接口与状态规则

本文是 `src/v1/` 的接口导航和行为摘要，不是独立于源码的规范。合约 ABI 以当前编译结果为准；继承自 Uniswap、OpenZeppelin 和 permissioned-pools 的入口需结合相应父合约查看。测试目录和执行边界见 [`../test/README.md`](../test/README.md)。

## 1. 合约与外部依赖

TSV V1 包含 Registry、Volume Ledger、Hook、Swap Router 和 LP Manager。它们连接 Uniswap V4 `PoolManager`、Permissions Adapter Factory、Factory 创建的 W、W 对应的 U、已登记的 Q、Participant SBT 和 legal-share adapter。每个 TSV PoolKey 必须使用 TSV Hook，并且恰好包含一只 W 和一个 Q。

构建参数以 [`../foundry.toml`](../foundry.toml) 为准：Solidity 0.8.26、Cancun、via-IR、optimizer runs 200。V4 与 OpenZeppelin 版本应通过 submodule/soldeer 配置解析，不要从文档中的旧构建日志推断版本。

## 2. ABI 中的主要数据类型

| 类型 | 当前字段或值 | 用途 |
| --- | --- | --- |
| `PermissionedRegisterParam` | `currency`, `securityId`, `legalShareAdapter` | 注册 W、其 U 派生关系对应的证券 ID 和法律股数 Adapter |
| `UnderlyingRecord` | `securityId`, `legalShareAdapter`, `rawDecimals`, `registered` | W 共享的 canonical U 配置 |
| `QuoteTokenRecord` | `rawDecimals`, `registered` | Q 的准入精度和新池注册开关 |
| `SecurityRecord` | `securityId`, `tierId`, `listed`, `poolIds`, `listedPoolCount`, `securityState` | 证券上市、所属池和安全模式 |
| `PoolRecord` | `key`, `securityId`, `tierId`, `lifecycle`, `tickCount`, `poolSecurityIndex` | 已登记 V4 池的完整身份和运行状态 |
| `SecurityPauseMode` | `NONE`, `TRADE`, `LP`, `ALL` | 替换式证券操作暂停模式；数值同时作为 LP/TRADE 位掩码 |
| `PoolLifecycle` | `DELIST`, `LIST`, `PAUSE` | 池自身的交易/普通 LP lifecycle |
| `SwapRequest` | `PoolKey key`, `bool zeroForOne`, `uint128 amountSpecified`, `uint128 limitAmount`, `uint64 deadline`, `uint256 expectedMultiplier` | Router 单池 exact-input 请求；最后一个数值是当前 U Adapter multiplier 快照 |
| `DailyQuota` | `uint256 ESTDay`, `uint256 amount` | Ledger 中任意 epoch day 的 usedWad 写入值，金额为 WAD |
| `SbtIdentityConfig` | `bool registered`, `PermissionFlag permissions` | SBT tokenId 到 TSV 操作权限的配置 |

权威字段注释见 [`src/v1/types/TSVTypes.sol`](../src/v1/types/TSVTypes.sol) 和各合约源码。

## 3. Registry 写入口与只读接口

### 初始化与依赖绑定

- `initialize(address admin)`：初始化 Default Admin 和 Upgrade Admin。
- `bindComponents(address hook, address lpManager, address factory, address sbt)`：仅 Default Admin 可调用一次。要求组件有代码、SBT `paused()`/`verify()` 可读，并从 Factory 读取有代码的 PoolManager。Registry 保存 Hook、LP Manager、Factory、PoolManager 和 SBT。
- `permissionedValidationLibrary()`：读取链接到 Registry 实现的 `PermissionedValidationLib` 地址。

### SBT、证券和资产

| 写入口 | 角色 | 语义 |
| --- | --- | --- |
| `setSbtConfig(uint256 tokenId, PermissionFlag permissions, bytes32 reasonCode)` | Default Admin | 注册/更新身份权限；允许 `NONE`、`SWAP_ALLOWED`、`LIQUIDITY_ALLOWED` 及二者并集 |
| `setTierPolicy(uint8 tierId, uint32 maxListed, bytes32 reasonCode)` | Default Admin | 设置非零 tier 的上市证券容量；不能低于当前 listed 数 |
| `registerPermissionedCurrency(PermissionedRegisterParam, uint8 tierId, bytes32 reasonCode)` | Symbol Admin | 新证券连同首个 W 原子登记，或为同一已上市证券添加 W |
| `registerQuoteToken(address quote, bytes32 reasonCode)` | Symbol Admin | 登记 Q 与其 decimals |
| `disableUnderlyingPoolRegister(address u, bytes32 reasonCode)` | Symbol Admin | 禁止 U 加入新池，不关闭既有池 |
| `disableQuoteTokenPoolRegister(address q, bytes32 reasonCode)` | Symbol Admin | 禁止 Q 加入新池，不关闭既有池 |
| `replaceUnderlyingLegalShareAdapter(address u, address adapter, bytes32 reasonCode)` | Symbol Admin | 校验 adapter 接口及 U 绑定后，立即用于后续成交 |
| `setSecurityTier(bytes32 securityId, uint8 tierId, bytes32 reasonCode)` | Symbol Admin | 将已上市证券移到可用 tier；既有 PoolRecord 中 tier 快照不变 |
| `relistSecurity(bytes32 securityId, bytes32 reasonCode)` | Symbol Admin | 恢复已下架证券到原 tier；不自动恢复 DELIST 池 |
| `delistSecurity(bytes32 securityId, bytes32 reasonCode)` | Symbol Admin | 只有证券下所有池 lifecycle 均 DELIST 后才能下架 |

Registry 查询包括 `getSecurity`、`getTierPolicy`、`getCurrencyUnderlying(W)`、`getUnderlying(U)`、`getQuoteToken(Q)`、`getPool(poolId)`、`isKnownPool`、`getPoolLifeCycle`、`getListPoolCountBySecurity`、`getPoolTickCount`、`getSecurityPauseMode`、`isTradable`、`isLPAllowed` 和 `isPaused`。默认 mapping 记录不能被当作已准入的资产或池。

### 池、lifecycle 和暂停

- `registerPool(PoolKey)` 只允许已绑定 LP Manager 调用。key 必须排序正确、使用登记 Hook、fee/tick spacing 合法，资产都允许新池准入，并且池中恰有一只 W 和一个 Q。新池从 `LIST` 开始，并快照当前 securityId/tier。
- `updatePoolLifeCycle` / `batchUpdatePoolLifeCycle`：Symbol Admin 设置 `LIST`、`PAUSE` 或 `DELIST`。DELIST 要求 `tickCount == 0`；重新启用非 DELIST 状态要求证券仍上市。
- `updatePoolTickCount(PoolKey, int256)`：仅 LP Manager 更新；增加时池不能 DELIST 且证券必须上市，减少不能低于零。
- `applySecurityStatus(securityId, mode, reasonCode)`：Halt Reporter 为已上市证券写入最终 `NONE`/`TRADE`/`LP`/`ALL` 模式。相同模式会回滚。当前 `SecurityStatusChanged` 事件不带 reasonCode。
- `setEmergencyPauseEnable(bool enabled, bytes32 reasonCode)`：启用需 Emergency Pauser，解除需 Emergency Resumer；状态必须发生变化。
- `isTradable` 与 `isLPAllowed` 不包含全局紧急暂停；使用执行入口时还需检查 `isPaused()`。

所有上述管理操作要求 `reasonCode != bytes32(0)`，但事件是否包含该字段应以当前事件声明为准。

## 4. Volume Ledger

Ledger 只保存调用方直接设定的值，没有 ADTV、tier 公式或拆并股状态。

| ABI | 权限与规则 |
| --- | --- |
| `initialize(address registry)` | Registry 地址必须有代码 |
| `setQuota(bytes32 securityId, uint256 amount, bytes32 reasonCode)` | Registry 的 `VOLUME_ORACLE_ROLE`；证券与原因码非零；直接覆盖逐日沿用的 `Quota`，不清空 `usedWad` |
| `setUsedWad(bytes32 securityId, DailyQuota[] values, bytes32 reasonCode)` | 同一角色；逐项覆盖当日用量，允许 0 和高于额度 |
| `currentESTDay()` | 返回 `(block.timestamp - 5 hours) / 1 days`，epoch day，固定 UTC-5 |
| `recordSwap(poolId, delta0, delta1, legalShares0, legalShares1)` | 仅 Registry 配置的 Hook；验证 V4 delta 方向并要求恰有一个非零 legal-share leg，累加后检查 `usedWad <= Quota` |

`setQuota` 立即生效，不能预设指定日期的额度。`setUsedWad` 对空数组无操作；未排序日期和重复日期均按数组顺序写入，重复日期最后一次写入生效。Quota 默认为 0，正成交量需先设置足额 quota。用量修正可低于已记录量，或高于 quota；只影响之后的成交检查。事件为 `QuotaSet`、`UsedWadSet` 和 `VolumeUsed`。

## 5. Router 请求

| 入口 | 调用者与结算 |
| --- | --- |
| `swapExactInputFromContractDirect(SwapRequest request, address payer, address participant, address recipient)` | 仅已 allowlist 的 Adapter；U 输入要求 payer 为零且 U 已存入 W；Q 输入要求 payer 为调用 Adapter；输出给 recipient |
| `swapExactInputFromContract(SwapRequest request, address participant)` | 仅已 allowlist 的 Adapter；调用 Adapter 为 payer 和输出接收方 |
| `setAdapterAllowed(address adapter, bool allowed)` | Registry Default Admin；启用时地址必须有代码，且全局暂停时不可调用 |
| `settlementCurrency(address currency)` | 若输入为已登记 W，返回 U；否则返回原地址 |

`amountSpecified` 必须大于零且不超过 `int128.max`；`limitAmount` 必须非零；deadline 过期时拒绝。Router 构造单池 exact-input action，检查最终实际输入等于请求输入，V4 action 检查最小输出。用户身份由 `participant` 决定；Adapter 负责保证此地址与外部调用上下文一致。

## 6. Hook 与法律股数 Adapter

Hook 初始化参数为 `(poolManager, registry, ledger, router, lpManager)`。代理地址低 14 位必须等于 `0x3FFF`，可由 `TSVHookProxyFactoryV1.predict/deploy` 配合 CREATE2 salt 生成。V1 Hook 返回零 before/after swap delta、零 liquidity delta，不重写 fee；donate 回调拒绝。

Swap 的 hookData 必须是一个 ABI 编码 `uint256 expectedMultiplier`。Hook 在 beforeSwap 和 afterSwap 都读取 canonical U Adapter 的实时 multiplier 并要求相等。LP hookData 可为空；非空时同样要求 32 字节快照。

`ERC8056DirectLegalShareAdapter` 绑定单个 U，要求 token `decimals <= 18`、`uiMultiplier() > 0`。对非零 rawAmount 的换算为 `floor(rawAmount * uiMultiplier / 10**decimals)`；结果为 0 时拒绝。Adapter 不定义或证明该公式是发行方认可的法律股数口径。

## 7. LP Manager

LP Manager 构造器把 PoolManager、Permit2、订阅 gas limit、Position Descriptor、WETH、Permissions Adapter Factory、交付 gas limit 和 Registry 固定在实现参数/immutable 中；代理 initializer 为 `initialize(registry)`。

对外关键入口为 `initializePool`、继承的 `modifyLiquidities`/`modifyLiquiditiesWithoutUnlock`、`unwindPosition`、`unwindPositionByTsv`、ERC-721 `ownerOf/approve/permit` 等父类接口。各 action 的权限及结算行为由 [`TSVLPManagerLib.sol`](../src/v1/libraries/TSVLPManagerLib.sol) 与 permissioned position manager 共同实现。

`MINT_POSITION_FROM_DELTAS` 和 `INCREASE_LIQUIDITY_FROM_DELTAS` 被拒绝。普通 action 校验调用者及仓位 owner 的 SBT LP 权限；强退使用受限回调上下文。`withdrawClaim` 固定回滚。强退一次性销毁完整 position，可能受收款 Token 行为和 `int128` delta 边界影响。

## 8. 角色和升级

Registry 继承 AccessControl/UUPS。`initialize(admin)` 授予调用配置使用的 Default Admin 与 Upgrade Admin；各角色通过 Registry 的 AccessControl 管理。Router、LP Manager、Hook 和 Ledger 读取 Registry 的角色状态。Registry 自身升级由其本地 Upgrade Admin 授权；其他组件由 Registry 查询 `UPGRADE_ADMIN_ROLE`。

业务角色常量和消费者见 [`TSVGoverned.sol`](../src/v1/governance/TSVGoverned.sol)、Registry、Ledger 与 periphery 源码。共享基类虽然声明 `REVOKE_EXIT_EXECUTOR_ROLE` 和 `WITHDRAW_CLAIM_ROLE`，当前 TSV 路径没有消费者；LP `withdrawClaim` 禁用。

## 9. 组件初始化参数

| 代理 | initializer | 特别约束 |
| --- | --- | --- |
| Registry | `initialize(admin)` | 后续调用 `bindComponents(hook, lpManager, factory, sbt)` 一次 |
| Volume Ledger | `initialize(registry)` | quota/upgrade 角色从 Registry 查询 |
| Hook | `initialize(poolManager, registry, ledger, router, lpManager)` | CREATE2 代理地址须满足 V4 Hook flags |
| Swap Router | `initialize(poolManager, registry)` | 实现构造参数固定 PoolManager 和 Factory，initializer 必须与之匹配 |
| LP Manager | `initialize(registry)` | 实现构造时已固定 PoolManager、Factory 等依赖 |

`TSVERC1967Proxy` 要求初始化 calldata 非空，并提供 `tsvImplementation()`。实现构造器禁用 implementation 自身初始化。该表描述代码入口，不代表仓库已经包含可用于目标链的完整部署脚本或实际部署状态。
