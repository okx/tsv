"""Resumable, receipt-verified multicall exercise. SDK owns credential loading."""
import importlib.util
import json
import sys
import time
import tomllib
from pathlib import Path

OUT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('previous',OUT.parent/'run.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
o=p.ops;o.OUT=OUT
SID='0xe29c89c6170c14d1aec33ef8c32df8beb88a6ff3e6e3c30a8bcb27e4321773e3'
LABELS=['quotas','mixed','add1','add2','unwind']
SIGS=['multicall(bytes[])','setQuota(bytes32,uint256,bytes32)','setUsedWad(bytes32,(uint256,uint256)[],bytes32)',
      'unwindPositionByTsv(uint256,uint128,uint128,bytes)','approve(address,uint256)','modifyLiquidities(bytes,uint256)']
def saved(name):return json.loads((OUT/name).read_text())
def decode(data):
    sig=next(s for s in SIGS if o.cast('sig',s).lower()==data[:10].lower())
    args=json.loads(o.cast('decode-calldata','--json',sig,data))
    result={'function':sig,'arguments':args}
    if sig=='multicall(bytes[])':result['calls']=[decode(x) for x in args[0]]
    return result
def preflight():
    assert int(o.rpc('eth_chainId',[]),16)==196 and o.owner().lower()==p.ACTOR.lower()
    block=o.rpc('eth_blockNumber',[])
    qs=[('pool',o.REG,'getPool(bytes32)',[p.POOL]),('qBalance',p.Q,'balanceOf(address)',[p.ACTOR]),
        ('uBalance',p.U,'balanceOf(address)',[p.ACTOR]),('day',p.LEDGER,'currentESTDay()',[]),
        ('quota',p.LEDGER,'Quota(bytes32)',[SID]),('pause',o.REG,'getSecurityPauseMode(bytes32)',[SID]),
        ('globalPause',o.REG,'isPaused()',[]),('lpAllowed',p.W,'isAllowed(address,bytes2)',[p.ACTOR,'0x0002']),
        ('sbt',o.REG,'isSbtAllowed(bytes2,address)',['0x0002',p.ACTOR]),('binding',o.REG,'getCurrencyUnderlying(address)',[p.W]),
        ('count',o.REG,'getPoolTickCount(bytes32)',[p.POOL])]
    for r in ['VOLUME_ORACLE_ROLE','FORCE_EXIT_ADMIN_ROLE']:qs.append((r,o.REG,'hasRole(bytes32,address)',[o.cast('keccak',r),p.ACTOR]))
    raw=o.batch(qs,block);day=int(raw['day'],16)
    assert o.words(raw['pool'])[:8]==[int(p.Q,16),int(p.W,16),2000,60,int(o.HOOK,16),int(SID,16),2,1]
    assert int(raw['qBalance'],16)>=200000 and int(raw['uBalance'],16)>=2*10**17
    assert int(raw['pause'],16)==int(raw['globalPause'],16)==int(raw['count'],16)==0
    assert all(int(raw[r],16)==1 for r in ['lpAllowed','sbt','VOLUME_ORACLE_ROLE','FORCE_EXIT_ADMIN_ROLE'])
    assert o.address(raw['binding']).lower()==p.U.lower()
    assert o.state(p.POOL,block)['sqrtPriceX96']==str(p.PRICE)
    for target in [p.LEDGER,o.LP]:
        o.rpc('eth_call',[{'from':p.ACTOR,'to':target,'data':o.cast('calldata','multicall(bytes[])','[]')},block])
    result={'block':int(block,16),'actor':p.ACTOR,'poolid':p.POOL,'securityId':SID,'quotaWad':str(int(raw['quota'],16)),
            'day':day,'usedWad':str(int(o.call(p.LEDGER,'usedWad(bytes32,uint256)',SID,day,block=block),16)),
            'qBalance':int(raw['qBalance'],16),'uBalance':int(raw['uBalance'],16),
            'nativeBalance':int(o.rpc('eth_getBalance',[p.ACTOR,block]),16),'raw':raw}
    assert result['nativeBalance']>10**14
    o.save('preflight.json',result);print(json.dumps({k:v for k,v in result.items() if k!='raw'},indent=2),flush=True)

def reconcile(label):
    journal=saved(label+'.journal.json')
    path=o.ROOT/'broadcast/RwtMulticallExercise.s.sol/196/run-latest.json'
    artifact=json.loads(path.read_text())
    hashes=[t['hash'] for t in artifact['transactions']]
    assert hashes and all(hashes)
    receipts=[];txs=[]
    for h in hashes:
        r=None
        for attempt in range(6):
            r=o.rpc('eth_getTransactionReceipt',[h])
            if r:break
            time.sleep(2)
        assert r and r['status']=='0x1','No successful receipt; do not resubmit'
        t=o.rpc('eth_getTransactionByHash',[h])
        assert t['from'].lower()==p.ACTOR.lower() and int(t['value'],16)==0
        txs.append({'hash':h,'to':t['to'],'nonce':int(t['nonce'],16),'input':t['input'],**decode(t['input'])})
        receipts.append(r)
    txs.sort(key=lambda t:t['nonce'])
    assert txs[0]['nonce']==journal['startNonce'],'Artifact does not belong to this operation'
    assert [t['nonce'] for t in txs]==list(range(txs[0]['nonce'],txs[0]['nonce']+len(txs)))
    o.save(label+'.transactions.json',txs);o.save(label+'.receipts.json',receipts)
    verify(label)
    o.save(label+'.journal.json',{**journal,'status':'verified','hashes':hashes})
    report()

def verify(label):
    txs=saved(label+'.transactions.json');rs=saved(label+'.receipts.json')
    if label in ['quotas','mixed']:
        assert len(txs)==1 and txs[0]['to'].lower()==p.LEDGER.lower() and txs[0]['function']=='multicall(bytes[])'
        calls=txs[0]['calls'];assert len(calls)==2
        quota=int(saved(label+'.journal.json')['inputs']['TSV_MULTICALL_QUOTA'])
        expected=['setQuota(bytes32,uint256,bytes32)']*2 if label=='quotas' else ['setQuota(bytes32,uint256,bytes32)','setUsedWad(bytes32,(uint256,uint256)[],bytes32)']
        assert [c['function'] for c in calls]==expected
        assert all(c['arguments'][0].lower()==SID for c in calls)
        qe=p.events(rs,p.LEDGER,'QuotaSet(bytes32,uint256,bytes32)')
        assert len(qe)==(2 if label=='quotas' else 1)
        assert all(e['topics'][1].lower()==SID and o.words(e['data'])[0]==quota for e in qe)
        assert int(o.call(p.LEDGER,'Quota(bytes32)',SID),16)==quota
        result={'quotaWad':str(quota),'internalCalls':calls}
        if label=='mixed':
            args=saved(label+'.journal.json')['inputs'];day=int(args['TSV_MULTICALL_DAY']);used=int(args['TSV_MULTICALL_USED'])
            ev=p.events(rs,p.LEDGER,'UsedWadSet(bytes32,uint256,uint256,bytes32)');assert len(ev)==1
            assert ev[0]['topics'][1].lower()==SID and int(ev[0]['topics'][2],16)==day and o.words(ev[0]['data'])[0]==used
            assert int(o.call(p.LEDGER,'usedWad(bytes32,uint256)',SID,day),16)==used
            result.update(ESTDay=day,usedWad=str(used))
    elif label in ['add1','add2']:
        ev=[e for e in p.events(rs,o.LP,'Transfer(address,address,uint256)') if len(e['topics'])==4 and int(e['topics'][1],16)==0]
        assert len(ev)==1 and o.address(ev[0]['topics'][2]).lower()==p.ACTOR.lower()
        tid=int(ev[0]['topics'][3],16);net=p.transfer_net(rs)
        assert net=={'usdcRaw':100000,'rwtRaw':10**17}
        assert o.words(o.call(o.LP,'getPoolAndPositionInfo(uint256)',tid))[:5]==[int(p.Q,16),int(p.W,16),2000,60,int(o.HOOK,16)]
        assert o.address(o.call(o.LP,'ownerOf(uint256)',tid)).lower()==p.ACTOR.lower()
        assert int(o.call(o.LP,'getPositionLiquidity(uint256)',tid),16)==10**11
        result={'tokenId':tid,'liquidity':str(10**11),**net,'mintTx':ev[0]['transactionHash']}
    else:
        ids=[saved(x+'.verification.json')['tokenId'] for x in ['add1','add2']]
        assert len(txs)==1 and txs[0]['to'].lower()==o.LP.lower() and txs[0]['function']=='multicall(bytes[])'
        assert [int(c['arguments'][0]) for c in txs[0]['calls']]==ids
        assert all(c['function']=='unwindPositionByTsv(uint256,uint128,uint128,bytes)' for c in txs[0]['calls'])
        ev=p.events(rs,o.LP,'TsvPositionUnwound(uint256,address,address,address,address,uint256,uint256,uint256,uint256)')
        assert [int(e['topics'][1],16) for e in ev]==ids
        burns=[e for e in p.events(rs,o.LP,'Transfer(address,address,uint256)') if len(e['topics'])==4 and int(e['topics'][2],16)==0]
        assert sorted(int(e['topics'][3],16) for e in burns)==sorted(ids)
        assert all(o.address(e['topics'][1]).lower()==p.ACTOR.lower() for e in burns)
        for tid in ids:assert int(o.call(o.LP,'getPositionLiquidity(uint256)',tid),16)==0
        net=p.transfer_net(rs);assert -net['usdcRaw']>=198000 and -net['rwtRaw']>=198000000000000000
        result={'tokenIds':ids,'bothBurned':True,'usdcReturnedRaw':-net['usdcRaw'],'rwtReturnedRaw':str(-net['rwtRaw']),
                'events':[{'tokenId':int(e['topics'][1],16),'amountWords':[str(v) for v in o.words(e['data'])[2:]]} for e in ev],
                'note':'实际到账依据底层代币 Transfer 和余额；退出事件 adapter 侧金额可能为 0。'}
    o.save(label+'.verification.json',result);print(label,json.dumps(result,ensure_ascii=False),flush=True)

def execute(label):
    assert not (OUT/(label+'.journal.json')).exists(),'Existing journal: reconcile, never resend blindly'
    assert o.owner().lower()==p.ACTOR.lower()
    mode={'quotas':'QUOTAS','mixed':'MIXED','add1':'ADD','add2':'ADD','unwind':'UNWIND'}[label]
    inputs={'TSV_MULTICALL_ACTION':mode}
    if label in ['quotas','mixed']:
        inputs['TSV_MULTICALL_QUOTA']=str(int(o.call(p.LEDGER,'Quota(bytes32)',SID),16))
        if label=='mixed':
            day=int(o.call(p.LEDGER,'currentESTDay()'),16)
            inputs.update(TSV_MULTICALL_DAY=str(day),TSV_MULTICALL_USED=str(int(o.call(p.LEDGER,'usedWad(bytes32,uint256)',SID,day),16)))
    if label=='unwind':
        for i,add in enumerate(['add1','add2']):inputs['TSV_MULTICALL_NFT_'+str(i)]=str(saved(add+'.verification.json')['tokenId'])
    empty=OUT/'empty';empty.mkdir(exist_ok=True)
    base={k:str(empty) for k in ['FOUNDRY_SRC','FOUNDRY_SCRIPT','FOUNDRY_TEST']}
    base['FOUNDRY_REMAPPINGS']='\n'.join(tomllib.loads((o.ROOT/'foundry.toml').read_text())['profile']['default']['remappings']+['permit2/=lib/v4-periphery/lib/permit2/'])
    operation=o.Operation(o.Target.RWT_MULTICALL,label,{**base,**inputs})
    print('SIMULATING',label,flush=True);sim=o.client.simulate(operation)
    (OUT/(label+'.simulation.log')).write_text(sim.result.stdout+'\n'+sim.result.stderr)
    print(sim.result.stdout,flush=True)
    if not sim.result.succeeded:raise RuntimeError(sim.result.stderr)
    nonce=int(o.rpc('eth_getTransactionCount',[p.ACTOR,'pending']),16)
    assert nonce==int(o.rpc('eth_getTransactionCount',[p.ACTOR,'latest']),16),'Pending transactions'
    o.save(label+'.journal.json',{'status':'broadcasting','startNonce':nonce,'inputs':inputs})
    print('BROADCASTING',label,flush=True);result=o.client.broadcast(sim,'BROADCAST')
    (OUT/(label+'.broadcast.log')).write_text(result.stdout+'\n'+result.stderr)
    print(result.stdout,flush=True)
    if not result.succeeded:raise RuntimeError(result.stderr+'; reconcile before any retry')
    reconcile(label)

def reconcile_unsent(label):
    journal=saved(label+'.journal.json')
    log=(OUT/(label+'.broadcast.log')).read_text()
    assert journal['status']=='broadcasting' and 'could not instantiate forked environment' in log and 'Script ran successfully' not in log
    nonce=journal['startNonce']
    assert int(o.rpc('eth_getTransactionCount',[p.ACTOR,'latest']),16)==nonce
    assert int(o.rpc('eth_getTransactionCount',[p.ACTOR,'pending']),16)==nonce
    artifact=json.loads((o.ROOT/'broadcast/RwtMulticallExercise.s.sol/196/run-latest.json').read_text())
    known=set()
    for other in LABELS:
        path=OUT/(other+'.journal.json')
        if path.exists():
            j=saved(path.name)
            if j['status']=='verified':known.update(j['hashes'])
    assert all(t['hash'] in known for t in artifact['transactions']),'New broadcast artifact requires receipt reconciliation'
    suffix=str(int(time.time()))
    o.save(label+'.no-send-'+suffix+'.json',{'latestNonce':nonce,'pendingNonce':nonce,'failureBeforeFork':True,'artifactOnlyPreviouslyVerifiedTransactions':True})
    (OUT/(label+'.journal.json')).rename(OUT/(label+'.unsent-'+suffix+'.journal.json'))
    (OUT/(label+'.broadcast.log')).rename(OUT/(label+'.unsent-'+suffix+'.broadcast.log'))
    print('Confirmed no transaction sent:',label,nonce,flush=True)

def report():
    doc=OUT.parent/'TRANSACTIONS.md';marker='\n## Multicall 批量交易补充（2026-10-23）'
    base=doc.read_text().split(marker)[0]
    lines=[marker,'','池子：`'+p.POOL+'`。操作地址：`'+p.ACTOR+'`。',
      '按用户确认：同一 securityId 两次 setQuota；第二笔 setQuota + setUsedWad；两次分别投入 0.1 USDC + 0.1 RWT，再由第三笔 multicall 退出两个新 NFT。额度及用量均原值写回。',
      '','| 序号 | 阶段 | 外层调用 | 交易 | 区块 | 状态 |','| --- | --- | --- | --- | --- | --- |']
    details=[];n=0
    for label in LABELS:
        if not (OUT/(label+'.verification.json')).exists():continue
        txs=saved(label+'.transactions.json');rs={r['transactionHash']:r for r in saved(label+'.receipts.json')}
        for t in txs:
            n+=1;r=rs[t['hash']]
            lines.append(f'| {n} | {label} | `{t["function"]}` | [{t["hash"]}](https://www.oklink.com/xlayer/tx/{t["hash"]}) | {int(r["blockNumber"],16)} | 成功 |')
        details+=['','### '+label,'','交易与解码参数（以链上 calldata 为准）：','```json',json.dumps(txs,indent=2,ensure_ascii=False),'```',
                  '核验结果：','```json',json.dumps(saved(label+'.verification.json'),indent=2,ensure_ascii=False),'```']
    lines+=details
    if (OUT/'final.json').exists():lines+=['','### 本轮最终状态','','```json',json.dumps(saved('final.json'),indent=2,ensure_ascii=False),'```']
    lines+=['',f'本轮已记录 {n} 笔成功交易（含加流动性及必要授权）；原始回执、模拟及广播日志保存在 `multicall/` 子目录。','']
    doc.write_text(base+'\n'.join(lines))

def final():
    pre=saved('preflight.json');unwind=saved('unwind.verification.json');mixed=saved('mixed.verification.json')
    block=o.rpc('eth_blockNumber',[])
    raw=o.batch([('q',p.Q,'balanceOf(address)',[p.ACTOR]),('u',p.U,'balanceOf(address)',[p.ACTOR]),
        ('count',o.REG,'getPoolTickCount(bytes32)',[p.POOL]),('pause',o.REG,'getSecurityPauseMode(bytes32)',[SID]),
        ('quota',p.LEDGER,'Quota(bytes32)',[SID]),('used',p.LEDGER,'usedWad(bytes32,uint256)',[SID,mixed['ESTDay']])],block)
    assert int(raw['q'],16)==pre['qBalance']-200000+unwind['usdcReturnedRaw']
    assert int(raw['u'],16)==pre['uBalance']-2*10**17+int(unwind['rwtReturnedRaw'])
    assert int(raw['count'],16)==int(raw['pause'],16)==0
    assert int(raw['quota'],16)==int(mixed['quotaWad']) and int(raw['used'],16)==int(mixed['usedWad'])
    slot='0x'+(int(o.slot(p.POOL),16)+3).to_bytes(32,'big').hex()
    active=int(o.call(o.PM,'extsload(bytes32)',slot,block=block),16)&((1<<128)-1);assert active==0
    result={'block':int(block,16),'poolid':p.POOL,'activeLiquidity':0,'positionCount':0,'pauseMode':0,
            'quotaWad':mixed['quotaWad'],'usedWad':mixed['usedWad'],'ESTDay':mixed['ESTDay'],
            'usdcBalanceRaw':str(int(raw['q'],16)),'rwtBalanceRaw':str(int(raw['u'],16)),**o.state(p.POOL,block)}
    o.save('final.json',result);report();print(json.dumps(result,indent=2),flush=True)

if __name__=='__main__':
    action=sys.argv[1]
    if action=='preflight':preflight()
    elif action in ('all','resume'):
        for label in LABELS:
            if action=='resume' and (OUT/(label+'.journal.json')).exists():
                assert saved(label+'.journal.json')['status']=='verified','Unresolved journal; reconcile first'
                continue
            execute(label)
        final()
    elif action=='reconcile_unsent':reconcile_unsent(sys.argv[2])
    elif action=='reconcile':reconcile(sys.argv[2])
    elif action=='final':final()
    elif action=='report':report()
    elif action in LABELS:execute(action)
    else:raise SystemExit('Unknown action')
