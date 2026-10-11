# 外部 DEX Router / Adapter 接入 TSV

> **2026-10-07 Wrapped Swap 更新：** Registry 与单池 Wrapped Swap 已实现，用户收付 U/Q，池内结算 W/Q。当前 ABI、库链接与验收边界见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)，当前运营步骤见 [W/U/Q 开通流程](./OPENING_A_STOCK_MARKET_V1.md)。下文旧 DIRECT、TokenConfig/getToken、DEX 与 LP 成功路径属于历史版本；生产 Wrapped LP 及真实资产/目标链验收仍待交付，历史测试数量不代表当前覆盖。

> 当前接入实现已固定为上游 `TSVAdapter` 提交 `e38c6b109875893ad037677eb8d8221fa4b5687b`，详见 [实现与测试依赖](./TSV_ADAPTER_IMPLEMENTATION_V1.md)。下文为早期方案记录；其中追加 amountIn、moreInfo 自带滑点和固定 DexRouter 地址的要求不适用于该实现。当前使用现有两个 marker、输入币余额和后端签名授权，DexRouter 合约不需为 TSV 追加金额字段。

本文说明本仓库 `TSVSwapRouterV1` 的 Adapter 专用入口，以及外部 `GitHub-Web3-DEX-Adapters-EVM` 和 `GitHub-Web3-DEX-EVM` 需要配合的工作。外部仓库不在本次 Solidity 改动范围内。

`SwapRequest` ABI 新增 `expectedMultiplier`，外部 Adapter 与客户端需要使用更新后的 ABI，并携带**报价时**观察到的股票侧 multiplier；若在提交交易时才读取当前值，就无法拒绝报价后发生的变化。固定比例 Adapter 传入其配置比例，零值会被 Hook 拒绝。

## 调用链

```text
用户 / AA
  → 外部 DexRouter
  → 外部 TSV Adapter
  → TSVSwapRouterV1.swapExactInputFromAdapterDirect
  → V4 PoolManager / TSV Hook
  → TSV Adapter
  → 外部 DexRouter 指定的 hop 收款地址
```

外部 DexRouter 继续使用现有 `IAdapter.sellBase` / `sellQuote` 调用约定，但 TSV Router 唯一入口从 participant 拉取本 hop 输入，并将输出直接发送给 Adapter 指定的 `to`。因此 participant 必须持有输入 Token 并提前授权 TSV Router；Adapter 余额不作为输入来源。对于输入由 DexRouter 或 Adapter 持有的中间跳，不能使用此入口；路由集成必须确保输入仍可由 participant 支出。

## TSV Router 接口

Adapter 入口复用 `SwapRequest`，字段顺序如下：

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `key` | V4 `PoolKey` | 要交易的 TSV 池 |
| `zeroForOne` | `bool` | 交易方向 |
| `amountSpecified` | `uint128` | 本入口中表示精确输入金额 |
| `limitAmount` | `uint128` | 本入口中表示最小输出金额 |
| `deadline` | `uint64` | 请求过期时间 |
| `expectedMultiplier` | `uint256` | 报价时从 Registry 所登记股票侧 Adapter 读取并保留的 Multiplier |

Adapter 调用 `swapExactInputFromAdapterDirect(request, participant, recipient)`。Router 仅接受 `setAdapterAllowed(adapter, true)` 已授权的调用地址；该函数及撤销操作 `setAdapterAllowed(adapter, false)` 仅 Governor 可调用。Router 对 `participant` 执行 SBT 资格检查，从 participant 拉取 `amountSpecified` 输入，并把 Swap 输出直接交给 `recipient`。输入必须全额成交且达到 `limitAmount`；部分成交时整笔交易回滚，不需要 Adapter 退款。价格边界由 Router 根据方向设置为 V4 的全范围边界。

Adapter Swap 入口只支持 exact-in：`amountSpecified` 表示输入量，`limitAmount` 表示最小输出。Router 不提供普通 Adapter 出资模式、用户直调或 exact-output 入口。调用方需按上述字段顺序编码匹配的 ABI tuple；入口不接收 `sqrtPriceLimitX96`。

## 外部 Adapter 仓库工作

在 `GitHub-Web3-DEX-Adapters-EVM` 增加 TSV Adapter，并完成以下事项：

