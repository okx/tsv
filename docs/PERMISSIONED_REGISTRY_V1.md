# Registry 与 W/U/Q 准入

本文描述 [`TSVRegistryV1.sol`](../src/v1/core/TSVRegistryV1.sol) 及其链接的 [`PermissionedValidationLib.sol`](../src/v1/libraries/PermissionedValidationLib.sol)。代码内没有 DataInbox、治理 Anchor、市场报告或准入待审状态；管理员通过 Registry 的角色受限方法直接更新状态。

## 1. 资产关系

| 名称 | 地址/来源 | Registry 保存内容 |
| --- | --- | --- |
| W | Permissions Adapter Factory 创建并验证的 permissioned stock adapter | `currencyUnderlying[W] = U` |
| U | W 包装的原始股票 token | `securityId`、`rawDecimals`、canonical `legalShareAdapter`、新池 `registered` 标志 |
| Q | 非股票 quote ERC-20 | `rawDecimals`、新池 `registered` 标志 |

一个 U 只能映射到一个 securityId、精度和法律股数 Adapter；同一 U 的多个 W 共享这些配置。每个 PoolKey 必须包含且仅包含一只 W 和一个 Q，并将 PoolKey 的完整 hash 作为 poolId。池内使用 W/Q 计价与结算，Swap Router 在 W 腿向用户收付 U。

## 2. 初始化和依赖绑定

1. 通过 `initialize(admin)` 初始化 Registry。admin 获得 `DEFAULT_ADMIN_ROLE` 和 `UPGRADE_ADMIN_ROLE`。
2. 外部部署并配置 PoolManager、Permissions Adapter Factory、SBT、Hook 和 LP Manager。
3. Default Admin 调用一次 `bindComponents(hook, lpManager, factory, sbt)`。Registry 从 Factory 读取 PoolManager，探测 SBT 的 `paused()` 与 `verify()` 接口并保存依赖。
4. Registry 的 W/Q 准入和池登记在依赖绑定后才可进行。

`bindComponents` 不绑定 Router、Ledger，也不校验所有组件之间的完整交叉引用。其余地址在各自 initializer 或 implementation immutable 中配置，部署后的地址核对属于运维责任。

## 3. 注册证券和 W

`registerPermissionedCurrency(PermissionedRegisterParam param, uint8 tierId, bytes32 reasonCode)` 由 `SYMBOL_ADMIN_ROLE` 调用。`param` 包含 `currency`（W）、`securityId` 和 `legalShareAdapter`。首次注册在一次调用中创建该证券记录、分配 tier 容量并注册 W；以后添加 W 时证券必须仍上市且 tier 必须相同。

链接库按 Factory 状态读取 U 并验证 W 已登记且已验证；再核对 W 的 PoolManager/U 地址、allowlist checker 接口、U/W decimals 一致且不超过 18、legal-share Adapter 的 ERC-165 和 `poolCurrency() == U`。同一 U 后续注册的 W 必须继续使用相同 securityId、decimals 和 adapter。

链上检查不证明发行方 checker 的业务规则、U 的转账特性、W 的抵押/供应经济安全或 Adapter 所采用的法律股数定义。生产准入须逐项核对真实合约和发行方材料。

## 4. 注册 Q 与 Pool

- `registerQuoteToken(q, reasonCode)` 由 Symbol Admin 调用；Q 必须是有代码、非系统地址、非 W/U 的 ERC-20。Registry 读取并保存 decimals（最大 18）。
- `TSVLPManagerV1.initializePool(key, sqrtPriceX96)` 是池登记入口。LP Manager 检查 `POOL_CREATOR_ROLE` 后调用 Registry `registerPool(key)`，并在同一交易内调用 PoolManager `initialize`。
- Registry 要求调用者为绑定 LP Manager；key 使用绑定 Hook；资产地址排序、fee 和 tick spacing 合法；两侧均已登记且正好一侧为 W、一侧为 Q；证券仍上市；poolId 未用过。
- 新池生命周期为 `LIST`，注册时保存 securityId 和 tier 快照。任何初始化失败都会回滚本次 Registry 注册。

