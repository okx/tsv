# RWA market maker (X Layer / TSV v4)

当前目录通过 `market_rebalancer.py` 读取股票参考价、监控 TSV v4 池价，并可在显式选择 `rebalance` 模式时，对偏离阈值的池子执行模拟和广播。

## 环境与配置选择

```sh
# 生产配置：production_config.json（默认）
python3 outputs/rwa-market-maker/market_rebalancer.py --mode prices-only --once

# 测试/预发配置：test_config.json
python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode prices-only --once

# 也可用环境变量选择测试配置
ROBINHOOD_ENV=test python3 outputs/rwa-market-maker/market_rebalancer.py --mode prices-only --once
```

传 `--config <path>` 时会覆盖 `--environment` 对应的默认配置。`production` 使用 `production_config.json`，`test` 使用 `test_config.json`。两份配置由同一个 Python/Foundry 交易脚本处理；`test` 是配置选择名，不代表测试网。测试配置给出的网络是 X Layer Mainnet，chain ID 为 196。

测试配置将 BTGO MarketBeat 价格用作 RWT-USDC 池的基准价。该配置里的 Registry 映射得到 RWT underlying `0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0`；`securityId` 与链上 Registry 读取值相同。

测试池已按 BTGO 的 `$5.21 × 80% = $4.168` 初始价创建：PoolId `0xdfc2f5fd2363bdf32d72ab5d6c949801124eed1d4f8374c02b329281a41ad7ef`，PoolKey 为 USDC/RWT wrapper、fee 2000、tick spacing 10、原 hook，`sqrtPriceX96=38807505579413740389281041832379873`。建池和加 LP 交易均成功。LP 仓位 token ID 为 193，tick 范围为 261440–262640；receipt 显示注入 4.047288 USDC 和 0.999999999999995278 RWT。PoolManager active-liquidity slot 读回 `68081424593535`，当前 tick 可用流动性非零。实际 USDC 用量低于最大值 4.168，因为 tick 对齐后的仓位区间决定两种资产的实际比例。该读数不枚举可能存在的区间外 LP position。

配置中的 `PermissionsAdapterFactory` 采用你提供的 `0x92cdb...`。链上 Registry 的 `permissionsAdapterFactory()` 也返回该值；现有 `script/xlayer/deployment.json` 记录的 Factory 是另一个地址。`TradeTSV` 交易脚本本身不读取 Factory，但需要其他部署或 Registry 操作时应单独处理这项差异。

## 运行模式

### 持续观察池价（只读）

`pool_price_monitor.py` 持续读取池内折算 USD 价格和对应行情参考价，不会提交交易。默认监控所选配置中配置了池子的 RWT、MSTR、BTGO；每轮每个资产输出一行 JSON，包含池价、市场参考价、相对价差、tick、活跃流动性、Registry tradable 状态和报价时间。行情源暂时失败时仍会输出链上池价及错误字段。

```sh
# production：监控 MSTR、BTGO
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment production

# test：监控 RWT-USDC 池，以 BTGO 行情作参考
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment test

# 单轮输出，或指定当前配置里的资产
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment test --once
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment production --assets MSTR BTGO
```

轮询周期默认读取配置的 `interval_seconds`，并自动确保不短于所选行情 endpoint 的 `min_poll_seconds`；行情请求总数不超过每分钟 30 次。按 Ctrl+C 停止。`test` 配置指向 X Layer 主网，脚本只读，但仍需可用的主网 RPC 和 Python Web3 依赖。

```sh
# 只读价格，不连接 X Layer RPC
python3 outputs/rwa-market-maker/market_rebalancer.py --mode prices-only --once

# 以测试配置持续监控；达到阈值后会执行 Foundry 模拟并尝试广播
PYTHONPATH=sdk/python python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode rebalance --max-trade-notional-usd 10
```

再平衡时必须传入正数 `--max-trade-notional-usd`（旧参数 `--trade-notional-usd` 仍可用）；该值是最大输入额度。脚本根据目标价格、当前 `sqrtPriceX96`、当前活跃流动性和经过的初始化 tick 直接计算 exact-input 数量，并受最大额度限制；若目标超出池内可用流动性区间则停止并报告。随后用 Router 支持的 `swapExactInput` 做一次 sizing 模拟，按滑点容差设置最低输出，再模拟最终交易。模拟成功后才广播。普通 exact-input 交易不提供链上价格停止保证；成交后程序等待回执并重新读取池价。

程序只在当前 tick 的 active liquidity 大于零时继续到交易判断；零 active liquidity 时会输出 `skipped_no_active_liquidity`。该字段表示当前价格附近可用于 swap 的流动性，不用于枚举池里所有可能位于区间外的 LP position。

`pool_price_monitor.py` 也会输出 `active_liquidity`、`has_active_liquidity` 和 `liquidity_status`（`active` / `zero_active`），用于直接判断当前价格 tick 是否有活跃流动性。该状态不代表全池 TVL 或特定交易规模的可成交深度。

## 行情源

| 股票/池 | 来源 | 价格口径 | 自动交易最大报价年龄 |
|---|---|---|---:|
| MSTR | Robinhood Stock Token API | bid/ask 中间价，按 `generatedAt` | 90 秒 |
| BTGO | MarketBeat | 报价横幅 Fair Market Value，按 `As of` 东部时间 | 120 秒 |
| SECZ | MarketBeat | 报价横幅 Fair Market Value，按 `As of` 东部时间 | 120 秒 |

按每个 URL 的最小轮询间隔限频，同时所有来源合计不超过每分钟 30 次。MarketBeat 的 `As of` 有时只提供时分；这种情况下程序按读取时的东部日期补齐。页面改版或来源没有符合格式的报价时间时程序报错，不回退到未经时间标记的价格。

## 重要边界

- 测试配置使用 X Layer **主网**合约；在 `rebalance` 模式下会广播真实主网交易，不是隔离测试网。
- 当前测试池 `RWT-USDC` 已初始化且 Registry 标记为 tradable；新 LP 仓位覆盖当前 tick，PoolManager active liquidity 已读回非零值。
- 广播成功后程序等待 Router 交易回执，再读取池状态；跨 tick 时以链上回读为准，下一轮按新状态重新评估。
- 报价与池价相差达到配置阈值后，程序用真实 swap 改变池价，不会直接写 `sqrtPriceX96`。
- 逐函数实现说明见 [`rebalancer_implementation.md`](rebalancer_implementation.md)。


cd ~/meili/yunshan.fang_dacs_at_okg.com/117/Desktop/gitlab/tsv
/opt/homebrew/opt/python@3.13/bin/python3.13 -m venv .venv-rwa
source .venv-rwa/bin/activate
python -m pip install -r outputs/rwa-market-maker/requirements.txt

XLAYER_RPC_URL=https://xlayerrpc.okx.com PYTHONPATH=sdk/python python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode rebalance --max-trade-notional-usd 10 

XLAYER_RPC_URL=https://xlayerrpc.okx.com PYTHONPATH=sdk/python python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode rebalance --max-trade-notional-usd 10



默认按配置选择资产：test 监控 RWT-USDC 池，并以 BTGO 行情作参考；production 监控 MSTR 和 BTGO 池。脚本持续打印池内 USD 价格、市场参考价、相对价差、tick、活跃流动性、Registry tradable 状态和报价时间。它只读链上和行情，不会发送
交易；轮询遵守配置的 endpoint 间隔和每分钟最多 30 次请求限制。

python3 outputs/rwa-market-maker/pool_price_monitor.py --environment test
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment production

cast chain-id --rpc-url https://xlayerrpc.okx.com

