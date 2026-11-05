# `market_rebalancer.py` 实现逻辑说明

本文按当前代码和配置说明 `market_rebalancer.py` 的实际执行流程。重点覆盖报价获取、池价计算、偏离判断、交易参数生成、模拟与广播，以及运行边界。交易相关内容以代码为准；配置或外部数据源变化后，应重新核对。

## 1. 程序用途和模式

程序有两种模式：

| 模式 | 行情 | X Layer RPC | 交易 |
|---|---|---|---|
| `prices-only` | 获取所选股票的行情并输出 JSON | 不连接 | 不读取池状态、不交易 |
| `rebalance` | 获取行情并读取对应池状态 | 检查链 ID、读取 PoolManager 与 Registry | 偏离达到阈值且报价足够新时，模拟后广播 swap |

`--environment production|test` 选择默认配置，分别对应 `production_config.json` 和 `test_config.json`；也可用 `ROBINHOOD_ENV` 设置默认环境。显式传 `--config` 时优先使用该路径。环境名只选择配置，不改变 X Layer 链。`--once` 让程序处理一轮后退出；未指定时按配置中的 `interval_seconds` 持续轮询。默认资产来自所选配置的对象顺序；`--assets` 可选择其中部分资产。

再平衡模式必须显式传入正数 `--max-trade-notional-usd`（兼容旧别名 `--trade-notional-usd`）。它是最大输入金额。程序根据参考价和 `rebalance_target_deviation_percent` 计算目标 `sqrtPriceX96`，然后调用带价格限制的 exact-input 路径：输入金额仅作为上限，PoolManager 到达目标价后停止，并只结算实际消耗的输入。Foundry 模拟必须证明目标价可达，且最终带 `minAmountOut` 的模拟再次达到目标，才会广播。目标不可达、报价金额不足或模拟失败时不会广播。`rebalance_target_deviation_percent` 默认 1%，作为目标残余偏离；`--slippage-bps` 默认 100，即 1%。配置中的触发偏离门槛当前为 8%，单资产冷却时间为 900 秒，交易 deadline 为 300 秒。

价格限制由 TSV Router 的 `swapExactInputToPrice` 支持。该接口把请求输入当作上限，目标价格由 `sqrtPriceLimitX96` 硬性限制；证券底层输入只在 PoolManager 确认实际债务后转入并包装，避免目标价提前到达时扣除未使用输入。旧版 Router 代理不包含此入口，必须先部署并升级到包含该方法的实现，脚本才可用于广播。升级前脚本模拟会报方法不存在，不能使用旧版 Router 降级执行。

## 2. 配置与资产数据源

配置文件默认为同目录下的 `production_config.json`，可用 `--config` 覆盖。当前资产配置摘要如下：

| 股票 | 行情来源 | 报价口径 | 自动交易报价年龄上限 |
|---|---|---|---:|
| MSTR | Robinhood Stock Token `/rhj/prices/MSTR` | bid/ask 中间价，采用 `generatedAt` | 90 秒 |
| BTGO | MarketBeat 股票页 | 报价横幅 Fair Market Value，采用 `As of` 时间 | 120 秒 |
| SECZ | MarketBeat 股票页 | 报价横幅 Fair Market Value，采用 `As of` 时间 | 120 秒 |

MSTR 和 BTGO 配置了 `pool_id` 供计算结果校验；SECZ 当前配置 PoolKey，但没有配置预期 `pool_id`，因此只按该 PoolKey 计算池 ID。三者都配置 UnderlyingToken、quote currency、wrapped currency、fee、tick spacing 和 hook。当前 `quote_usd` 为 `1`，程序据此把 quote token 单价按 1 美元处理。

配置中的 `prices_cache_seconds` 当前没有被程序读取。实际行情限频由 `min_poll_seconds` 和 `max_requests_per_minute` 控制。

## 3. 行情请求与新鲜度

### 3.1 请求客户端

`MultiSourcePriceClient` 对允许的 Robinhood、MarketBeat、MEXC HTTPS URL 发起请求。客户端设置浏览器式 User-Agent、20 秒请求超时，并执行两层限频：

1. 每个 URL 按其 `min_poll_seconds` 单独限频。当前 MarketBeat 每页至少间隔 60 秒，Robinhood 至少间隔 15 秒。
2. 所有报价请求共享一个滚动 60 秒窗口。配置值会被限制在最多 30 次/分钟。

HTTP 状态错误会变成可读异常。`urllib` 网络错误时，程序使用参数数组调用系统 `curl` 重试，不经过 shell；curl 失败时把两端错误写入诊断信息。URL 前缀不在 allowlist 时直接拒绝。

### 3.2 Robinhood

