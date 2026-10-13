# 外部 DEX Router 与 TSV Adapter

本仓库的 TSV 执行入口在 [`TSVSwapRouterV1.sol`](../src/v1/periphery/TSVSwapRouterV1.sol)。配套的 `TSVAdapter` 位于 pinned submodule `lib/dex-adapters/src/adapters/uniswap-v4/TSVAdapter.sol`。两处代码共同定义接口；历史 DEX 方案和旧 Router ABI 不适用。

## 调用链

```text
用户 → DexRouter / DynamicRoute → TSVAdapter → TSVSwapRouterV1
                                     ↓                  ↓
                                  U 或 Q              PoolManager → TSVHookV1 → VolumeLedger
```

Adapter 调用 `sellBase(to, pool, moreInfo)` 或 `sellQuote(...)`。`pool` 参数必须是 TSV Router 地址。`TSVAdapter.MoreInfo` 为：

```solidity
struct MoreInfo {
    ITSVSwapRouter.PoolKey key;
    uint256 expectedMultiplier;
    uint64 expiry;
    address[] allowedCallers;
    uint256 nonce;
    bytes authSig;
}
```

Adapter 的 signer 校验池 key、multiplier 和 expiry 的摘要、可信 caller 列表及 nonce。实际 `participant` 不在签名中；Adapter 从标准调用 calldata 尾部的 caller marker 取值，并且只接受 authSig 授权的 caller 集合。`ORIGIN_PAYER` marker 是退款地址，不能用于 participant/SBT 身份。

## Trailer 和输入

Adapter 要求 `sellBase`/`sellQuote` ABI calldata 后恰有两个 32-byte word：

1. `DEX_ROUTER_CALLER_MARKER | trustedCaller`；
2. `ORIGIN_PAYER | refundTo`。

标记外 padding 必须为零，尾部偏移按 `moreInfo` ABI 编码长度计算。集成时应按 `lib/dex-adapters` 的 `CallerAuth` 和 `TSVAdapter` 实现构造 trailer，不要用 `tx.origin`、`refundTo` 或未认证的 `to` 当参与者。

Adapter 将 PoolKey 股票侧 W 映射到 U，通过 `settlementCurrency` 得到真实输入/输出 Token。它以自身 `tokenIn` 全部余额作为 exact input，故调用前 DexRouter 必须把本 hop 输入转入 Adapter；余额为 0 或超过 `int128.max` 时拒绝。Adapter 只批准 TSV Router 花费这笔输入。

## TSV Router 请求

Router ABI 中的结构为 `SwapRequest(key, zeroForOne, amountSpecified, limitAmount, deadline, expectedMultiplier)`：

- `key` 是登记的 W/Q 池，`zeroForOne` 由 `sellBase`/`sellQuote` 方向确定；
- `amountSpecified` 是 U/Q settlement token 的 raw 输入量；
- `limitAmount` 是 Router 最小池内输出量；此 Adapter 使用非零最小值 `1`，产品滑点由 DexRouter 对最终输出检查；
- `deadline` 由该 Adapter 设为当前区块时间；上游交易 deadline 仍由 DexRouter 检查；
- `expectedMultiplier` 从签名的 `MoreInfo` 读取，Hook 在执行前和记账时比较 U Adapter 的实时值。

Adapter 调用 `swapExactInputFromContract(request, participant)`。只有 `isAdapterAllowed(adapter) == true` 的合约能调用；Router 从 Adapter 余额扣输入，将输出返回 Adapter，再由 Adapter 将本次输出增量交给 `to`。Router 要求 `actualIn == amountSpecified`，所以 TSV 路径必须全额成交；不足额不是成功退款场景，而是整笔回滚。Adapter 还核对输出余额 delta 和输入剩余余额，避免发送历史 dust。

Router 另有 `swapExactInputFromContractDirect(request, payer, participant, recipient)`：U 输入时 payer 为零，调用前 U 必须已存入 W；Q 输入时 payer 必须是调用 Adapter；`recipient` 必须等于 participant。Q 在 `PoolManager.sync` 后由 Router 直接从 payer 转入 PoolManager。一般外部 DexRouter hop 使用 `swapExactInputFromContract`，由调用 Adapter 付款并接收输出。两者都依赖 Router Adapter allowlist、TSV SBT 权限、W issuer 权限、池 lifecycle、暂停和当日 quota。

## 管理与验收

1. 部署外部 `TSVAdapter`，设置 TSV Router 地址和后端 auth signer。
2. Registry Default Admin 调用 `router.setAdapterAllowed(adapter, true)`。
3. 检查外部 DexRouter caller 生成的尾部 marker、签名字段、nonce 和金额单位；确认 participant 来自已认证 caller marker。
4. 核对 Router 的 `settlementCurrency(W) == U`、Q 原样返回，W `swappingEnabled` 和 issuer checker 权限就绪。
5. 在目标链分别验证两种交易方向、用户/Adapter 余额增量、失败回滚、`VolumeUsed` 和 quota；记录真实地址及交易证据。

该仓库的本地 DexAdapter 集成测试不构成 X Layer 部署或外部 DexRouter 地址核验。当前 `test/integration/xlayer/` 没有可执行 fork 测试。
