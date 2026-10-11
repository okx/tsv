# 外部 DEX Router / Adapter 接入 TSV

> **2026-10-07 Wrapped Swap 更新：** Registry 与单池 Wrapped Swap 已实现，用户收付 U/Q，池内结算 W/Q。当前 ABI、库链接与验收边界见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)，当前运营步骤见 [W/U/Q 开通流程](./OPENING_A_STOCK_MARKET_V1.md)。下文旧 DIRECT、TokenConfig/getToken、DEX 与 LP 成功路径属于历史版本；生产 Wrapped LP 及真实资产/目标链验收仍待交付，历史测试数量不代表当前覆盖。

> 当前接入实现已固定为上游 `TSVAdapter` 提交 `e38c6b109875893ad037677eb8d8221fa4b5687b`，详见 [实现与测试依赖](./TSV_ADAPTER_IMPLEMENTATION_V1.md)。下文为早期方案记录；其中追加 amountIn、moreInfo 自带滑点和固定 DexRouter 地址的要求不适用于该实现。当前使用现有两个 marker、输入币余额和后端签名授权，DexRouter 合约不需为 TSV 追加金额字段。

本文说明本仓库 `TSVSwapRouterV1` 的 Adapter 入口。当前工作区同步修改了 `lib/dex-adapters` 中的 TSVAdapter 接口调用；外部 `GitHub-Web3-DEX-EVM` 的 DexRouter 源码不在本次改动范围内。

`SwapRequest` ABI 包含 `expectedMultiplier`。外部 Router 直付入口可传入报价快照；本 TSVAdapter 在调用 Router 前，从 Registry 所登记的 canonical 股票 Adapter 读取当前 multiplier 并放入请求，Hook 再校验执行期间的快照一致性。

## 调用链

```text
用户 / AA
  → 外部 DexRouter
  → 外部 TSV Adapter
  → TSVSwapRouterV1.swapExactInputFromContract
  → V4 PoolManager / TSV Hook
  → TSV Adapter
  → 外部 DexRouter 指定的 hop 收款地址
```

外部 DexRouter 继续使用现有 `IAdapter.sellBase` / `sellQuote` 调用约定。DexRouter 把本 hop 输入预转入 TSVAdapter；Adapter 对 Router 授予精确额度，Router 从调用 Adapter 拉取 settlement token 输入并把输出返给 Adapter；Adapter 校验本次余额变化后，将输出转给 `to`。`participant` 仍从已验证的 caller marker 提取，仅用于 SBT 与发行方权限检查，不承担付款，也无需给 TSV Router 授权。

## TSV Router 接口

Adapter 入口复用 `SwapRequest`，字段顺序如下：

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `key` | V4 `PoolKey` | 要交易的 TSV 池 |
| `zeroForOne` | `bool` | 交易方向 |
| `amountSpecified` | `uint128` | 本入口中表示精确输入金额 |
| `limitAmount` | `uint128` | 本入口中表示最小输出金额 |
| `deadline` | `uint64` | 请求过期时间 |
| `expectedMultiplier` | `uint256` | TSVAdapter 调用前从 Registry 所登记股票侧 Adapter 读取的当前 Multiplier |

TSVAdapter 调用 `swapExactInputFromContract(request, participant)`。Router 仅接受 `setAdapterAllowed(adapter, true)` 已授权的调用地址；白名单由 Registry `DEFAULT_ADMIN_ROLE` 控制。Router 对 `participant` 执行 SBT 资格检查，从调用 Adapter 拉取 `amountSpecified` 输入，并把 Swap 输出返给该 Adapter。输入必须全额成交且达到 `limitAmount`；未全额成交时整笔交易回滚。价格边界由 Router 根据方向设置为 V4 的全范围边界。

Adapter 入口只支持 exact-in：`amountSpecified` 表示 Adapter 的 settlement token 输入量，`limitAmount` 表示最小池内输出量。Router 还保留 participant 直付入口；普通用户不能直接调用 Swap，也没有 exact-output 入口。调用方需按上述字段顺序编码匹配的 ABI tuple；入口不接收 `sqrtPriceLimitX96`。

## 外部 Adapter 仓库工作

在 `GitHub-Web3-DEX-Adapters-EVM` 增加 TSV Adapter，并完成以下事项：