## 5. SBT 身份

Default Admin 使用 `setSbtConfig(tokenId, permissions, reasonCode)` 登记或更新 tokenId。允许权限位为 `NONE`、`SWAP_ALLOWED`、`LIQUIDITY_ALLOWED` 或两者并集。`permissionsOf(owner)` 将 owner 当前持有的所有已登记身份权限按位 OR；如果 SBT 的 `paused()` 为 true，则返回 `NONE`。`hasCredential` 只回答持有任一身份，不代表持有某项操作权限。

Router 以 participant 检查 `SWAP_ALLOWED`。普通 LP action 以执行者及仓位 owner 检查 `LIQUIDITY_ALLOWED`；W 还根据发行方 checker 与 `swappingEnabled` 执行独立门禁。SBT 权限和发行方权限必须分别满足。

## 6. Securities、暂停与 pool lifecycle

- `SecurityPauseMode` 是当前最终值：`NONE` 不暂停，`TRADE` 停止 swap，`LP` 停止普通 LP，`ALL` 两者都停。`applySecurityStatus` 要求证券上市并由 `HALT_REPORTER_ROLE` 调用。
- `PoolLifecycle` 与 security pause 独立：`LIST` 允许继续检查；`PAUSE` 禁止 swap 但允许普通 LP；`DELIST` 禁止普通 swap 和 LP。
- `isTradable` / `isLPAllowed` 根据已知池、lifecycle 和 security pause 返回结果；全局 `emergencyPauseEnable` 需另用 `isPaused()` 检查。
- 启用/解除全局暂停分别要求 `EMERGENCY_PAUSER_ROLE` / `EMERGENCY_RESUMER_ROLE`。全局暂停阻止 Router、Hook、LP Manager 的执行入口，包括强退入口。
- 设置池为 DELIST 要求该池 `tickCount == 0`。该计数由 LP Manager 在 mint/burn position NFT 后更新，不代表 V4 价格 ticks。`delistSecurity` 还要求该 security 的所有注册池 lifecycle 已 DELIST。

`disableUnderlyingPoolRegister(U, reasonCode)` 和 `disableQuoteTokenPoolRegister(Q, reasonCode)` 只禁止以后注册池，不关闭既有池。清除资产新池注册状态不会自动暂停或移除其旧池。

## 7. 与额度和法律股数的关系

Registry 仅把池映射到 securityId。Hook 使用 `getUnderlying(U).legalShareAdapter` 将真实 W delta 换算为 legal-share WAD，再由 Ledger 对该 securityId 执行日额度检查。这里没有 ADTV/tier 配额公式、reportId、来源时间或拆并股报告。Quota 由 `VOLUME_ORACLE_ROLE` 直接写入 Ledger；详见 [`BACKEND_INTEGRATION_GUIDE_V1.md`](./BACKEND_INTEGRATION_GUIDE_V1.md)。

替换 Adapter 会立即影响之后的成交换算，不迁移既有 usedWad。运营方须审查单位口径变化及当日额度影响后再替换。

## 8. 准入风险边界

源码 NatSpec 明示以下准入约束，链上无法完整强制：

1. 不得将历史登记过的 Q 重新用作 W 或 U。当前 quote 记录没有永久的“曾为 Q”标记；复用可能使现存旧池绕过新的 security、quota、multiplier 和 issuer 管控。
2. Q 的转账接收方不能通过 receiver-controlled 行为拒绝 LP 收款。quote 退出没有 adapter owner 兜底，拒收会回滚强退并恢复 position NFT。
3. 发行方 Token 和 quote 必须在 LP 全仓退出所需额度下兼容 PoolManager 的 `int128` delta 限制。代码不提供授权的分段强退。
4. U/Q 的 raw 余额和双向转账应符合精确 ERC-20 结算预期。税费、rebase、黑名单、升级后改变转账规则等行为不是 Registry 校验项。

以上风险要求链下准入策略、发行方确认和持续监控，不可从本地 mock 测试推断已满足。测试所在层级见 [`../test/README.md`](../test/README.md)。
