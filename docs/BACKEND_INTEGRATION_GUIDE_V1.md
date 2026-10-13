# TSV V1 后端接入指南

本指南按当前 `src/v1/` ABI 编写。它不包含 ADTV 报告、拆并股报告、可配置交易日或 DataInbox 流程；相关历史描述不适用于当前合约。部署前先核对目标链地址、ABI 和权限。

## 1. 资产和池信息

当前池必须是 W/Q：PoolKey 一侧是已验证并在 Registry 登记的 Permissions Adapter W，另一侧是已登记的 quote token Q。用户与 Router 外部结算使用 U/Q；PoolManager 内使用 W/Q。

后端可读取：

| 读取项 | 用途 |
| --- | --- |
| `registry.getCurrencyUnderlying(W)` | 获取 W 的 U；返回 0 表示不是已登记 W |
| `registry.getUnderlying(U)` | 读取 `securityId`、`legalShareAdapter`、decimals 和新池注册状态 |
| `registry.getQuoteToken(Q)` | 读取 Q decimals 和新池注册状态 |
| `registry.getPool(poolId)` | 读取 pool key、securityId、tier 快照、lifecycle 和 NFT 计数 |
| `registry.isKnownPool(poolId)` / `getPoolLifeCycle(poolId)` | 判断是否登记及其生命周期 |
| `router.settlementCurrency(W)` | 获取 W 腿外部结算资产 U；Q 返回自身地址 |

PoolId 使用 Uniswap V4 对完整 PoolKey 的 hash。不要只以 token pair、fee 或 hook 中任意一项作为池身份。

## 2. 参与者资格和外层 DEX Adapter

TSV Router 的两个 Swap 写入口均要求 `msg.sender` 在 Router Adapter allowlist 中；普通用户不能直接作为 Router caller。外部 DEX Adapter 应将真实 participant 传给 Router：

- `swapExactInputFromContractDirect(request, participant, recipient)` 由 allowlisted Adapter 调用，从 participant 拉取 settlement input，并向 `recipient` 交付 output。
- `swapExactInputFromContract(request, participant)` 由 allowlisted Adapter 调用，从 Adapter 预存余额扣 input，并把 output 返回给 Adapter。

Router 通过 `registry.isSbtAllowed(SWAP_ALLOWED, participant)` 校验 TSV 身份权限；W 再通过 issuer checker 和 `swappingEnabled` 校验发行方权限。后端需分别读取/检查这两层状态。使用外部 DEX 集成时，marker、签名 caller 列表、nonce 与退款字段请按 [`EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md`](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md) 实现。

## 3. SwapRequest 与执行限制

```solidity
struct SwapRequest {
    PoolKey key;
    bool zeroForOne;
    uint128 amountSpecified;
    uint128 limitAmount;
    uint64 deadline;
    uint256 expectedMultiplier;
}
```

- `amountSpecified` 是 exact-input 的 settlement token raw 数量，必须大于 0 且不超过 `int128.max`。
- `limitAmount` 是最小输出 raw 数量，不能为 0。
- `deadline` 为 Unix 秒。超过 deadline 时 Router 回滚。
- `expectedMultiplier` 应从 Registry 的 canonical U adapter 调用 `currentMultiplier(U)` 取得，并作为请求报价快照。Hook 会在 swap 前和记账时复核；变化时回滚。
- Router 设置方向对应的 V4 价格范围，并要求实际输入等于请求输入；部分成交回滚。无需也不能传入 exact-output 或用户价格限制字段。

成功返回 `(actualIn, actualOut)`。Router 没有独立 Swap 事件；成交量事件由 Ledger 发出：`VolumeUsed(securityId, poolId, ESTDay, amount)`。后端可结合 V4 Swap 事件、Router 返回值和 Ledger 事件对账。

## 4. Pool lifecycle、暂停和只读门禁

- `registry.isTradable(poolId)` 检查池注册、`LIST` lifecycle 与 security 的 TRADE pause。
- `registry.isLPAllowed(poolId)` 检查池注册、非 `DELIST` lifecycle 与 security 的 LP pause。
- `registry.isPaused()` 单独报告全局紧急暂停；不能从前两个 view 推断全局是否可执行。
- `SecurityPauseMode` 是写入最终状态：`NONE`/`TRADE`/`LP`/`ALL`。同值重复写入会回滚。
- `PoolLifecycle.PAUSE` 阻止 swap，普通 LP 仍可继续；`DELIST` 需要 Registry 记录的 position NFT 数为零。

资产被禁用用于新池注册，不会自动关闭已登记池。证券下架需要其所有池先变为 DELIST。

## 5. Volume Ledger 配置和读取

`currentESTDay()` 返回 `(block.timestamp - 5 hours) / 1 days`，是从 Unix epoch 起算的整数日，日界固定为 05:00 UTC（全年固定 UTC-5，不跟随夏令时）。始终以链上返回值定位当日状态。

`VOLUME_ORACLE_ROLE` 直接设置额度和修正使用量：

