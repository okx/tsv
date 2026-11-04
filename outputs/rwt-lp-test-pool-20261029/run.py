"""Create one fresh RWT/USDC pool at a human token ratio of 1:1."""
import importlib.util
import json
import sys
import time
from pathlib import Path

OUT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('ops',OUT.parent/'volorost2-usdt-20261022/run.py')
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o);o.OUT=OUT
Q='0xb6ceceab302e2e4948951ee7843fc24e92933061'
W='0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c'
OLD='0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3'
SID='0xe29c89c6170c14d1aec33ef8c32df8beb88a6ff3e6e3c30a8bcb27e4321773e3'
PRICE=(1<<96)*10**6
SPACING=20
POOL=o.cast('keccak',o.cast('abi-encode','f(address,address,uint24,int24,address)',Q,W,2000,SPACING,o.HOOK))
def saved(name):return json.loads((OUT/name).read_text())
def preflight():
    assert int(o.rpc('eth_chainId',[]),16)==196 and o.REG.lower()=='0x2233ea2044ffa04ccceeef0b9adfe0799505a908'
    actor=o.owner();block=o.rpc('eth_blockNumber',[])
    qs=[('old',o.REG,'getPool(bytes32)',[OLD]),('known',o.REG,'isKnownPool(bytes32)',[POOL]),
        ('qDecimals',Q,'decimals()',[]),('wDecimals',W,'decimals()',[]),('underlying',o.REG,'getCurrencyUnderlying(address)',[W]),
        ('paused',o.REG,'isPaused()',[]),('pauseMode',o.REG,'getSecurityPauseMode(bytes32)',[SID]),
        ('creator',o.REG,'hasRole(bytes32,address)',[o.cast('keccak','POOL_CREATOR_ROLE'),actor]),
        ('lpRegistry',o.LP,'registry()',[]),('quote',o.REG,'getQuoteToken(address)',[Q]),('hook',o.REG,'hook()',[])]
    raw=o.batch(qs,block)
    assert o.words(raw['old'])[:6]==[int(Q,16),int(W,16),2000,40,int(o.HOOK,16),int(SID,16)]
    assert int(raw['known'],16)==0 and o.state(POOL,block)['sqrtPriceX96']=='0','Pool already exists'
    assert int(raw['qDecimals'],16)==6 and int(raw['wDecimals'],16)==18
    assert int(raw['creator'],16)==1 and int(raw['paused'],16)==0
    assert o.address(raw['lpRegistry']).lower()==o.REG.lower() and o.address(raw['hook']).lower()==o.HOOK.lower()
    underlying=o.address(raw['underlying']);ur=o.words(o.call(o.REG,'getUnderlying(address)',underlying,block=block))
    assert ur[0]==int(SID,16) and ur[2:]==[18,1] and o.words(raw['quote'])==[6,1]
    nonce=int(o.rpc('eth_getTransactionCount',[actor,'pending']),16)
    assert nonce==int(o.rpc('eth_getTransactionCount',[actor,'latest']),16)
    balance=int(o.rpc('eth_getBalance',[actor,block]),16);assert balance>10**14
    data={'poolid':POOL,'securityId':SID,'currency0':Q,'currency1':W,'underlying':underlying,'fee':2000,'tickSpacing':SPACING,
          'hooks':o.HOOK,'sqrtPriceX96':str(PRICE),'tick':276324,'pauseMode':int(raw['pauseMode'],16),
          'operator':actor,'startNonce':nonce,'block':int(block,16),'nativeBalance':str(balance)}
    o.save('preflight.json',data);print(json.dumps(data,indent=2),flush=True)
