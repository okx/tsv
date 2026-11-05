# TSV V1 资产准入检查

本文将 [`TSVRegistryV1`](../src/v1/core/TSVRegistryV1.sol) 与 [`PermissionedValidationLib`](../src/v1/libraries/PermissionedValidationLib.sol) 实际检查的条件，与必须由运营/法务/发行方在链下核实的事项分开。代码入口不构成法律或经济安全批准。

## 1. 当前池资产模型

| 符号 | 合约中的意义 | 池/用户行为 |
| --- | --- | --- |
| W | Factory 创建且验证的 Permissions Adapter | V4 PoolKey 中的股票侧 Currency；Issuer checker 决定用户权限 |
| U | W 包装的 underlying ERC-20 | Router 输入/输出股票腿时使用的结算 Token；也是法律股数 Adapter 的绑定地址 |
| Q | Registry 独立登记的 quote ERC-20 | V4 PoolKey 中的报价侧 Currency，用户侧也以 Q 结算 |

Registry 只允许 W/Q 两侧各一，不支持 U/Q 池、两只股票池或任意池资产组合。若一只股票有多个 W adapter，它们必须共享同一个 U、securityId、raw decimals 和 legal-share adapter。

## 2. 链上准入校验

### W 与 U

`registerPermissionedCurrency({currency: W, securityId, legalShareAdapter}, tierId, reasonCode)` 由 Symbol Admin 调用。链接库检查：

- W 是 Factory 记录且已验证的 adapter，Factory 所用 PM 与 Registry 绑定值一致；
- W 的 `POOL_MANAGER()` 与 `PERMISSIONED_TOKEN()` 指向配置 PM 和 Factory 派生的 U；
- W 和 U 是有代码、不同且非 TSV 系统地址的资产；
- W 的 checker 有代码并实现 `IAllowlistChecker`；
- W/U `decimals()` 相同且不超过 18；
- legal-share adapter 有代码，ERC-165 声明 `IDirectLegalShareAdapter`，并返回 `poolCurrency() == U`；
- U 尚未登记为其他 security/W，也不是已登记 quote。

新 security 的首次登记会连同首个 W 上市并占用 tier 名额；给既有 security 添加 W 时，security 必须仍上市并沿用 tier。所有 registry 写入口的 reasonCode 必须非零。

### Q 与 PoolKey

`registerQuoteToken(Q, reasonCode)` 检查 Q 有代码，且不属于当前识别出的系统地址、W 或 U 身份，并读取 `decimals() <= 18`。未在 Factory 标为 adapter 的普通 token 可以作为 Q；Registry 无法证明它的 ERC-20 转账语义。

由 LP Manager 登记 PoolKey 时，Registry 校验 Hook 地址、currency 排序、fee、tickSpacing、W/Q 准入、恰有一侧 W，以及所属 security 仍上市。初始 lifecycle 为 `LIST`。池初始化与登记在同一交易内。

## 3. legal-share Adapter

接口为 [`IDirectLegalShareAdapter`](../src/v1/interfaces/IDirectLegalShareAdapter.sol)：

```solidity
function poolCurrency() external view returns (address);
function currentMultiplier(address currency) external view returns (uint256);
function toLegalShares(address currency, uint256 rawAmount) external view returns (uint256);
```

`ERC8056DirectLegalShareAdapter` 构造时绑定单一 U 并限制 decimals 不超过 18；每次调用读取 U 的 `uiMultiplier()`，要求 multiplier 非零，按 `floor(rawAmount * multiplier / 10**decimals)` 转成 WAD。非零 raw 输入若向下取整到 0 会回滚。

Registry 只验证接口和地址绑定；它不验证 multiplier 单位是否代表法律股数，也不校验未来值是否平滑、稳定或由发行方批准。Hook 对 Router 提交的 `expectedMultiplier` 作执行时一致性检查，不能代替法律定义审查。

## 4. 需要链下审核的行为

逐个真实资产和发行方核验并保存证据：

- 真实 U/Q 的 transfer/transferFrom 精确、无税费、无 rebase 或隐式余额变化；升级、暂停、黑名单和收款拒绝能力；
- W 的 Factory 身份、抵押资产、供应量不变量、`swappingEnabled`、allowed wrapper/hook、issuer checker 规则及 owner 控制；
- SBT 的 verify/pause 行为、tokenId 发布政策、权限撤销和生产合约地址；
- `uiMultiplier` 的单位、精度、更新权限、变化时点、最坏 gas 和转换公式是否适用于额度与法律报告；
- full-position forced exit 能否收到 Q/U，真实仓位本金和累积费用是否可能越过 PoolManager 单次 `int128` delta；
- Token / proxy / checker 后续升级或权限修改的持续监控和暂停响应。

这些属性没有由 Registry 完整执行。普通 ERC-20 接口存在、Factory 验证成功、本地 mock 测试通过，都不代表上述风险已排除。

## 5. 代码可见的高风险边界

1. Quote 地址只保留当前 `registered` 状态。禁用的历史 Q 地址不能因此重新用于 W 或 U；旧池仍能使用该 Q，而新 security 的控制不会自动覆盖旧池。
2. `unwindPosition` 的 Q 侧没有 adapter-owner claim fallback。若 LP 可拒绝转账，退出回滚并恢复 NFT/Registry 计数；pool/security 下架可能因此受阻。
3. 强退使用一次完整 position burn，不提供授权的分块操作。最大仓位本金或已累积费用过大时，V4 delta 可能超过 `int128` 范围并使强退回滚。
4. 关闭 U/Q 新池登记不会暂停既有池。需要停止旧池时，须单独更新 pool lifecycle 或 security pause。

## 6. 审批和运行后的持续核验

注册前由运营角色确认身份、单位和权限；交易开放前还要登记当日 Ledger quota、启用 W swaps、配置 W 的 issuer/hook/wrapper 权限、设置 Router Adapter allowlist 并验证 SBT。运行中对 Factory/W ownership、checker、Token implementation/multiplier、SBT pause、池状态和实际失败率持续监控。资产或单位假设变化时，应按审批流程停止受影响操作并重新审查。

代码准入入口和事件见 [`PERMISSIONED_REGISTRY_V1.md`](./PERMISSIONED_REGISTRY_V1.md)；当前部署步骤见 [`OPENING_A_STOCK_MARKET_V1.md`](./OPENING_A_STOCK_MARKET_V1.md)。