```solidity
struct DailyQuota { uint256 ESTDay; uint256 amount; }

ledger.setQuota(securityId, amount, reasonCode);
ledger.setUsedWad(securityId, values, reasonCode);
```

- `amount` 单位为 legal-share WAD；quota 没有 ADTV/Tier 派生公式，值直接覆盖。
- 每个 securityId 有一个每日 quota，设置后逐日沿用，直到再次修改；usedWad 按 securityId/ESTDay 独立存储。多个 W 和 pool 共用同一 securityId 的额度与用量。
- quota 缺省为 0，正数成交必须先设置 quota。
- `setQuota` 不改 `usedWad`；`setUsedWad` 可下调、清零或设置高于 quota 的值，之后的 swap 才按新状态检查。
- 两个 setter 都要求 `securityId` 和 `reasonCode` 非零。`setQuota` 立即生效，不能预设指定日期的额度。`setUsedWad` 的空数组不写入；未排序值按数组顺序处理；重复 ESTDay 最后一次写入生效。
- 额度交易发出 `QuotaSet`，用量修正发出 `UsedWadSet`，成交记账发出 `VolumeUsed`。

读取接口：`Quota(securityId)`、`usedWad(securityId, ESTDay)` 和 `currentESTDay()`。请使用部署 ABI 确认 `Quota` 大写 getter 名称。

## 6. 证券和资产配置

| 操作 | Registry API / 角色 |
| --- | --- |
| 注册 W 与新证券/追加 W | `registerPermissionedCurrency(param, tierId, reasonCode)` / `SYMBOL_ADMIN_ROLE` |
| 注册 Q | `registerQuoteToken(quote, reasonCode)` / `SYMBOL_ADMIN_ROLE` |
| 禁止 U/Q 加入新池 | `disableUnderlyingPoolRegister(u, reasonCode)`、`disableQuoteTokenPoolRegister(q, reasonCode)` / Symbol Admin |
| 更换 canonical legal-share Adapter | `replaceUnderlyingLegalShareAdapter(u, newAdapter, reasonCode)` / Symbol Admin |
| 更改最终 security pause mode | `applySecurityStatus(securityId, mode, reasonCode)` / `HALT_REPORTER_ROLE` |
| 设置或清除 global pause | `setEmergencyPauseEnable(enabled, reasonCode)` / pauser 或 resumer 分别授权 |
| 改 Pool lifecycle | `updatePoolLifeCycle` / `batchUpdatePoolLifeCycle` / Symbol Admin |

Registry 的管理事件和参数以 [`PERMISSIONED_REGISTRY_V1.md`](./PERMISSIONED_REGISTRY_V1.md) 为准。`applySecurityStatus` 的输入检查 reasonCode 非零，但 `SecurityStatusChanged` 事件本身没有 reasonCode 字段。

## 7. LP Manager 调用

- 由 `POOL_CREATOR_ROLE` 调用 `initializePool(key, sqrtPriceX96)` 登记并初始化 V4 池。
- 通过父类 ABI `modifyLiquidities(unlockData, deadline)` 或 `modifyLiquiditiesWithoutUnlock(actions, params)` 编码上游 V4 position actions。使用显式 `MINT_POSITION`/`INCREASE_LIQUIDITY`；`*_FROM_DELTAS` mint/increase 会被拒绝。
- 普通 position operation 检查执行者与 position owner 的 TSV `LIQUIDITY_ALLOWED`，再检查池 `isLPAllowed` 和 W issuer 权限。
- LP 用户付款经 immutable `TOKEN_APPROVE_PROXY.claimTokens`；用户授权地址是 `TOKEN_APPROVE_PROXY.tokenApprove()`，部署运维还需把 LP Manager proxy 加入 TokenApproveProxy allowlist。
- `withdrawClaim` 在 TSV LP Manager 中固定回滚。
- `unwindPosition` 由池内任一经验证 W adapter 的 owner 调用；`unwindPositionByOkx` 需 `FORCE_EXIT_ADMIN_ROLE`。都对原 LP owner 执行一次全仓退出；全局暂停会阻止调用。

强退无法保证所有 Token/仓位都成功：Q 可拒收转账，完整本金/费用 delta 可能越过 V4 `int128` 范围。后端不能把强退接口描述为无条件可用。

## 8. 代理和升级读取

`TSVERC1967Proxy.tsvImplementation()` 返回当前 implementation。其他地址从各代理 getter、Registry 绑定值和 implementation immutable 核对。Registry 是 AccessControl role root；组件升级角色从 Registry 查询。当前代码不支持 Governance Anchor、批量升级冻结或旧报告入口。

部署顺序和目标链检查见 [`DEPLOYMENT_CHECKLIST_V1.md`](./DEPLOYMENT_CHECKLIST_V1.md)。本地测试与真实目标链证据的边界见 [`IMPLEMENTATION_STATUS_V1.md`](./IMPLEMENTATION_STATUS_V1.md)。
