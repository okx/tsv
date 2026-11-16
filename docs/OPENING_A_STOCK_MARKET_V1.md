# 按当前合约开通 W/Q 股票池

本文是基于当前 Registry、Hook、Router、LP Manager 和 Ledger 入口整理的运维顺序，不是自动化部署脚本或目标链验收记录。当前源码没有 DataInbox、ADTV 报告、首开市场报告、治理 Anchor 或可执行 X Layer fork 测试。

## 1. 确认资产与外部依赖

在链下完成 Token 和发行方审查，确定：

- W：由已绑定 Factory 创建并验证的 permissioned stock adapter。
- U：W 包装的原始股票 token；W/U decimals 相同且不超过 18。
- Q：作为另一侧池资产的 quote ERC-20；decimals 不超过 18。
- Adapter：实现 `IDirectLegalShareAdapter`，`poolCurrency()` 返回 U，且当前 multiplier 与 `toLegalShares` 语义一致。
- SBT：实现 Registry 使用的 `paused()` 和 `verify(address,uint256)`。

还须确认 U/Q raw 转账、发行方 checker、W wrapping、LP 强退收款和法律股数单位。Registry 仅执行代码中列出的地址、Factory、接口和 metadata 检查，不能替代这些审查。

## 2. 部署当前组件

按目标链发布流程先确定 PM、Permissions Adapter Factory 和 SBT，再部署 Registry、Ledger、Router、LP Manager、Hook 及实现合约。Registry proxy 必须通过 `initialize(admin)` 创建；其余 proxy 也须带正确 initializer。

注意以下代码约束：

- Hook proxy 地址低 14 位须为 `0x3FFF`。使用 `TSVHookProxyFactoryV1.predict/deploy` 与最终 initializer calldata 一起预计算地址。
- Router implementation constructor 固定 PoolManager 和 Factory；`initialize(pm, registry)` 中的 PM 必须一致。
- LP Manager implementation constructor 固定 PM、Factory、Registry 等集成参数；proxy 使用 `initialize(registry)`。
- Hook initializer 绑定 PM、Registry、Ledger、Router 和 LP Manager。
- Registry 使用 `bindComponents(hook, lpManager, factory, sbt)` 一次绑定 Hook、LP Manager、Factory、Factory 的 PM 和 SBT。该函数不绑定 Router 或 Ledger。

`docs/DEPLOYMENT_MANIFEST_V1.example.json` 是当前五组件的发布记录模板，不会部署合约，也不构成实际部署证据。仓库尚无与当前源码匹配的完整生产部署脚本；发布前须按当前 constructors/initializers 编写并独立审查部署自动化。

## 3. 配置权限和发行方组件

在 Registry 授予最小所需的 `SYMBOL_ADMIN_ROLE`、`POOL_CREATOR_ROLE`、`HALT_REPORTER_ROLE`、`EMERGENCY_PAUSER_ROLE`、`EMERGENCY_RESUMER_ROLE`、`FORCE_EXIT_ADMIN_ROLE`、`VOLUME_ORACLE_ROLE` 和 `UPGRADE_ADMIN_ROLE`。所有相关组件通过 Registry 读取角色；Default Admin 负责 role grants。

由发行方 owner 配置 W 的 allowlist checker、`swappingEnabled`、Router wrapper 和 Hook allowlist。LP Manager 需要被 W 允许作为 wrapper；用户的发行方 checker 需允许 swap/LP 对应权限。发行方侧设置与 Registry 的 TSV SBT 权限彼此独立。

LP 付款人须对 U 和 Q 直接授权 LP Manager **proxy 地址**；LP Manager 使用 `transferFrom` 将 U 送入 W 并 wrap，或将 Q 送入 PoolManager。Swap 付款人（调用 Router 的已授权 Adapter）对输入 U/Q 另行授权 Router **proxy 地址**。不要只给 implementation 授权。

## 4. 登记 SBT、Tier 和资产