def verify():
    pre=saved('preflight.json')
    artifact=json.loads((o.ROOT/'broadcast/InitializeTSVPools.s.sol/196/run-latest.json').read_text())
    assert len(artifact['transactions'])==1
    h=artifact['transactions'][0]['hash'];tx=o.rpc('eth_getTransactionByHash',[h])
    assert tx and tx['from'].lower()==pre['operator'].lower() and tx['to'].lower()==o.LP.lower()
    assert int(tx['nonce'],16)==pre['startNonce'] and int(tx['value'],16)==0
    expected=o.cast('calldata','initializePool((address,address,uint24,int24,address),uint160)',f'({Q},{W},2000,{SPACING},{o.HOOK})',PRICE)
    assert tx['input'].lower()==expected.lower(),'Broadcast does not match intended pool'
    receipt=None
    for attempt in range(6):
        receipt=o.rpc('eth_getTransactionReceipt',[h])
        if receipt:break
        time.sleep(2)
    assert receipt and receipt['status']=='0x1','No successful receipt; do not resend'
    topic=o.cast('keccak','Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)')
    ev=[l for l in receipt['logs'] if l['address'].lower()==o.PM.lower() and l['topics'][0]==topic]
    assert len(ev)==1 and ev[0]['topics'][1].lower()==POOL
    assert o.words(ev[0]['data'])==[2000,SPACING,int(o.HOOK,16),PRICE,276324]
    block=o.rpc('eth_blockNumber',[]);pool=o.words(o.call(o.REG,'getPool(bytes32)',POOL,block=block))
    assert pool[:6]==[int(Q,16),int(W,16),2000,SPACING,int(o.HOOK,16),int(SID,16)]
    assert pool[7]==1 and pool[8]==0
    state=o.state(POOL,block);assert state['sqrtPriceX96']==str(PRICE) and state['tick']==276324
    active=int(o.call(o.PM,'extsload(bytes32)','0x'+(int(o.slot(POOL),16)+3).to_bytes(32,'big').hex(),block=block),16)&((1<<128)-1)
    assert active==0
    result={'poolid':POOL,'currency0':Q,'currency1':W,'fee':2000,'tickSpacing':SPACING,'hooks':o.HOOK,
      'sqrtPriceX96':state['sqrtPriceX96'],'tick':state['tick'],'securityId':SID,'txhash':h,
      'lifecycle':'LIST','activeLiquidity':str(active),'pauseMode':int(o.call(o.REG,'getSecurityPauseMode(bytes32)',SID,block=block),16),
      'verificationBlock':int(block,16)}
    o.save('pool.json',result);o.save('verified-receipt.json',receipt);o.save('canonical-transaction.json',tx)
    o.save('initialize.journal.json',{'status':'verified','hashes':[h]})
    (OUT/'TRANSACTIONS.md').write_text('# RWT-USDC LP 测试新池\n\n网络：X Layer Mainnet（196）。\n\n沿用参考池资产、fee=2000 和 Hook，采用未注册的 tickSpacing=20 创建独立池。USDC 为 6 位，RWT adapter 为 18 位，1:1 初始价格对应 sqrtPriceX96=2^96×10^6。\n\n```json\n'+json.dumps(result,indent=2)+'\n```\n\n[创建交易](https://www.oklink.com/xlayer/tx/'+h+')\n\n已验证成功回执、Initialize 事件、Registry PoolRecord 和 PoolManager 价格。仅创建并初始化，未添加流动性。\n\nLark 日志此前返回 forBidden，未自动重试；原始证据保存在本目录。\n')
    print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':
    action=sys.argv[1]
    if action=='preflight':preflight()
    elif action=='execute':
        pre=saved('preflight.json');assert o.owner().lower()==pre['operator'].lower()
        assert int(o.rpc('eth_getTransactionCount',[pre['operator'],'pending']),16)==pre['startNonce']
        o.execute('initialize',o.Target.INITIALIZE_POOLS,{'TSV_POOL_COUNT':'1','TSV_POOL_CURRENCY0_0':Q,'TSV_POOL_CURRENCY1_0':W,
          'TSV_POOL_FEE_0':'2000','TSV_POOL_TICK_SPACING_0':str(SPACING),'TSV_POOL_HOOK_0':o.HOOK,'TSV_POOL_SQRT_PRICE_X96_0':str(PRICE)})
        verify()
    elif action=='verify':verify()
    else:raise SystemExit('Unknown action')
