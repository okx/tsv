"""Render the verified public deployment evidence for handoff."""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent
v = json.loads((OUT / 'verified.json').read_text())
pool = {
    'name': 'VOLOROSTOCK2—USDT',
    'chainId': v['chainId'],
    'poolid': v['poolId'],
    **{k: v[k] for k in ['currency0', 'currency1', 'fee', 'tickSpacing', 'hooks', 'sqrtPriceX96', 'tick']},
    'txhash': v['initializeTx'],
    'lifecycle': v['lifecycle'],
    'tierId': v['tierId'],
    'liquidity': v['liquidity'],
}
(OUT / 'pool.json').write_text(json.dumps(pool, indent=2, ensure_ascii=False) + '\n')
rows = []
for stage, title in [('legal', '部署 Legal-share Adapter'), ('tier', 'Tier 2 容量 2 → 3'), ('register', '登记 VOLOROST2'), ('initialize', '注册并初始化池')]:
    receipts = json.loads((OUT / (stage + '.receipts.json')).read_text())
    assert len(receipts) == 1 and receipts[0]['status'] == '0x1'
    r = receipts[0]
    h = r['transactionHash']
    rows.append(f'| {title} | [{h}](https://www.oklink.com/xlayer/tx/{h}) | {int(r["blockNumber"], 16)} | {int(r["gasUsed"], 16)} | 成功 |')
report = f'''# VOLOROSTOCK2—USDT 部署结果

网络：X Layer Mainnet（196）。核验区块：{v['verificationBlock']}。
已完成 Legal-share Adapter 部署、Tier 2 扩容、证券登记、池注册及初始化，4 笔交易回执均成功。

## PoolKey 和池状态

```json
{json.dumps(pool, indent=2, ensure_ascii=False)}
```

- currency0 是指定报价币地址，链上 symbol 为 USD₮0（USDT0），decimals=6。
- currency1 是 VOLOROST2 的 PermissionsAdapter，decimals=6；底层代币 VOLOROST2 的 decimals=6。
- 地址按链上要求升序排列。价格严格采用用户明确确认的 sqrtPriceX96，tick=-276325；fee=2000（0.2%）。
- Registry 状态 LIST，isTradable=true，isLPAllowed=true。Tier 2 最终为 3/3。
- 本次仅建池，未添加流动性；链上 active liquidity=0，Registry tickCount={v['tickCount']}，尚不能据此认定可成交。

## 合约与证券

| 项目 | 地址或数值 |
| --- | --- |
| Underlying U | `{v['underlying']}` |
| PermissionsAdapter W | `{v['adapter']}` |
| Checker | `{v['checker']}` |
| Factory | `{v['factory']}` |
| Legal-share Adapter | `{v['legalShareAdapter']}` |
| Security ID | `{v['securityId']}` |
| Tier ID | `2` |
| 当前 uiMultiplier | `1000000000000000000` |
| Registry | `0x2233ea2044ffa04ccceeef0b9adfe0799505a908` |
| LP Manager | `0xf73d8683b948564d2795c62a2a909012ea168d29` |
| Router | `0xe5df3ab010bb20094f490dfcf61b6e2d9a3311c8` |
| Pool Manager | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |
| 签名钱包 | `{v['signer']}` |

## 交易

| 操作 | 交易哈希 | 区块 | Gas used | 回执 |
| --- | --- | --- | --- | --- |
{chr(10).join(rows)}

## 验证依据

每步写入前均通过 Foundry 主网模拟；广播后通过 RPC 独立读取交易回执及相关状态。
最终核对 PoolManager Initialize 事件、完整 PoolKey、初始 sqrtPriceX96/tick、Registry 的证券绑定、Tier 和生命周期，以及零流动性状态。
原始证据见同目录 `verified.json`、`*.receipts.json`、`*.transactions.json` 和模拟日志。

Lark 交易日志写入曾返回 `forBidden`，未自动重试；完整记录已保存在本目录。
'''
(OUT / 'DEPLOYMENT.md').write_text(report)
print(json.dumps(pool, indent=2, ensure_ascii=False))
print('\n'.join(rows))