`get_robinhood_quote` 校验 ticker 字符格式，然后请求 `/rhj/prices/{symbol}`。它从返回的 `quotes` 中选择 `tokenSymbol` 与 ticker 相同的行，并要求货币为 USD、市场未暂停、bid 为正且 ask 不低于 bid。价格计算为：

```text
market_price = (bid + ask) / 2
```

报价时间直接取 API `generatedAt`。字段缺失、时间格式错误或行情条件不符时抛错，不会拿其他字段兜底。

### 3.3 MarketBeat

`get_marketbeat_quote` 用 `PageText` 去除脚本、样式和标签，合并可见文本。它只匹配报价横幅中的价格变动、百分比和 `As of [MM/DD/YYYY] hh:mm AM/PM Eastern`；页面省略日期时使用读取时的东部日期。不再使用 analyst summary 中的 current price，也不会把收盘价当作盘中报价。

解析到多个匹配项时取文本中的最后一项。将页面时间解析为 `America/New_York` 时区时间后计算报价年龄。页面被改版、没有带时间的报价横幅、价格无效或时间过旧时，不会继续使用历史值；没有匹配项会抛出错误。

代码还保留 `mexc` provider 分支：它解析带 UTC 时间的 MEXC 页面报价，并根据时间选择 regular、pre-market 或 after-hours 数据。当前配置没有资产使用该分支。

### 3.4 新鲜度字段

`freshness()` 将报价时间统一换算为 UTC，计算 `age_seconds`。未来超过 10 秒的时间戳被视为无效；报价超过该资产的 `max_trade_age_seconds` 时，仍返回行情，但将 `trade_eligible` 设为 `false`。因此在再平衡模式中，旧报价不会触发交易。

## 4. 再平衡模式启动和逐资产流程

进入 `rebalance` 后，程序先加载 Web3，选择 RPC：优先使用进程环境变量 `XLAYER_RPC_URL`，否则使用配置中的 `rpc_url`。连接失败或 `chain_id` 不等于配置的 196 时，程序在处理资产前退出。

每轮按所选资产逐个执行下列步骤：

1. 获取该股票行情并准备一条输出 JSON。
2. 读取并验证对应 v4 池状态。
3. 把池价换算成美元，与行情参考价比较。
4. 按新鲜度、偏离门槛和冷却状态决定 HOLD、跳过或构造交易。
5. 对可执行交易先做 Foundry 模拟；模拟成功后再广播。

`prices-only` 在第 1 步输出后就进入下一资产，不会执行链上步骤。

## 5. PoolKey、PoolId 与池价读取

`inspect_pool()` 依次执行以下检查和读取：

1. 对 currency0、currency1 做 checksum 格式化，并要求 `currency0 < currency1`（按地址数值比较）。
2. 用 ABI 编码 `(address,address,uint24,int24,address)` 后计算 keccak，得到 PoolId。若配置了预期 `pool_id`，则比较二者。
3. 通过 PoolManager 的 `extsload` 读取 `keccak256(abi.encode(poolId, 6))` 对应状态槽。低 160 bit 解为 `sqrtPriceX96`，其后的 24 bit 解为有符号 tick；零 `sqrtPriceX96` 代表池未初始化。
4. 读取 Registry 的 Hook，并要求它同时匹配所选配置和 PoolKey。再读取 `router.registry()` 并要求与配置 Registry 一致。若资产配置 `security_id`，则读取 `getUnderlying(UnderlyingToken)` 并校验 securityId 与 registered 标志。对两个 pool currency 调用 `getCurrencyUnderlying`，要求恰好有一个映射到配置中的 UnderlyingToken；并要求 Registry 的 `isTradable(poolId)` 为真。
5. 读取 `keccak256(abi.encode(poolId, 6)) + 3` 对应的 active liquidity slot。该值为当前 tick 可用的活跃流动性；为零时程序跳过交易。
6. 读取两个 pool currency 的 decimals，以及 UnderlyingToken 的 decimals。

价格换算采用 v4 的 Q96 表示：

```text
rawPrice1Per0 = (sqrtPriceX96 / 2^96)^2
humanPrice1Per0 = rawPrice1Per0 × 10^(decimals0 - decimals1)
```

若股票 W 是 currency0，股票价格为 `humanPrice1Per0`；若股票 W 是 currency1，股票价格取其倒数。结果是每股对应的 quote token 数量。美元池价为：

```text
pool_price_usd = pool_quote_per_stock × quote_usd
```

本配置令 `quote_usd=1`。若 quote token 不等于美元稳定币，必须更新该参数或补充真实汇率来源，否则偏离判断不再代表美元偏离。

## 6. 偏离率、方向和交易金额

偏离率定义为：

```text
deviation_percent = (pool_price_usd / reference_price_usd - 1) × 100
```

