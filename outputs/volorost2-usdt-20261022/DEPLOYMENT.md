# VOLOROSTOCK2—USDT 部署结果

网络：X Layer Mainnet（196）。核验区块：73890106。
已完成 Legal-share Adapter 部署、Tier 2 扩容、证券登记、池注册及初始化，4 笔交易回执均成功。

## PoolKey 和池状态

```json
{
  "name": "VOLOROSTOCK2—USDT",
  "chainId": 196,
  "poolid": "0xbdf2fc001650f849065e99e1acbe47d07f62d4e5f5cc48335871282c2449f273",
  "currency0": "0x779ded0c9e1022225f8e0630b35a9b54be713736",
  "currency1": "0x9f212c1DCc9e8026d30Ff38b01B72687EAab747b",
  "fee": 2000,
  "tickSpacing": 60,
  "hooks": "0xbc6d8c8a8b681872a93554116f01268f80c9ffff",
  "sqrtPriceX96": "79228162514264337593543",
  "tick": -276325,
  "txhash": "0xeb76f9bddd6c986834bd1c48965bedc7264c60be1032dde04a7c091d70de9458",
  "lifecycle": "LIST",
  "tierId": 2,
  "liquidity": "0"
}
```

- currency0 是指定报价币地址，链上 symbol 为 USD₮0（USDT0），decimals=6。
- currency1 是 VOLOROST2 的 PermissionsAdapter，decimals=6；底层代币 VOLOROST2 的 decimals=6。
- 地址按链上要求升序排列。价格严格采用用户明确确认的 sqrtPriceX96，tick=-276325；fee=2000（0.2%）。
- Registry 状态 LIST，isTradable=true，isLPAllowed=true。Tier 2 最终为 3/3。
- 本次仅建池，未添加流动性；链上 active liquidity=0，Registry tickCount=0，尚不能据此认定可成交。

## 合约与证券

| 项目 | 地址或数值 |
| --- | --- |
| Underlying U | `0xC03484ab791B5BD2C3DA860BEa2Ba96C76248BFD` |
| PermissionsAdapter W | `0x9f212c1DCc9e8026d30Ff38b01B72687EAab747b` |
| Checker | `0xbB1716d2a3fc6215C306a8942A2842F486e1C4B1` |
| Factory | `0x92cdb229613dA8ca45E375cf69dF4b3b645FF48D` |
| Legal-share Adapter | `0x48a9b7cbda233d67f9743b7e4f6daadd789bbc19` |
| Security ID | `0xb5305ea27b8a8d8f365bb30fd5500981f3fc8848bc3c897b801051edeee73c7f` |
| Tier ID | `2` |
| 当前 uiMultiplier | `1000000000000000000` |
| Registry | `0x2233ea2044ffa04ccceeef0b9adfe0799505a908` |
| LP Manager | `0xf73d8683b948564d2795c62a2a909012ea168d29` |
| Router | `0xe5df3ab010bb20094f490dfcf61b6e2d9a3311c8` |
| Pool Manager | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |
| 签名钱包 | `0x224467f6640AbE0A62D1be98187912627b59722A` |

## 交易

| 操作 | 交易哈希 | 区块 | Gas used | 回执 |
| --- | --- | --- | --- | --- |
| 部署 Legal-share Adapter | [0x02619115ab04993a58db374cd0a77912a31349331574fa32d3a29c0c6013caf4](https://www.oklink.com/xlayer/tx/0x02619115ab04993a58db374cd0a77912a31349331574fa32d3a29c0c6013caf4) | 73889701 | 282813 | 成功 |
| Tier 2 容量 2 → 3 | [0x016e12baccbae80dd06f321253b6f7ac1bb423b83ce96cca3902206b77a86efa](https://www.oklink.com/xlayer/tx/0x016e12baccbae80dd06f321253b6f7ac1bb423b83ce96cca3902206b77a86efa) | 73889895 | 37346 | 成功 |
| 登记 VOLOROST2 | [0xe86b369c79355e72398bd35e6a52c79f914f52c022107aeab76a57f62ec5c45c](https://www.oklink.com/xlayer/tx/0xe86b369c79355e72398bd35e6a52c79f914f52c022107aeab76a57f62ec5c45c) | 73889955 | 278457 | 成功 |
| 注册并初始化池 | [0xeb76f9bddd6c986834bd1c48965bedc7264c60be1032dde04a7c091d70de9458](https://www.oklink.com/xlayer/tx/0xeb76f9bddd6c986834bd1c48965bedc7264c60be1032dde04a7c091d70de9458) | 73890077 | 350598 | 成功 |

## 验证依据

每步写入前均通过 Foundry 主网模拟；广播后通过 RPC 独立读取交易回执及相关状态。
最终核对 PoolManager Initialize 事件、完整 PoolKey、初始 sqrtPriceX96/tick、Registry 的证券绑定、Tier 和生命周期，以及零流动性状态。
原始证据见同目录 `verified.json`、`*.receipts.json`、`*.transactions.json` 和模拟日志。

Lark 交易日志写入曾返回 `forBidden`，未自动重试；完整记录已保存在本目录。
