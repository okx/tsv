# TSVSwapRouterV1 逻辑 Review

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-02 |
| 审查基线 | Git HEAD `9f696db`；Router 文件按当前工作区内容审查（该文件有未提交修改） |
| 范围 | `src/v1/periphery/TSVSwapRouterV1.sol`，并核对 Hook、Registry、VolumeLedger、直接结算库及部署绑定 |
| 结论 | 未确认可利用的 Router 安全漏洞；发现若干重复读取、重复字段和可选接口整理点 |
| 验证 | 源码审查；未运行测试或构建 |

## 执行摘要

Router 的核心 Swap 路径连贯：入口校验用户、池和金额；PoolManager 在 `unlockCallback` 中执行 Swap；Hook 在 `afterSwap` 按实际 delta 记账；Router 再按相同 delta 结算两种 Currency。回调限制、重入锁、delta 符号、滑点和精确余额检查各自有作用，建议保留。

当前最明确的冗余是交易日读取及 Router 内的完整 PoolKey 重复比对。`SwapRequest` 也重复携带入口已经决定的 Swap 模式，以及当前实现强制相等的付款人、收款人地址。这些整理会改变请求 ABI；合约未部署时可以一并清理，但需要同步类型、脚本、文档和调用端。

## Review 项

### 1. 重复读取交易日，`exists` 分支当前不可达

`_validate()` 在进入 PoolManager 前调用 `ledger.currentTradeDay()` 并检查 `dayExists`；`_swap()` 在解锁后又调用一次，并用 `day` 写入事件。当前 [TSVVolumeLedgerV1.currentTradeDay()](../../src/v1/core/TSVVolumeLedgerV1.sol) 只会返回 `(true, day)` 或回滚，不会返回 `false`。Ledger 的 `recordSwap()` 也会为本次记账读取交易日。

因此 Router 的预检查没有独立拒绝效果。最小清理是删掉 `_validate()` 中的读取；保留 `_swap()` 的查询、事件日字段和 `exists` 检查，可维持当前事件并保留对未来 Ledger 实现的防御。若要进一步理顺接口，可让 `currentTradeDay()` 直接返回 `uint32`，同时更新 Router 和 Ledger 的调用点。

