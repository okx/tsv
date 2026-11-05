# RWA Market Maker (X Layer / TSV v4)

`market_rebalancer.py` 获取股票参考价，并支持只读价格检查或显式再平衡。`pool_price_monitor.py` 读取 X Layer 池状态和市场参考价，只读，不会发送交易。

## 配置与资产

配置文件使用同一套 `assets` 结构：`production_config.json` 是生产配置，`test_config.json` 是 RWT-USDC 配置。`test` 只是配置名，该配置同样连接 X Layer 主网（chain ID 196）。`--config <path>` 可指定配置文件；`market_rebalancer.py` 的环境变量默认值为 `ROBINHOOD_ENV`，监控器为 `RWA_MARKET_ENV`。两者均可用 `--environment` 显式指定。`XLAYER_RPC_URL` 可覆盖配置中的 RPC。

生产配置现含六个资产。下面的初始价格和 tick 是部署时用户提供的读数；程序运行时从 PoolManager 读取实时状态。

| Ticker | PoolId | Currency1 | 初始 `sqrtPriceX96` | 初始 tick |
|---|---|---|---:|---:|
| MSTR | `0xa999aed1e46e931f2728df9136833010bc3e8d86168cb7d027e1ad9a21f2831e` | `0xe1218f57c5fe7d11088ac4682781906f3c4b0bff` | `7266192850782408354742523130` | -47785 |
| BTGO | `0x35dcb6792cc0dac132d37441cb7eb22f396442493b9e17193300aea8882c10dc` | `0xd5cf2ce52694249cff1741c0ce7ebc3f7c0c4c3b` | `36310354836963468287886058198` | -15606 |
| SECZ | `0x899d43e231666175df6204eebdbcde1945c8cdf39e56d492538b63434d8082fd` | `0xc71874b5ee1fb75ee21228981e818375920b7516` | `28354604063808208081946837949` | -20552 |
| HOOD | `0x031c8d93b10efd5417656f34d5952b07aa655abc9e41311d8f5ea592050a0d19` | `0xc0d57d1e0a12c74d7416b1895f5eaa087f43c5b3` | `8932597574989696252006689598` | -43655 |
| COIN | `0x23a8e8337aa384f82a5f3b400861a4e999209b9cc1f41209295ed2ddce439299` | `0xbd26a1683e8d7159aac52f875247e1d80dc3b5af` | `6785033755342840821061579226` | -49155 |
| CRCL | `0xffab809e144e5948be68cd55d6252bbbdd8f351e57e1f457c0bc600588d65b24` | `0xd4f64a67b2c1295bd6c25b3a306b2a049e392397` | `9572137737134969611696588638` | -42272 |

All six pools use USDC `0xb6ceceab302e2e4948951ee7843fc24e92933061` as `currency0`, fee `2000`, tick spacing `10`, and hook `0xf151416e74d6b4ae00197e8d8e4f4765283b3fff`. PoolId, PoolKey, ticker, ISIN, price source, and Registry underlying mapping are configured per asset in `production_config.json`.

## 安装

从仓库根目录创建 Python 3.13 虚拟环境并安装依赖：

```sh
cd ~/meili/yunshan.fang_dacs_at_okg.com/117/Desktop/gitlab/tsv
/opt/homebrew/opt/python@3.13/bin/python3.13 -m venv .venv-rwa
source .venv-rwa/bin/activate
python -m pip install -r outputs/rwa-market-maker/requirements.txt
```

## 获取市场参考价

检查生产配置中全部六个资产的行情，一轮后退出：

```sh
python3 outputs/rwa-market-maker/market_rebalancer.py --environment production --mode prices-only --once --assets MSTR BTGO SECZ HOOD COIN CRCL
```

`prices-only` 只请求行情，不连接 X Layer RPC，也不读取池状态或发送交易。每个资产输出一行 JSON，包含行情来源、价格口径、报价时间、新鲜度和 `trade_eligible`。MarketBeat 在休市或报价过旧时仍会返回价格，但 `trade_eligible` 为 `false`，不能触发再平衡。省略 `--assets` 时使用所选配置中的全部资产。

```sh
# 只读查看 test 配置的 BTGO 参考行情
python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode prices-only --once
```

## 只读监控池状态

