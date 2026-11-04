# RWT-USDC LP 测试新池

网络：X Layer Mainnet（196）。

沿用参考池资产、fee=2000 和 Hook，采用未注册的 tickSpacing=20 创建独立池。USDC 为 6 位，RWT adapter 为 18 位，1:1 初始价格对应 sqrtPriceX96=2^96×10^6。

```json
{
  "poolid": "0x3c4819dd89f20dbb51dfd23becb6c89d97399b5cd996f09cc4f08e863137dcaf",
  "currency0": "0xb6ceceab302e2e4948951ee7843fc24e92933061",
  "currency1": "0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c",
  "fee": 2000,
  "tickSpacing": 20,
  "hooks": "0xbc6d8c8a8b681872a93554116f01268f80c9ffff",
  "sqrtPriceX96": "79228162514264337593543950336000000",
  "tick": 276324,
  "securityId": "0xe29c89c6170c14d1aec33ef8c32df8beb88a6ff3e6e3c30a8bcb27e4321773e3",
  "txhash": "0x39785e9d6dc0be95da0fec947b2fed1bcfc5b9ba2449b8bf28fa4bdfe337cc90",
  "lifecycle": "LIST",
  "activeLiquidity": "0",
  "pauseMode": 0,
  "verificationBlock": 74494037
}
```

[创建交易](https://www.oklink.com/xlayer/tx/0x39785e9d6dc0be95da0fec947b2fed1bcfc5b9ba2449b8bf28fa4bdfe337cc90)

已验证成功回执、Initialize 事件、Registry PoolRecord 和 PoolManager 价格。仅创建并初始化，未添加流动性。

Lark 日志此前返回 forBidden，未自动重试；原始证据保存在本目录。