1. 实现现有 `IAdapter.sellBase` 和 `sellQuote`，分别映射到对应的 TSV 交易方向；只支持 exact-input。
2. 仅允许配置的外部 DexRouter 调用 Adapter。解析 DexRouter 附加在 calldata 尾部的 caller marker，并将 marker 中的原始调用者作为 `participant` 传入 TSV Router。
3. 构造共享 `SwapRequest` 时保留报价阶段取得的股票侧 `expectedMultiplier`，不能在执行阶段用刚读取的当前值替换它。该值对应 Registry 所登记的股票侧 Adapter，不使用报价币的 Multiplier。输入金额与最小输出分别写入 `amountSpecified` 和 `limitAmount`；不得从 Adapter 总余额推断输入量，也不得让请求用既有余额补足本 hop 金额；拒绝零金额及超出 TSV 支持范围的金额。
4. 确保 participant 已授权 TSV Router 支出本 hop 输入；Adapter 不为 Router 设置输入 allowance，也不承担输入退款。Router 将成交输出直接送往 `to`，Adapter 不暂存或转发输出。
5. 按部署链配置 TSV Router 地址、DexRouter 地址及 TSV 池参数，并登记/发布 Adapter 的链上地址和所需路由元数据。

身份字段必须使用 `DEX_ROUTER_CALLER_MARKER`，不可使用 `ORIGIN_PAYER` 作为 SBT 身份。当前外部 DexRouter 的 `CommonLib.exeAdapter` 把原始调用者写入 caller marker；`ORIGIN_PAYER` 写入的是 `refundTo`，在特定路由模式下可以与原始调用者不同。尾部扩展后布局为 `ABI calldata || amountIn || DEX_ROUTER_CALLER_MARKER+caller || ORIGIN_PAYER+refundTo`，因此 Adapter 分别从 calldata 的 `-96`、`-64`、`-32` 字节读取三个字段。Adapter 还必须限制直接调用来源为配置的 DexRouter，避免任意调用者伪造尾部字段。

## 外部 DexRouter 仓库工作

在 `GitHub-Web3-DEX-EVM` 中，现有 Solidity `IAdapter` 分发入口继续调用 `sellBase` / `sellQuote`，不需要新增供用户直接调用的 DexRouter 方法；但内部 Adapter 调用 helper 需要附加精确 hop 输入量。需要配合 Adapter 团队完成：

- 给 `CommonLib.exeAdapter` 增加 `amountIn` 参数；在 `DagRouter` 与 `SmartSwapRouter` 的 Adapter 调用点，把刚刚转到 `assetTo` 的实际 `_fromTokenAmount` 传入。
- 在 ABI 编码的 Adapter calldata 与两个既有尾字段之间追加 32 字节 `amountIn`。保持最后 64 字节仍为原 caller marker 和 `ORIGIN_PAYER`，使旧 Adapter 继续按原偏移读取。
- 在路由配置与构造工具中识别 TSV Adapter，并生成其 `moreInfo` 数据；`amountIn` 从链上实际 hop 转账量生成，不从 `moreInfo` 接受。
- 保留 `CommonLib.exeAdapter` 附加的原 64 字节尾部字段；不要把退款地址 marker 当作用户 SBT 身份。
- 确保 hop 输入仍由 `participant` 持有且已授权 TSV Router 支出；不得先把输入转到 Adapter/DexRouter。Adapter 传入的 `recipient` 应是该 hop 目标地址。若外部 DexRouter 固定先把输入转给 Adapter 或中间 hop 由 DexRouter 持有，则该路由与当前直接结算入口不兼容，必须调整路由资金来源。
- 在 `moreInfo` 中提供最小输出、deadline 与完整池参数；确认 `sellBase` / `sellQuote` 与 Adapter 解码的交易方向一致。

除非外部 Router 的部署或路由配置另有准入要求，Adapter 与 TSV Router 的授权分别由其自身配置完成：外部 Adapter 限定可信 DexRouter 调用来源，TSV Governor 将该 Adapter 地址加入 TSV Router 白名单。

## 部署与运行要求

1. 部署 TSV Router 实现升级，并确认代理 ABI 包含 `swapExactInputFromAdapterDirect` 与 `setAdapterAllowed`。
2. 部署外部 TSV Adapter，配置对应外部 DexRouter 与 TSV Router。
3. 由 TSV Governor 调用 `setAdapterAllowed(adapter, true)`；撤销时调用 `setAdapterAllowed(adapter, false)`。
4. 在外部路由配置中启用该 Adapter 后，先确认调用用户、Adapter、输入结算、输出转发及 commission 收款地址与预期一致，再开放交易。

白名单只授权 Adapter 合约地址，用户身份仍由 Adapter 从可信 DexRouter caller marker 中解析，并由 TSV Registry 做 SBT 校验。TSV Hook 和 Volume Ledger 继续按实际 PoolManager delta 执行既有交易限制及成交量记账。