监控器需要 Web3 依赖和可用的 X Layer RPC。默认监控所选配置的全部资产；可用 `--assets` 限定 ticker。每个资产输出池价、市场价、价差、tick、`sqrt_price_x96`、当前 tick 的 active liquidity 和 Registry tradable 状态。链上池状态与行情分开读取，其中一项失败时会输出相应错误字段。

```sh
# 生产配置六个池，单轮后退出
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment production --once

# 持续监控 test 配置的 RWT-USDC 池（参考 BTGO 行情）
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment test

# 只监控指定资产
python3 outputs/rwa-market-maker/pool_price_monitor.py --environment production --assets MSTR HOOD COIN CRCL --once
```

轮询间隔至少为配置的 `interval_seconds` 和所选行情源 `min_poll_seconds` 中的最大值；全部市场请求总量限制为每分钟最多 30 次。`active_liquidity=0` 表示当前 tick 没有可用于 swap 的活跃流动性，不代表全池没有区间外 LP 仓位。

## 行情源与新鲜度

| Ticker | 行情源 | 价格口径 | 自动交易最大报价年龄 |
|---|---|---|---:|
| MSTR、COIN、CRCL | Robinhood Stock Token API | bid/ask 中间价，按 `generatedAt` | 90 秒 |
| BTGO、SECZ、HOOD | MarketBeat 股票页 | Fair Market Value 报价横幅，按 `As of` 东部时间 | BTGO 2,800 秒；SECZ 1,200 秒；HOOD 2,800 秒 |

Robinhood 返回的报价必须匹配 ticker、USD、非暂停状态和有效 bid/ask。MarketBeat 页面必须包含可解析的带时间报价横幅；页面格式变化或缺少报价时间时会报错，不使用未标时间的价格。MarketBeat 的时分时间戳可能按读取时的东部日期补齐。

## 再平衡

再平衡会对符合条件的池执行模拟，并在模拟通过后广播真实主网交易。生产配置和 test 配置均使用 X Layer Mainnet；运行前先核对 `--environment`、配置、RPC 和 `--assets`。下面的 `10` 是每笔 swap 最大输入额度（USD），不是固定成交金额：

```sh
PYTHONPATH=sdk/python python3 outputs/rwa-market-maker/market_rebalancer.py --environment test --mode rebalance --max-trade-notional-usd 10
PYTHONPATH=sdk/python python3 outputs/rwa-market-maker/market_rebalancer.py --environment production --mode rebalance --max-trade-notional-usd 10
```

程序仅在报价新鲜、当前 tick 有活跃流动性，且偏离达到 `rebalance_deviation_percent`（当前为 8%）时考虑交易。目标价按 `rebalance_target_deviation_percent`（当前为 1%）计算。脚本根据当前价格、活跃流动性和跨越的初始化 tick 估算 exact-input 数量，并限制在最大输入额度内。之后运行 sizing 模拟，根据模拟输出和 `--slippage-bps`（默认 100 bps，即 1%）计算最低输出，再运行最终模拟；通过后才广播。当前 swap 未启用链上 `sqrtPriceLimitX96`，目标价仅用于输入量估算，成交可能越过目标价。确认回执后脚本重新读取池价。

常见跳过结果包括 `skipped_stale_price` 和 `skipped_no_active_liquidity`。前者表示报价年龄超过资产配置，后者表示当前 tick 没有活跃流动性。普通 exact-input 交易不提供目标价的链上停止保证。

## 当前核对记录

2026-11-05 的只读检查确认六个配置池的 PoolId、PoolKey 和 Registry tradable 状态可读，六个池均为 `registry_tradable=true`。当次快照中 MSTR、BTGO 有非零 active liquidity；SECZ、HOOD、COIN、CRCL 的 active liquidity 为零。该状态会随链上交易和 LP 变化，应以监控器实时输出为准。同期价格检查成功取得六个资产报价；BTGO、SECZ、HOOD 的 MarketBeat 报价时间已过期，`trade_eligible=false`。这些只读结果不表示六个池当前都可实际成交。

```sh
cast chain-id --rpc-url https://xlayerrpc.okx.com
```

预期 chain ID 为 `196`；两个脚本也会在需要连接 RPC 时自行校验 chain ID。

测试配置的 RWT-USDC 初始化和 LP 历史记录、逐函数实现细节见 [`rebalancer_implementation.md`](rebalancer_implementation.md)。