当前门槛为 `abs(deviation_percent) >= 8`：

- 偏离为负：池价低于外部参考价，动作是 `BUY_STOCK`。
- 偏离为正：池价高于外部参考价，动作是 `SELL_STOCK`。
- 小于门槛：保持 `HOLD`。

`build_trade()` 根据参考价和目标残余偏离计算目标池价，并按最大美元额度限制输入量。目标原始价格按 `currency1/currency0 = (quote_usd / target_stock_usd) × 10^(decimals1-decimals0)` 换算。随后读取目标 tick 范围内的初始化 tick 与 `liquidityNet`，按各段活跃流动性和池 fee 直接累计 exact-input 数量；若流动性在目标之前归零，则报告目标价超出可用流动性，不发起模拟或交易。当前 Router 不支持 `swapExactInputToPrice`，故用计算出的金额调用支持的 `swapExactInput` 做 sizing 模拟，读取实际输出并按滑点容差计算最低输出，再模拟最终交易；仅最终模拟成功才广播。普通 exact-input 交易没有链上价格停止保证。Rebalance 模式会在 stderr 实时输出行情抓取、链上读取、输入计算、模拟和最终广播阶段，JSON 结果仍输出到 stdout。实现假设 PoolKey 中 quote 为 currency0、股票 W 为 currency1：

| 动作 | `zero_for_one` | 输入金额 | 最小输出 |
|---|---:|---|---|
| 买入股票 | `true` | min(到目标价所需 quote, 单笔上限) | 按参考价估值并扣除滑点容差的股票数量 |
| 卖出股票 | `false` | min(到目标价所需股票, 单笔上限) | 按 quote 美元价估值并扣除滑点容差的 quote 数量 |

最小输出按向下取整，输入转换为整数。输入或最小输出取整后为零时拒绝构造交易。TradeRequest 包含 PoolKey、方向、输入量、最小输出量和 deadline 秒数。

**方向依赖配置的币种排序。** 当前 MSTR、BTGO、SECZ PoolKey 都是 quote currency 为 currency0、wrapped stock currency 为 currency1。若以后更换成相反顺序，当前方向判断和 `zero_for_one` 逻辑需要同步改写；虽然 `inspect_pool()` 会计算出正确方向的池价，但 `build_trade()` 不会自动根据 currency index 推导方向。

## 7. 冷却、模拟和广播

偏离达到门槛后，先检查报价是否 `trade_eligible`，再检查池是否有 active liquidity，最后检查该 ticker 的冷却时间。若 active liquidity 为零，输出 `skipped_no_active_liquidity`，不构造或模拟 swap。冷却计时使用进程内单调时钟；Router 交易回执确认成功后记录冷却时间，然后读取池状态。冷却字典保存在内存中，进程重启后会清空。

`execute_trade()` 创建 `TradeRequest`，再构造 `Operation(Target.TRADE, ..., request.env())` 并调用项目 `tsv_xlayer_sdk`：

1. SDK 确认目标为 allowlist 中的 `TradeTSV.s.sol:TradeTSV`。
2. 调用 `simulate()`，通过 Foundry 执行脚本但不带 `--broadcast`。模拟失败时抛错，不进入广播。
3. `broadcast()` 要求目标是写操作、模拟成功，且调用者传入的确认字必须精确为 `BROADCAST`。它重新读取执行环境并比较操作指纹；如果模拟后环境或输入变化则拒绝广播。
4. 程序把所选配置中的 Router 和 Hook 传入 SDK operation inputs，覆盖部署 JSON、`.env.xlayer` 和进程环境中的默认值。RPC URL 只从进程环境读取；若调用者没有设置 `XLAYER_RPC_URL`，程序先将所选配置的 RPC URL 写入进程环境。校验通过后，SDK 以 `forge script ... --broadcast` 执行 `TradeTSV`。

SDK 从部署 JSON 读取公开部署环境，从 `script/xlayer/.env.xlayer` 读取允许的本地环境项，再以进程环境覆盖；操作输入最后合并。写操作要求 `XLAYER_PRIVATE_KEY`，私钥不放入 TradeRequest 参数。SDK 会对 Foundry 输出中的密钥和 RPC URL 做遮蔽。

`TradeTSV` 脚本还会检查 chain ID 196、router 和 hook 合约代码、Registry hook 一致性、Registry 未暂停、池可交易、trader 有 `SWAP_ALLOWED` 权限、池中恰有一个股票 currency、Underlying 已注册且 Adapter 存在、quote 输入已注册、账户输入余额足够，并按需设置 allowance 后调用 `swapExactInput`。因此即使 Python 的前置检查通过，Foundry 模拟仍可能因链上权限、余额、Registry 或交易条件失败而拒绝。

## 8. 输出与错误行为