位置：[TSVSwapRouterV1.sol:114](../../src/v1/periphery/TSVSwapRouterV1.sol#L114)、[TSVSwapRouterV1.sol:119](../../src/v1/periphery/TSVSwapRouterV1.sol#L119)、[TSVSwapRouterV1.sol:137](../../src/v1/periphery/TSVSwapRouterV1.sol#L137)、[TSVVolumeLedgerV1.sol:219](../../src/v1/core/TSVVolumeLedgerV1.sol#L219)。

### 2. Router 的 PoolKey 全量比对重复

Router 由 `request.key.toId()` 得出 `poolId`，再对 `registry.getPool(poolId).key` 和请求 PoolKey 做哈希比较。Registry 也是用这个 `poolId` 存取 PoolConfig；PoolId 本身由完整 PoolKey 的字段哈希得到。成功 Swap 还必经 Hook 的 `beforeSwap`，其中再次检查 `isTradable(poolId)` 和精确 PoolKey。

Router 的 `getPool()`、完整结构解码和第二次哈希比较没有额外覆盖当前 Registry 不变量。可以移除这部分，同时保留 Hook 上的检查。Router 的 `isTradable()` 是另一项取舍：保留它可以在进入 PoolManager 前快速拒绝停用池；删除它可减少成功 Swap 的重复查询，但无效池会更晚在 Hook 中回滚。建议先移除完整 key 比对，是否移除 Router 的早期 `isTradable()` 按失败路径 Gas 与早拒绝体验决定。

位置：[TSVSwapRouterV1.sol:133](../../src/v1/periphery/TSVSwapRouterV1.sol#L133)、[TSVSwapRouterV1.sol:135](../../src/v1/periphery/TSVSwapRouterV1.sol#L135)、[TSVHookV1.sol:147](../../src/v1/core/TSVHookV1.sol#L147)。

### 3. `SwapRequest` 带有可由入口或调用者推出的字段

- `exactInput` 必须与 `swapExactInput` / `swapExactOutput` 的入口一致；入口已经决定模式，当前字段只用于重复核对和后续编码。
- `payer` 与 `recipient` 必须等于 `participant`，结算也始终使用 `participant`。
- 当前 Router 还要求 `participant == msg.sender`，所以在严格直连模式下，`participant` 本身也能由调用者得出。

若 V1 继续只允许参与者本人 Swap，可以将模式作为私有调用参数传入，并由 Router 把 `msg.sender` 作为参与者、付款方和收款方传给回调；外部 `SwapRequest` 可只保留池、方向、金额和限制字段。这会缩小请求 calldata 并消除模式不匹配路径，但会改变结构体 ABI 和函数 selector。若有意支持代付、代收或转发，则应单独定义授权语义，而不是保留当前永远相等的字段。

位置：[TSVTypes.sol:86](../../src/v1/types/TSVTypes.sol#L86)、[TSVSwapRouterV1.sol:71](../../src/v1/periphery/TSVSwapRouterV1.sol#L71)、[TSVSwapRouterV1.sol:80](../../src/v1/periphery/TSVSwapRouterV1.sol#L80)、[TSVSwapRouterV1.sol:127](../../src/v1/periphery/TSVSwapRouterV1.sol#L127)。

### 4. Router 保存的 Hook 地址是拓扑元数据，不参与 Swap 执行

Router 的 `hook` 仅在初始化时保存并通过 getter 暴露；Swap 代码不读取它。治理绑定和部署核验会用 `router.hook()` 检查连线，同时也核对 `hook.router() == router`、Registry/Ledger 指向 Hook 等关系。

这不是 Swap 路径上的安全检查，也不消耗每笔 Swap 的 Gas。若要简化组件配置，可删除 Router 存储与初始化参数，并同步移除治理 Anchor 接口、部署脚本和部署检查中的反向连线断言；Hook 对 Router 的正向引用仍能表达该连接。若保留双向拓扑核验，当前字段应按配置元数据理解，不应称为运行时 Swap 防护。

位置：[TSVSwapRouterV1.sol:29](../../src/v1/periphery/TSVSwapRouterV1.sol#L29)、[TSVSwapRouterV1.sol:44](../../src/v1/periphery/TSVSwapRouterV1.sol#L44)、[TSVGovernanceAnchor.sol:120](../../src/v1/governance/TSVGovernanceAnchor.sol#L120)、[DeployCoreV1.s.sol:195](../../script/DeployCoreV1.s.sol#L195)。

### 5. 结算库函数重复接收 Currency 和其地址

Router 将 `Currency.unwrap(currency)` 作为 `token` 传入结算库，而 `TSVDirectSettlementLib` 同时接收原始 Currency。当前 Router 和 LP Manager 都从同一个 Currency 派生该地址，因此参数重复，也留下了未来误传不匹配地址的空间。

可在共享结算库内部执行一次 `Currency.unwrap(currency)`，移除 `token` 参数并更新 Router 与 LP Manager 两个调用方。这是跨合约的小型接口整理，不改变结算规则。

位置：[TSVSwapRouterV1.sol:141](../../src/v1/periphery/TSVSwapRouterV1.sol#L141)、[TSVDirectSettlementLib.sol:15](../../src/v1/libraries/TSVDirectSettlementLib.sol#L15)、[TSVLPManagerV1.sol:288](../../src/v1/periphery/TSVLPManagerV1.sol#L288)。

### 6. 回调往返的 `BalanceDelta` 只用于外层事件

`unlockCallback()` 把 `actualIn`、`actualOut` 和完整 `BalanceDelta` 编码返回；`_swap()` 解码后仅用 delta 发出 `SwapExecuted`。若更看重回调编码简洁，可在回调完成双边结算后发出事件，让回调只返回公开函数所需的 `actualIn/actualOut`。

这属于较低优先级的结构/Gas 选择：事件会在 PoolManager 最后的 unlock 检查之前发出，但若该检查回滚，EVM 会一并回滚事件日志。需要权衡回调中增加事件逻辑与减少一段 delta 编码往返。

位置：[TSVSwapRouterV1.sol:109](../../src/v1/periphery/TSVSwapRouterV1.sol#L109)、[TSVSwapRouterV1.sol:111](../../src/v1/periphery/TSVSwapRouterV1.sol#L111)、[TSVSwapRouterV1.sol:117](../../src/v1/periphery/TSVSwapRouterV1.sol#L117)。

## 回调关联与 PoolManager 信任假设

Router 没有在存储中保存 request hash 或 `operationId`。在当前调用链中，Router 先验证请求，再用该请求调用 `PoolManager.unlock(abi.encode(request))`；指定 PoolManager 将同一份 `data` 交给 Router 的 `unlockCallback()`。回调还要求 `msg.sender == poolManager` 且 `entered == true`。因此在部署绑定的是预期 PoolManager、其按接口转发原始 data 的前提下，不需要额外状态 ID 来把请求绑定到回调。

Router 初始化本身只检查 PoolManager 有代码；PoolManager 实现身份由部署输入的代码哈希及部署核验承担。部署时应确保 `TSV_POOL_MANAGER_CODEHASH` 来自预期的官方/审计版本。若系统允许任意自定义 PoolManager，则它可以替换或重放 callback data；那会突破本协议的核心依赖信任假设，不是一个单靠 Router 里再加 `operationId` 就能完整修复的正常公开调用路径。

结算库也依赖获批 ERC-20 的 `balanceOf` 和转账语义保持稳定。若获批资产是可升级代理，代理 runtime codehash 不变时，升级仍可能改变这些行为；这是已有的 Registry 代币准入/发行方信任线索，不是 Router 新增的调用者漏洞。

## 需要保留的逻辑

以下检查各自约束不同边界，不建议为缩短代码而删除：

- `nonReentrant` 与 `unlockCallback` 中的 PoolManager / `entered` 检查：限制重入并确保回调处于 Router 发起的解锁过程中。
- 参与者资格、`msg.sender` 绑定、请求方向和金额限制：保证当前直连调用模型和 PoolManager signed amount 符合预期。
- delta 符号、精确输入/输出滑点检查，以及逐 Currency 结算：保证 Router 按实际成交而非请求估算结算。
- Hook `beforeSwap` 的调用方、可交易状态和精确 PoolKey 检查：它位于 PoolManager 的 Swap 边界；即使 Router 保留早期校验，也不能因此删掉 Hook 的拒绝能力。
- 代币转账前后的余额检查：验证 payer、PoolManager 和收款方的实际余额变化。

`participant == address(0)` 可从 `participant == msg.sender` 推出，但显式写出有助阅读，单独移除收益很小。Router 声明的 `SettlementMismatch()` 与共享库错误 selector 相同，测试和 ABI 消费端将其作为解码别名使用；该声明本身不产生运行时代码，不属于 Gas 清理重点。

## 极端数值边界（非资金漏洞）

若精确输出的实际输入恰为 `2^127`，`int128` 输入 delta 可表示为 `type(int128).min`。Router 先扩展至 `int256` 再取反，不会溢出；若用户提供足够大的 `limitAmount`，滑点检查本身可能通过，但当前 V4 PoolManager 在 `settle()` 中需把正付款量转为 `int128`，因此该值会回滚。代币转账、Swap 和 Ledger 记账均随交易原子回滚；本次审查未构造出能产生该 delta 的有效池状态。

如希望更早失败，可在结算前显式拒绝 `inDelta == type(int128).min`。这只改善极端请求的失败位置和诊断，不是资金安全修复的必要条件。

## 结论与建议顺序

先做不改变接口语义的清理：删除 `_validate()` 的重复交易日读取；删除 Router 的完整 PoolKey 解码/哈希比较，同时保留 Hook 边界检查。之后再决定是否在未部署的 V1 中收窄 `SwapRequest`，并协调删除 Router 的 Hook 元数据。其余点是低优先级的共享库或事件编码整理。

本报告是对指定工作区源码的静态 Review，不代替完整部署核验或测试；本轮没有修改 Solidity 源码，也没有运行测试或构建。