1. Default Admin 为需使用的 SBT tokenId 调用 `setSbtConfig(tokenId, permissions, reasonCode)`。仅 `SWAP_ALLOWED`/`LIQUIDITY_ALLOWED` 两个位参与 TSV 检查；暂停的 SBT 会使有效权限归零。
2. Default Admin 配置非零 `tierId` 的 `setTierPolicy(tierId, maxListed, reasonCode)`。
3. Symbol Admin 调用 `registerQuoteToken(Q, reasonCode)`。
4. Symbol Admin 调用 `registerPermissionedCurrency({currency: W, securityId, legalShareAdapter}, tierId, reasonCode)`。首次调用会新建并上市 security；后续同 security 添加 W 必须使用相同 tier、U、decimals 和 adapter。
5. 确认 Router `isAdapterAllowed(adapter)` 及 Registry `getCurrencyUnderlying(W)`、`getUnderlying(U)`、`getQuoteToken(Q)` 等读取结果。

上述写入口的 `reasonCode` 必须非零。Registry 接纳 W/Q 仅代表合约准入条件通过，不代表链下发行方、转账风险或法律标准审查通过。

## 5. 创建池、额度并开始交易

1. 组装排序后的 `PoolKey(currency0, currency1, fee, tickSpacing, hook)`；两种 Currency 必须是 W 和 Q，Hook 必须是绑定的 TSV Hook。
2. 由 `POOL_CREATOR_ROLE` 调用 `LPManager.initializePool(key, sqrtPriceX96)`。Registry 注册池和 PoolManager 初始化在一个交易内完成。
3. 通过标准显式流动性 action 注入 LP；股票腿 U 和 Q 的用户付款依赖对 LP Manager proxy 的直接 ERC-20 allowance。position owner 与 action executor 均需 TSV LP SBT 权限，W 和 Hook 的 issuer/hook allowlist 也需就绪。
4. `VOLUME_ORACLE_ROLE` 在 Ledger 调用 `setQuota(securityId, amount, reasonCode)`。quota 是 legal-share WAD 的直接值，不从 ADTV/tier 自动计算；设置后逐日沿用直到再次修改，默认 0 会阻止正成交量。
5. 在 Router 上 allowlist 外部 Adapter。Adapter 请求提供 W/Q PoolKey、方向、raw input、最小 raw output、deadline 和 U Adapter 当前 multiplier 快照。

Swap 必须全额消耗输入，且满足最小输出。Hook 用真实 W PoolManager delta 转换并记账；多个 W 和多个池共用该 securityId 的日额度。运营需监控 `VolumeUsed` 并使用 `setUsedWad` 修正时留存原因码和审计记录。

## 6. 暂停、下架和强退

- 证券操作暂停使用 `applySecurityStatus(securityId, NONE/TRADE/LP/ALL, reasonCode)`，每次写入最终模式。
- 全局暂停使用 `setEmergencyPauseEnable(true, reasonCode)`；解除由单独的 `EMERGENCY_RESUMER_ROLE` 执行。
- 池 lifecycle 由 Symbol Admin 改成 `PAUSE`、`LIST` 或 `DELIST`。新建池默认 `LIST`；DELlST 需先退出并 burn 所有 position NFT，使 `tickCount == 0`。
- `unwindPosition` 由 W/Q permissioned adapter owner 发起；`unwindPositionByTsv` 由 `FORCE_EXIT_ADMIN_ROLE` 发起。两者均全仓退出并把资产交回原 NFT owner；quote 收款拒绝或 `int128` delta 溢出可能使退出回滚。全局暂停会阻止两条强退入口。

## 7. 验收记录

部署后将实际地址、交易哈希、实现地址、immutable 值、Registry 绑定、角色/SBT/W 配置、PoolKey、Quota 和真实资产测试结果保存在受控 release record 中。检查点至少包括：

- 每个 proxy 的 `tsvImplementation()` 与源码/编译产物匹配；Hook proxy flags 为 `0x3FFF`；
- Registry、Factory、PM、SBT、Hook、Router、LP Manager、Ledger 绑定地址相符；
- 目标用户和发行方对真实 W 的权限分别通过；真实 U/Q 授权及正/反向 Swap 均完成；
- 当日 quota 前后 `usedWad`/`VolumeUsed` 一致；不满足 quota、暂停和最小输出时整笔交易回滚；
- LP 正常出入和两条强退均在真实资产上测试，并评估 quote 收款限制和大仓位 delta 限制。

该清单仅定义应留存的证据。仓库当前没有这些目标链执行结果；不得将本地 mock/PoolManager 测试描述为生产验收。
