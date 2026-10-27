# DexRouter 与无签名 TSVAdapter

Adapter 子模块固定到 `80800d56`，买卖均不需要后端签名。构造参数为 `(tsvRouter, initialOwner, dexRouter)`。已部署的旧签名版本不可升级，使用前须配置匹配的新版地址、Adapter 的 DexRouter 白名单和 TSV Router 的 Adapter 白名单。

## MoreInfo

```solidity
struct MoreInfo {
    ITSVSwapRouter.PoolKey key;
    uint256 expectedMultiplier;
    uint256 amountIn;
}
```

使用 `abi.encode(info)`；不包含 allowedCallers、nonce、deadline、authSig。此前七字段签名结构与当前三字段 ABI 不兼容。PoolKey 保持 W/Q，expectedMultiplier 由报价提供并由 TSV Hook 与实时值比较。

- 卖出 U → Q：DexRouter 将 U 直接转入 W，assetTo = W。MoreInfo.amountIn 等于本跳准确输入，须大于 0、不超过 int128.max，并不超过 `max(U.balanceOf(W) - W.totalSupply(), 0)`。仅兑换指定金额，保留剩余 U。
- 买入 Q → U：assetTo = Adapter，MoreInfo.amountIn 填 0；执行时使用 Adapter 的实时 Q 全余额。U 直接付给 participant，Q allowance 在执行后清零。

**SDK amount_in / TSV_DEX_AMOUNT_IN 在两侧都仍是正数的实际 DexRouter 入金金额**，不能因为买入 MoreInfo.amountIn 为 0 就把外层金额也设为 0。deadline_seconds 和 min_return 继续用于外层交易有效期和滑点保护。

participant 来自白名单 DexRouter 的 caller marker。to 在执行时确定；单跳操作器仍要求 participant、receiver 为实际交易钱包。买入输出 U 的收款人还受 TSV Router 限制。TSV 的 SBT、证券状态、日额度、multiplier 和全额成交检查继续生效。

## 操作与迁移

只需交易钱包 XLAYER_PRIVATE_KEY，不再需要 TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY。菜单 14 不再询问 nonce；Python DexRouterTradeRequest 删除 nonce 参数。脚本编码三字段 MoreInfo，检查两层白名单、TokenApproveProxy 和 W/U 映射，先模拟，再由用户输入 BROADCAST 才广播。

精确金额不等于资金归属或签名授权：W 的富余 U 不按用户记账，错误的较大 amountIn 仍可能消耗历史资金；买入则使用全部 Q。Adapter 无 nonce 防重放或独立授权 deadline，相同 payload 在资金充足时可重复执行。金额、身份和用户交易授权依赖可信 DexRouter。

本次 SDK 更新不自动更换 deployment.json 的线上地址；使用前应填写与新版 ABI 一致、已完成加白的部署地址。测试使用本地 TSV fixture 和实际 Adapter，无需私钥，不广播链上交易。
