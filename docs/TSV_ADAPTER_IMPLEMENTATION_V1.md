# TSVAdapter 集成实现

TSVAdapter 源码来自 `lib/dex-adapters` 子模块，仓库当前固定版本为上游签名金额实现。Adapter 通过 `swapExactInputFromContractDirect` 连到 TSV Router，并继承 `CallerAuth`。

## 签名与精确输入

`MoreInfo` 包含 PoolKey、`expectedMultiplier`、精确 `amountIn`、`allowedCallers`、nonce、deadline 和 64 字节 EIP-2098 `authSig`。签名摘要绑定 Adapter 地址、链 ID、池、方向、参与者、Adapter 的 `to`、数量、multiplier、deadline、caller 列表和 nonce。成功 nonce 不能重放；失败交易会回滚 nonce。

Adapter 在买入时检查自己的 Q 余额，在卖出时检查 `max(U.balanceOf(W) - W.totalSupply(), 0)`。余额至少覆盖签名金额才继续，并且只使用该金额，因此本笔不会自动扫走多出的 U 或 Q。卖出 U 由 DexRouter 预存进 W；买入 Q 预存进 Adapter。输出由 TSV Router 直接发给 participant，符合其收款人规则。

## 权限与前置条件

- TSV Router 的 `isAdapterAllowed(adapter)` 与 Adapter 的 `isDexRouter(dexRouter)` 是两层独立白名单。
- `allowedCallers` 必须含实际 `msg.sender`，生产单跳操作器将其设为 X Layer `DEX_ROUTER`。
- participant 来自已校验的 DexRouter caller marker；Registry SBT、W 发行方权限、Hook multiplier、池状态和 Volume Ledger quota 仍由 TSV 协议检查。
- Adapter 的 `AUTH_SIGNER()` 是构造时固定的。签名私钥只留在后端/本地 `.env.xlayer`，其派生地址必须匹配链上 getter。
- 此版本构造函数增加 `authSigner`，部署 ABI 与旧版不兼容。旧 Adapter 不可升级，需重新部署并更新 adapter 地址及两层 allowlist。

完整 ABI、签名字段顺序、资金路径和操作器行为见 [`EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md`](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md)。本仓库的本地回调集成夹具位于 `test/helpers/v1/TSVAdapterFixture.sol` 和 `test/integration/local/trading/DexAdapter.t.sol`。
