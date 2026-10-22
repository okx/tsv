from pathlib import Path
import json
P=Path(__file__).resolve().parent
s=json.loads((P/'execution.json').read_text())
meta=json.loads((P/'decoded-tokens.json').read_text())
symbols={r['underlying'].lower():r['symbol'] for r in meta}
rows=s['tokens'];done=sum(bool(r.get('verification')) for r in rows)
lines=['# RWAT / USD₮0 新建池清单','',f'已完成最终链上核验：{done}/{len(rows)} 个池。网络：X Layer Mainnet（chainId 196）。','', '## 参数与范围','',f"- 操作钱包 / Adapter owner：`{s['owner']}`。",f"- Factory：`{s['factory']}`。",f"- Registry：`{s['registry']}`。",f"- PoolManager：`{s['poolManager']}`。",f"- LP Manager：`{s['lpManager']}`。",f"- Hook：`{s['hook']}`。",f"- 所有 Adapter 使用同一 allowListChecker：`{s['checker']}`。",f"- QuoteToken：USD₮0，`{s['quote']}`，精度 6。",'- fee = 2000（0.2%）；tickSpacing = 60；初始价格：1 枚 RWAT = 1 枚 USD₮0。','- 每个 Token 分配独立 securityId，每个 Token 使用独立 ERC8056DirectLegalShareAdapter。','- 每种 Token 只补 mint 至操作钱包足够转入 0.1 枚；每个 Adapter 转入 100000000000000000 raw units（0.1 枚），转入与 Factory 验证为独立交易。','- tier 3 容量 40；本次登记 22 个独立证券。','- 本次不部署、不修改 Token 的 Trust、Compliance、Rebasing 等底层服务；这些服务由其他流程完成。','- 本次没有执行 LP 添加或 swap，也没有配置 Adapter 的 TSV wrapper / hook / swapping 权限。','- Pool 是 PoolManager 中由 Pool ID 标识的状态，不是独立部署的池合约地址。','', '## 全部池子','', '| 序号 | Symbol | Underlying Proxy | PermissionsAdapter（W） | Pool ID | 状态 |','| --- | --- | --- | --- | --- | --- |']
for r in rows:
 lines.append(f"| {r['index']} | {symbols[r['underlying'].lower()]} | `{r['underlying']}` | `{r.get('adapter','尚未创建')}` | `{r.get('poolId','尚未创建')}` | {'已初始化且零流动性' if r.get('verification') else '进行中'} |")
lines+=['','## PoolKey、证券与交易明细','']
receipt_index={}
for label in ['mint','create','tier','verify','register','pools']:
 f=P/(label+'.receipts.json')
 if f.exists():
  for rc in json.loads(f.read_text()):receipt_index[rc['transactionHash'].lower()]=rc
for r in rows:
 lines += [f"### {r['index']}. {symbols[r['underlying'].lower()]} — {r['underlying']}",'',f"- securityId：`{r['securityId']}`。",f"- LegalShareAdapter：`{r.get('legalShareAdapter','尚未创建')}`。"]
 if r.get('poolId'):
  lines += [f"- Pool ID：`{r['poolId']}`。",f"- currency0：`{r['currency0']}`。",f"- currency1：`{r['currency1']}`。",f"- fee：2000；tickSpacing：60；hooks：`{s['hook']}`。",f"- 初始 sqrtPriceX96：`{r['sqrtPriceX96']}`（整数，按币种排序和小数位换算）。"]
 if r.get('verification'):
  lines += ['- 最终状态：Factory 已验证、Registry 已登记、Pool lifecycle=LIST、Pool liquidity=0、Pool tickCount=0。','- 先前验资阶段已确认 Adapter 收到 0.1 枚底层 Token；本次续建未修改 Adapter 权限。']
 lines += ['','| 操作 | 交易哈希 | 区块 | 回执 |','| --- | --- | --- | --- |']
 for label,key in [('Mint 余额缺口','mintTx'),('部署 LegalShareAdapter','createLegalTx'),('Factory 部署 PermissionsAdapter','createAdapterTx'),('转入 0.1 枚底层 Token','depositTx'),('Factory 验证 Adapter','verifyTx'),('Registry 注册 Underlying / security','registerTx'),('创建并初始化 Pool','initializeTx')]:
  h=r.get(key)
  if h:
   rc=receipt_index.get(h.lower());block=str(int(rc['blockNumber'],16)) if rc else '待核验';status='成功（status=1）' if rc and int(rc['status'],16)==1 else '待核验'
   lines.append(f'| {label} | `{h}` | {block} | {status} |')
 lines+=['']
lines += ['## 共用交易与最终核验','']
if s.get('tierTx'):lines.append(f"- 设置 tier 3 容量为 40：`{s['tierTx']}`。")
if 'final' in s['completedStages']:
 lines += [f"- 已核验成功交易 {s['transactionCount']} 笔；实际 Gas 费用合计 `{s['gasCostOKB']}` OKB（按各回执 gasUsed × effectiveGasPrice 求和）。",f"- 最终池状态核验使用固定区块 {int(s['verificationEndBlock'],16)}；先前阶段复用已保存的成功回执。",'- tier 3 最终容量/占用：40 / 22。','- 22 个池的 sqrtPriceX96 均与初始化参数一致，liquidity 和 Registry tickCount 均为零。']
lines += ['','## 证据文件','', '- `execution.json`：完整地址、PoolKey、securityId、交易哈希和最终状态。','- `mint/create/tier/verify/register/pools.receipts.json`：各阶段从 RPC 获取的交易回执。','- 对应的 `.broadcast.json`：Foundry 广播记录；`.simulation.log`：模拟结果。','- 每次发送前通过 SDK 模拟；每个阶段发送后检查 status=1 和状态回读。','- `diagnostic.json` 为执行前服务与 mint 只读模拟结果；历史 `PREFLIGHT.md` 中未就绪状态已由本报告的执行结果取代。']
(P/'RWAT_POOLS.md').write_text('\n'.join(lines)+'\n')
print('Report updated:',done,'/',len(rows),'verified pools')