1. 实现现有 `IAdapter.sellBase` 和 `sellQuote`，分别映射到对应的 TSV 交易方向；只支持 exact-input。
2. 仅允许配置的外部 DexRouter 调用 Adapter。解析 DexRouter 附加在 calldata 尾部的 caller marker，并将 marker 中的原始调用者作为 `participant` 传入 TSV Router。
3. 按当前 TSVAdapter ABI 构造 `SwapRequest`；在调用前从 Router Registry 找到唯一股票侧 underlying 及其 canonical Adapter，读取 `currentMultiplier(underlying)` 填入 `expectedMultiplier`。Router 不使用报价币 multiplier。Adapter 当前以本合约对应 settlement token 的余额作为本 hop exact input；拒绝零金额及超出 `int128.max` 的金额。
4. DexRouter 先把本 hop 输入转入 TSVAdapter；Adapter 只批准 Router 支出本次 `amountIn`。Router 从调用 Adapter 拉取输入并把成交输出返给 Adapter；Adapter 验证输入/输出余额变化后，把本次输出交给 `to`。当前 Main Router 要求输入全额成交，因此不足额时 Router 整笔回滚。
5. 按部署链配置 TSV Router 地址、DexRouter 地址及 TSV 池参数，并登记/发布 Adapter 的链上地址和所需路由元数据。

身份字段必须使用 `DEX_ROUTER_CALLER_MARKER`，不可使用 `ORIGIN_PAYER` 作为 SBT 身份。当前外部 DexRouter 的 `CommonLib.exeAdapter` 把原始调用者写入 caller marker；`ORIGIN_PAYER` 写入的是 `refundTo`，在特定路由模式下可以与原始调用者不同。calldata 尾部保持 `ABI calldata || DEX_ROUTER_CALLER_MARKER+caller || ORIGIN_PAYER+refundTo`，Adapter 从 `-64`、`-32` 字节读取字段。Adapter 还必须限制直接调用来源为配置的 DexRouter，避免任意调用者伪造尾部字段。

## 外部 DexRouter 仓库工作

在 `GitHub-Web3-DEX-EVM` 中，现有 Solidity `IAdapter` 分发入口继续调用 `sellBase` / `sellQuote`，不需要新增供用户直接调用的 DexRouter 方法；但内部 Adapter 调用 helper 需要附加精确 hop 输入量。需要配合 Adapter 团队完成：

- 保持现有 `IAdapter.sellBase/sellQuote` calldata 与两个尾部 marker；本 TSVAdapter 按当前 settlement token 余额确定本次输入，无需新增 amount 参数或更改尾部偏移。
- 在路由配置与构造工具中识别 TSV Adapter，并生成其 `moreInfo` 数据。`moreInfo` 绑定池、有效期、可信调用方集合及 nonce；输入金额不放入签名 payload。
- 保留 `CommonLib.exeAdapter` 附加的原 64 字节尾部字段；不要把退款地址 marker 当作用户 SBT 身份。
- 确保 DexRouter 的 hop 预转账与 TSVAdapter 的 `settlementCurrency` 一致：股票 PoolKey W 的外部结算资产是 U，报价币 Q 仍为 Q。Adapter 从余额推导本 hop exact input，并把输出 delta 转给 `to`。
- 确认 `sellBase` / `sellQuote` 与 Adapter 解码的交易方向一致；整体最小回报和交易 deadline 由外部 DexRouter 检查。

除非外部 Router 的部署或路由配置另有准入要求，Adapter 与 TSV Router 的授权分别由其自身配置完成：外部 Adapter 限定可信 DexRouter 调用来源，具有 Registry `DEFAULT_ADMIN_ROLE` 的管理员将该 Adapter 地址加入 TSV Router 白名单。

## 部署与运行要求

1. 部署 TSV Router 实现升级，并确认代理 ABI 包含 `swapExactInputFromAdapterDirect`、`swapExactInputFromContract` 与 `setAdapterAllowed`。
2. 部署外部 TSV Adapter，配置对应外部 DexRouter 与 TSV Router。
3. 由具有 Registry `DEFAULT_ADMIN_ROLE` 的管理员调用 `setAdapterAllowed(adapter, true)`；撤销时调用 `setAdapterAllowed(adapter, false)`。
4. 在外部路由配置中启用该 Adapter 后，先确认调用用户、Adapter、输入结算、输出转发及 commission 收款地址与预期一致，再开放交易。

白名单只授权 Adapter 合约地址，用户身份仍由 Adapter 从可信 DexRouter caller marker 中解析，并由 TSV Registry 做 SBT 校验。TSV Hook 和 Volume Ledger 继续按实际 PoolManager delta 执行既有交易限制及成交量记账。
