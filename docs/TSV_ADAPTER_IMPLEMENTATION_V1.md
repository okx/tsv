# TSV Adapter 源码位置与接口

当前 Adapter 实现在 pinned submodule [`lib/dex-adapters`](../lib/dex-adapters/)，源码为 `src/adapters/uniswap-v4/TSVAdapter.sol`；与当前 TSV Router 的连接规范见 [`EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md`](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md)。submodule 版本以仓库 gitlink 和 `git submodule status` 为准，不以本说明里的历史提交号为准。

## 当前实现

`TSVAdapter` 实现外部 `IAdapter.sellBase` / `sellQuote`，通过 `ITSVSwapRouter.swapExactInputFromContract` 连接 TSV。它只支持单池 exact-input：方向取自入口；PoolKey 和 `expectedMultiplier` 由 `MoreInfo` 提供；输入 Token 由 Router `settlementCurrency(W)` 映射为 U，Q 保持原地址。

`MoreInfo` 由 `PoolKey`、multiplier 快照、签名到期时间、允许 caller 列表、nonce 和签名组成。CallerAuth 将 adapter 地址、链 ID、allowedCallers、nonce 和 `(key, expectedMultiplier, expiry)` 摘要纳入验证。调用者名单包含实际 `msg.sender` 才能通过；nonce 为单次使用。Adapter 从经验证的尾部 marker 获取 SBT participant，退款地址 marker 只用于输入退款。

Adapter 使用自身 settlement-token 全部余额作为输入，并拒绝 0 或大于 `int128.max` 的金额。Router 仍要求全额成交；Adapter 检查 Router 返回量、余额 delta 并只把当前交易的输出增量发送给 `to`。TSVAdapter 使用最小非零 `limitAmount`，产品滑点和外层 deadline 由 DexRouter 处理。

## 边界

- Router 必须先把 Adapter 地址加入 `isAdapterAllowed`；此 TSV allowlist 与签名 `allowedCallers` 是两层不同授权。
- 外部 DexRouter caller marker 的产生/尾部排列由 DexRouter 协议与 Adapter 的 `CallerAuth` 实现共同决定；不要从本文推导其他 Adapter 的 marker 规则。
- SBT 的 participant 身份检查由 TSV Router/Registry 执行，issuer swap permission 由 W 执行。后端应确认 signer、可信 caller 集合和 Adapter 部署地址。
- 本文描述源码，不构成某个 Adapter、DexRouter、TSV Router 或 signer 已在目标链部署并相互授权的证据。

相关 Adapter 单元/集成测试位于 submodule 的 `test/adapters/uniswap-v4/TSVAdapterUnit.t.sol`、`Tsv.t.sol` 和 `TsvTestBase.sol`。本仓库自身的本地合约集成测试位于 `test/integration/local/trading/DexAdapter.t.sol`。