每个成功报价输出一行 JSON，包含资产、ISIN、来源、价格口径、参考价、时间戳、报价年龄和 `trade_eligible`。价格模式到此结束。再平衡模式还会输出 PoolId、tick、池价、偏离率、动作和执行状态；含 bid/ask 的 Robinhood 报价会额外输出 bid/ask。

常见执行状态包括：

| 状态 | 含义 |
|---|---|
| `HOLD` | 偏离未到门槛 |
| `skipped_stale_price` | 报价年龄超过阈值 |
| `cooldown` | 尚在该 ticker 冷却时间内 |
| `broadcast_confirmed` | 广播命令与链上 Router receipt 均成功 |
| `broadcast_cli_error_but_confirmed` | Foundry 命令返回非零，但本次新生成的 artifact 对应 Router 交易已由链上 receipt 确认成功 |

单资产处理中捕获网络错误、HTTP 错误、超时、运行时错误、值错误和 Decimal 错误，写一行错误 JSON 到 stderr 后继续下一个资产。广播确认后若池状态回读失败，错误 JSON 仍保留已确认的交易 hash 和 receipt。一次性模式会在这一轮所有资产处理完后退出。某些未被捕获的异常（例如不符合预期结构的 JSON 导致的 `KeyError`）可能使进程直接退出。

每次广播前，程序记录现有 Foundry broadcast artifact 指纹；广播后只接受本轮新建或变更的 artifact 中 Router 交易 hash，不会拿旧的 `run-latest.json` 冒充本轮交易。无论 Foundry 命令返回成功还是非零，程序都等待该 Router hash 的链上 receipt。若命令非零但 receipt `status=1`，输出 `broadcast_cli_error_but_confirmed` 并继续池状态回读；若 receipt 失败、artifact 缺失或 RPC 无法确认，则输出 `stop_and_reconcile_before_retry`，禁止自动重试。确认交易后，若池状态回读失败，错误 JSON 会保留交易 hash 和成功 receipt，明确标记 `failed_after_confirmed_broadcast`。冷却仍在确认广播后启动。

## 9. 重要假设与限制

- 外部股票价和池价是两个来源：MSTR 使用 Robinhood，BTGO/SECZ 使用 MarketBeat；报价口径、时间戳精度和数据延迟不完全相同。
- MarketBeat 页面解析依赖报价横幅文案和布局；找不到带日期的 `As of` 横幅会报错，不应通过放宽成分析摘要或收盘价来绕过。
- Robinhood 与 MarketBeat 报价年龄分别受配置的 90 秒和 120 秒限制；轮询间隔不等于来源报价刷新频率。
- 命令行名义金额参数是单笔最大值，不是固定交易额。预估量由偏离和 active liquidity 共同决定；程序通过 swap 改变价格，不直接写 `sqrtPriceX96`。
- 交易方向目前依赖 quote 为 currency0、股票 W 为 currency1 的配置约定。
- active liquidity 是当前 tick 的池状态值；零表示当前价格附近没有可执行 swap 的活跃流动性，但不能据此断言全池没有任何处于区间外的 LP position。
- `trade_cooldown_seconds` 只在当前进程内有效，无法阻止重启后的重复交易。
- 再平衡配置必须提供 RPC URL、Registry、Router、Hook 和 PoolManager。Python 链上读取使用配置 RPC（若设置了 `XLAYER_RPC_URL` 环境变量则以它为准）；SDK 的 RPC URL 从进程环境读取，程序在缺少该环境变量时才以配置 RPC 设置进程默认值。每笔操作显式传入所选配置的 Router 和 Hook。启动时会打印所选部署地址，链上预检查会比对 Router→Registry、Registry Hook 和 PoolKey Hook。
- 程序有 receipt 确认和交易后池价回读；没有持久化重试队列或跨重启冷却记录。

## 10. 主要代码入口

| 函数 | 职责 |
|---|---|
| `load_config` / `load_web3` | 加载 JSON 配置、懒加载 Web3 依赖 |
| `pool_id` / `inspect_pool` | 计算 PoolId、读取 packed slot、Registry 与池价 |
| `PageText` / `MultiSourcePriceClient` | HTML 可见文本处理、网络请求、限频和 curl fallback |
| `get_robinhood_quote` / `get_marketbeat_quote` / `get_mexc_quote` | 各行情源解析与校验 |
| `freshness` / `get_market_quote` | 报价时间检查、按 provider 分发 |
| `build_trade` | 依据偏离、active liquidity 和单笔上限估算交易量并构造 TradeRequest |
| `execute_trade` / `wait_for_trade_receipt` | SDK Foundry 模拟、广播及交易回执确认 |
| `main` | 参数校验、RPC 初始化、轮询、偏离决策和 JSON 输出 |

