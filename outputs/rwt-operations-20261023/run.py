"""Task-specific RWT pool and administration exercise; credentials use the SDK loader."""
import importlib.util
import json
import sys
import subprocess
from decimal import Decimal
from pathlib import Path

OUT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('ops',OUT.parent/'volorost2-usdt-20261022/run.py')
ops=importlib.util.module_from_spec(spec);spec.loader.exec_module(ops);ops.OUT=OUT
ACTOR='0x224467f6640AbE0A62D1be98187912627b59722A'
Q='0xb6ceceab302e2e4948951ee7843fc24e92933061'
W='0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c'
U='0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0'
OLD='0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3'
LEDGER=ops.env['TSV_LEDGER']
PRICE=(1<<96)*10**6
POOL=ops.cast('keccak',ops.cast('abi-encode','f(address,address,uint24,int24,address)',Q,W,2000,60,ops.HOOK))
ROLES=['HALT_REPORTER_ROLE','VOLUME_ORACLE_ROLE','FORCE_EXIT_ADMIN_ROLE']

def inspect():
    assert int(ops.rpc('eth_chainId',[]),16)==196
    signer=ops.owner();block=ops.rpc('eth_blockNumber',[])
    queries=[('oldPool',ops.REG,'getPool(bytes32)',[OLD]),('newKnown',ops.REG,'isKnownPool(bytes32)',[POOL]),
      ('underlying',ops.REG,'getUnderlying(address)',[U]),('currencyUnderlying',ops.REG,'getCurrencyUnderlying(address)',[W]),
      ('quote',ops.REG,'getQuoteToken(address)',[Q]),('qDecimals',Q,'decimals()',[]),('uDecimals',U,'decimals()',[]),('wDecimals',W,'decimals()',[]),
      ('qBalance',Q,'balanceOf(address)',[ACTOR]),('uBalance',U,'balanceOf(address)',[ACTOR]),('multiplier',U,'uiMultiplier()',[]),
      ('checker',W,'allowListChecker()',[]),('adapterUnderlying',W,'PERMISSIONED_TOKEN()',[]),('lpAdmission',W,'isAllowed(address,bytes2)',[ACTOR,'0x0002']),
      ('unwindAdmission',W,'isAllowed(address,bytes2)',[ACTOR,'0x8000']),('sbtLP',ops.REG,'isSbtAllowed(bytes2,address)',['0x0002',ACTOR]),
      ('factory',ops.REG,'permissionsAdapterFactory()',[]),('lpFactory',ops.LP,'PERMISSIONS_ADAPTER_FACTORY()',[]),
      ('ledgerRegistry',LEDGER,'registry()',[]),('lpRegistry',ops.LP,'registry()',[]),('paused',ops.REG,'isPaused()',[]),
      ('day',LEDGER,'currentESTDay()',[]),('creator',ops.REG,'hasRole(bytes32,address)',[ops.cast('keccak','POOL_CREATOR_ROLE'),ACTOR])]
    for role in ROLES:
        hashed=ops.cast('keccak',role)
        queries += [(role,ops.REG,'hasRole(bytes32,address)',[hashed,ACTOR]),(role+'_admin',ops.REG,'getRoleAdmin(bytes32)',[hashed])]
    raw=ops.batch(queries,block)
    assert all(isinstance(v,str) for v in raw.values()),raw
    ur=ops.words(raw['underlying']);sid='0x'+ur[0].to_bytes(32,'big').hex();day=int(raw['day'],16)
    extra=[('security',ops.REG,'getSecurity(bytes32)',[sid]),('pauseMode',ops.REG,'getSecurityPauseMode(bytes32)',[sid]),
      ('quota',LEDGER,'Quota(bytes32)',[sid]),('used',LEDGER,'usedWad(bytes32,uint256)',[sid,day]),
      ('factoryVerified',ops.address(raw['factory']),'verifiedPermissionsAdapterOf(address)',[W])]
    for role in ROLES:extra.append((role+'_canGrant',ops.REG,'hasRole(bytes32,address)',[raw[role+'_admin'],signer]))
    raw.update(ops.batch(extra,block))
    pre={'chainId':196,'block':int(block,16),'signer':signer,'actor':ACTOR,'poolid':POOL,'oldPoolid':OLD,
         'currency0':Q,'currency1':W,'underlying':U,'fee':2000,'tickSpacing':60,'hooks':ops.HOOK,'sqrtPriceX96':str(PRICE),
         'securityId':sid,'day':day,'quota':str(int(raw['quota'],16)),'usedWad':str(int(raw['used'],16)),
         'qBalance':str(int(raw['qBalance'],16)),'uBalance':str(int(raw['uBalance'],16)),
         'nativeBalance':str(int(ops.rpc('eth_getBalance',[signer,block]),16)),
         'roles':{role:bool(int(raw[role],16)) for role in ROLES},
         'canGrant':{role:bool(int(raw[role+'_canGrant'],16)) for role in ROLES},
         'lpAdmission':bool(int(raw['lpAdmission'],16)),'unwindAdmission':bool(int(raw['unwindAdmission'],16)),
         'newState':ops.state(POOL,block),'raw':raw}
    ops.save('preflight.json',pre)
    print(json.dumps({k:v for k,v in pre.items() if k!='raw'},indent=2),flush=True)
    assert signer.lower()==ACTOR.lower(),'Configured signer differs from requested operator'
    assert int(raw['qDecimals'],16)==6 and int(raw['uDecimals'],16)==int(raw['wDecimals'],16)==18
    assert ops.address(raw['currencyUnderlying']).lower()==ops.address(raw['factoryVerified']).lower()==U.lower()
    assert int(raw['qBalance'],16)>=500000 and int(raw['uBalance'],16)>=5*10**17,'Insufficient funds'
    assert int(raw['sbtLP'],16)==int(raw['lpAdmission'],16)==int(raw['creator'],16)==1
    assert int(raw['paused'],16)==int(raw['pauseMode'],16)==0,'Existing pause requires reassessment'
    return pre

def saved(name):return json.loads((OUT/name).read_text())
def load():
    pre=saved('preflight.json')
    assert ops.owner().lower()==ACTOR.lower()
    return pre
def canonicalize(label):
    original=saved(label+'.transactions.json')
    backup=OUT/(label+'.foundry-transactions.json')
    if not backup.exists():ops.save(backup.name,original)
    signatures=['grantRole(bytes32,address)','initializePool((address,address,uint24,int24,address),uint160)',
      'approve(address,uint256)','modifyLiquidities(bytes,uint256)','applySecurityStatus(bytes32,uint8,bool,bytes32)',
      'setQuota(bytes32,uint256,bytes32)','setUsedWad(bytes32,(uint256,uint256)[],bytes32)','unwindPositionByTsv(uint256,uint128,uint128,bytes)']
    selectors={ops.cast('sig',s).lower():s for s in signatures}
    actual=[];chains=[]
    for tx in original['transactions']:
        chain=ops.rpc('eth_getTransactionByHash',[tx['hash']]);assert chain and chain['hash'].lower()==tx['hash'].lower()
        assert chain['from'].lower()==ACTOR.lower() and int(chain['value'],16)==0
        sig=selectors[chain['input'][:10].lower()]
        arguments=json.loads(ops.cast('decode-calldata','--json',sig,chain['input']))
        actual.append({'hash':chain['hash'],'transactionType':'CALL','contractAddress':chain['to'],
            'function':sig,'arguments':arguments,'nonce':int(chain['nonce'],16),'input':chain['input']})
        chains.append(chain)
    actual.sort(key=lambda t:t['nonce'])
    byhash={r['transactionHash'].lower():r for r in saved(label+'.receipts.json')}
    receipts=[byhash[t['hash'].lower()] for t in actual]
    ops.save(label+'.canonical-transactions.json',chains)
    ops.save(label+'.transactions.json',{'transactions':actual,'source':'eth_getTransactionByHash, decoded calldata, sorted by sender nonce'})
    ops.save(label+'.receipts.json',receipts)
    return {'transactions':actual},receipts
def execute(label,target,inputs,expected_count=None):
    record,receipts=ops.execute(label,target,inputs)
    record,receipts=canonicalize(label)
    if expected_count is not None:assert len(receipts)==expected_count,('unexpected transaction count',label,len(receipts))
    assert all(r['from'].lower()==ACTOR.lower() for r in receipts)
    return record,receipts
def exercise(label,action,inputs=None,count=None):
    return execute(label,ops.Target.RWT_OPERATIONS,{'TSV_EXERCISE_ACTION':action,**(inputs or {})},count)
def events(receipts,address,signature):
    topic=ops.cast('keccak',signature).lower()
    return [l for r in receipts for l in r['logs'] if l['address'].lower()==address.lower() and l['topics'] and l['topics'][0].lower()==topic]
def transfer_net(receipts):
    result={Q.lower():0,U.lower():0}
    topic=ops.cast('keccak','Transfer(address,address,uint256)').lower()
    for r in receipts:
        for log in r['logs']:
            if log['address'].lower() not in result or len(log['topics'])!=3 or log['topics'][0].lower()!=topic:continue
            n=int(log['data'],16);k=log['address'].lower()
            if ops.address(log['topics'][1]).lower()==ACTOR.lower():result[k]+=n
            if ops.address(log['topics'][2]).lower()==ACTOR.lower():result[k]-=n
    return {'usdcRaw':result[Q.lower()],'rwtRaw':result[U.lower()]}
def verify_liquidity(receipts):
    mints=[l for l in events(receipts,ops.LP,'Transfer(address,address,uint256)') if len(l['topics'])==4 and int(l['topics'][1],16)==0 and ops.address(l['topics'][2]).lower()==ACTOR.lower()]
    assert len(mints)==1
    tokenid=int(mints[0]['topics'][3],16)
    delta=transfer_net(receipts)
    assert 499999<=delta['usdcRaw']<=500000 and 5*10**17-10**11<=delta['rwtRaw']<=5*10**17
    key=ops.words(ops.call(ops.LP,'getPoolAndPositionInfo(uint256)',tokenid))
    assert key[:5]==[int(Q,16),int(W,16),2000,60,int(ops.HOOK,16)]
    assert ops.address(ops.call(ops.LP,'ownerOf(uint256)',tokenid)).lower()==ACTOR.lower()
    liquidity=int(ops.call(ops.LP,'getPositionLiquidity(uint256)',tokenid),16)
    assert liquidity>0
    result={'tokenId':tokenid,'poolid':POOL,'liquidity':str(liquidity),**delta,
        'usdc':str(Decimal(delta['usdcRaw'])/10**6),'rwt':str(Decimal(delta['rwtRaw'])/10**18),
        'tickLower':-887220,'tickUpper':887220,'liquidityTx':mints[0]['transactionHash']}
    ops.save('liquidity-verification.json',result);print(json.dumps(result,indent=2),flush=True)
    return result

def report():
    pre=saved('preflight.json')
    stages=[('roles','授予接口操作角色'),('initialize','创建 RWT/USDC 新池'),('liquidity','授权及添加流动性'),
            ('status','LP/Swap 暂停与恢复'),('quota','setQuota 原值写回'),('used','setUsedWad 原值写回'),('unwind','退出新仓位')]
    lines=['# RWT-USDC 新池与管理接口交易记录','',
      '网络：X Layer Mainnet（196）。执行日期：2026-10-23。',
      f'操作账户：`{ACTOR}`。全部写操作先模拟再广播，成功回执及事件另存同目录。','',
      '## 已确认参数','',
      f'- 新 pool ID：`{POOL}`',f'- 参考 pool ID：`{OLD}`',
      f'- currency0 / USDC：`{Q}`，decimals=6。',f'- currency1 / RWT Adapter：`{W}`，decimals=18。',
      f'- RWT 底层 U：`{U}`。',f'- Hook：`{ops.HOOK}`。',
      f'- fee=2000（0.2%），tickSpacing=60，初始 sqrtPriceX96=`{PRICE}`，tick=276324，1 USDC = 1 RWT。',
      '- 新仓位两侧投入上限分别为 0.5 USDC 和 0.5 RWT；采用全区间 [-887220, 887220]，真实输入按链上转账计算。',
      f'- Security ID：`{pre["securityId"]}`。暂停和额度作用于该证券全部池。',
      '- 按用户确认，setQuota 和当前 EST 日 setUsedWad 均原值写回；每个接口各一笔。',
      '- applySecurityStatus 四笔独立交易：LP 暂停、LP 恢复、Swap 暂停、Swap 恢复。',
      '- unwindPositionByTsv 仅销毁本次新池铸造的 NFT，返还资产给该 NFT 的持有人。','',
      '## 角色','', '| 接口 | Registry 角色 |', '| --- | --- |',
      '| applySecurityStatus | HALT_REPORTER_ROLE |','| setQuota / setUsedWad | VOLUME_ORACLE_ROLE |',
      '| unwindPositionByTsv | FORCE_EXIT_ADMIN_ROLE |','',
      '## 全部交易','', '| 序号 | 阶段 | 合约 / 方法 | 交易 | 区块 | Gas used | 状态 |',
      '| --- | --- | --- | --- | --- | --- | --- |']
    n=0;details=[]
    for stage,title in stages:
        if not (OUT/(stage+'.transactions.json')).exists():continue
        txs=saved(stage+'.transactions.json')['transactions']; receipts=saved(stage+'.receipts.json')
        byhash={r['transactionHash'].lower():r for r in receipts if r}
        for tx in txs:
            n+=1;h=tx['hash'];r=byhash[h.lower()];fn=tx['function'] or tx['transactionType']
            status='成功' if r['status']=='0x1' else '失败'
            lines.append(f'| {n} | {title} | `{fn}` | [{h}](https://www.oklink.com/xlayer/tx/{h}) | {int(r["blockNumber"],16)} | {int(r["gasUsed"],16)} | {status} |')
            details += [f'### {n}. {title} — {fn}','',f'- 目标合约：`{r["to"]}`',f'- 交易：`{h}`','',
                        '参数：','```json',json.dumps(tx.get('arguments'),indent=2,ensure_ascii=False),'```','']
    lines+=['','## 交易参数','']+details
    for name,title in [('liquidity-verification.json','实际入池及新仓位'),('status-verification.json','四笔暂停恢复事件'),('quota-verification.json','额度写回'),('used-verification.json','已用量写回'),('unwind-verification.json','退出结果'),('final-verification.json','最终链上状态')]:
        if (OUT/name).exists():lines += ['','## '+title,'','```json',json.dumps(saved(name),indent=2,ensure_ascii=False),'```']
    lines+=['','当前已记录交易数：'+str(n)+'。','',
      '交易参数及排序以 eth_getTransactionByHash 返回的真实 calldata 和 nonce 为准。Foundry 对多笔广播的本地 hash/参数配对曾出现错位，原文件保留为 *.foundry-transactions.json；本报告使用链上校正后的记录。',
      'Lark 日志此前写入返回 forBidden，未自动重试；本次按用户要求以此 Markdown 及同目录原始回执交付。','']
    (OUT/'TRANSACTIONS.md').write_text('\n'.join(lines))
    print('Markdown updated:',OUT/'TRANSACTIONS.md',flush=True)

if __name__=='__main__':
    stage=sys.argv[1]
    if stage in ('continue','finish','tail','last'):
        stages={'continue':['initialize','liquidity','status','quota','used','unwind','final'],
                'finish':['status','quota','used','unwind','final'],'tail':['quota','used','unwind','final'],
                'last':['used','unwind','final']}[stage]
        for next_stage in stages:
            print('NEXT STAGE:',next_stage,flush=True)
            subprocess.run([sys.executable,str(Path(__file__).resolve()),next_stage],check=True)
    elif stage=='inspect': inspect()
    elif stage=='reconcile_status':
        pre=load();assert int(ops.rpc('eth_chainId',[]),16)==196
        latest=int(ops.rpc('eth_getTransactionCount',[ACTOR,'latest']),16)
        pending=int(ops.rpc('eth_getTransactionCount',[ACTOR,'pending']),16)
        root=ops.ROOT/'broadcast/RwtOperationsExercise.s.sol/196'
        dry=json.loads((root/'dry-run/run-latest.json').read_text())
        sent=json.loads((root/'run-latest.json').read_text())
        assert len(dry['transactions'])==4 and all(t.get('function')=='applySecurityStatus(bytes32,uint8,bool,bytes32)' and t.get('hash') is None for t in dry['transactions'])
        expected=int(dry['transactions'][0]['transaction']['nonce'],16)
        assert {t['hash'] for t in sent['transactions']}=={t['hash'] for t in saved('liquidity.transactions.json')['transactions']},'Broadcast artifact changed'
        pause=int(ops.call(ops.REG,'getSecurityPauseMode(bytes32)',pre['securityId']),16)
        result={'latestNonce':latest,'pendingNonce':pending,'expectedFirstStatusNonce':expected,'pauseMode':pause,
                'logRangeQuery':'RPC rejected eth_getLogs with HTTP 400; reconciliation uses exact sender nonce and broadcast artifact',
                'broadcastArtifactStillContainsOnlyLiquidity':True,'noStatusTransactionSent':latest==pending==expected and pause==0}
        ops.save('status-recovery.json',result);print(json.dumps(result,indent=2),flush=True)
        assert result['noStatusTransactionSent'],'Do not retry without further reconciliation'
        (OUT/'status.journal.json').rename(OUT/'status.failed-before-send.journal.json')
        (OUT/'status.broadcast.log').rename(OUT/'status.failed-before-send.broadcast.log')
    elif stage=='report':report()
    elif stage=='reconcile_used':
        load();root=ops.ROOT/'broadcast/VolumeLedgerOperations.s.sol/196'
        dry=json.loads((root/'dry-run/run-latest.json').read_text())
        sent=json.loads((root/'run-latest.json').read_text())
        assert len(dry['transactions'])==1 and dry['transactions'][0].get('function')=='setUsedWad(bytes32,(uint256,uint256)[],bytes32)'
        assert dry['transactions'][0].get('hash') is None
        expected=int(dry['transactions'][0]['transaction']['nonce'],16)
        latest=int(ops.rpc('eth_getTransactionCount',[ACTOR,'latest']),16)
        pending=int(ops.rpc('eth_getTransactionCount',[ACTOR,'pending']),16)
        assert {t['hash'] for t in sent['transactions']}=={t['hash'] for t in saved('quota.transactions.json')['transactions']}
        result={'latestNonce':latest,'pendingNonce':pending,'expectedNonce':expected,'broadcastArtifactStillQuota':True,
                'noUsedTransactionSent':latest==pending==expected}
        ops.save('used-recovery.json',result);print(json.dumps(result,indent=2),flush=True)
        assert result['noUsedTransactionSent']
        (OUT/'used.journal.json').rename(OUT/'used.failed-before-send.journal.json')
        (OUT/'used.broadcast.log').rename(OUT/'used.failed-before-send.broadcast.log')
    elif stage=='audit_completed':
        pre=load()
        for label in ['roles','initialize','liquidity','status']:canonicalize(label)
        receipts=saved('status.receipts.json')
        ev=events(receipts,ops.REG,'SecurityStatusChanged(bytes32,uint8,uint8)')
        values=[ops.words(e['data']) for e in ev]
        assert values==[[0,2],[2,0],[0,1],[1,0]]
        assert int(ops.call(ops.REG,'getSecurityPauseMode(bytes32)',pre['securityId']),16)==0
        ops.save('status-verification.json',[{'transactionHash':e['transactionHash'],'previousMode':v[0],'newMode':v[1]} for e,v in zip(ev,values)])
        verify_liquidity(saved('liquidity.receipts.json'))
        report();print('Canonical chain metadata reconciled; status restored; NFT verified',flush=True)
    elif stage=='status_audit':
        pre=load();txs=saved('status.transactions.json')['transactions'];rows=[]
        for t in txs:
            chain=ops.rpc('eth_getTransactionByHash',[t['hash']])
            receipt=ops.rpc('eth_getTransactionReceipt',[t['hash']])
            assert chain and receipt and receipt['status']=='0x1'
            ev=events([receipt],ops.REG,'SecurityStatusChanged(bytes32,uint8,uint8)')
            assert len(ev)==1
            args=ops.words('0x'+chain['input'][10:])
            rows.append({'hash':t['hash'],'nonce':int(chain['nonce'],16),'block':int(chain['blockNumber'],16),
                'transactionIndex':int(chain['transactionIndex'],16),'mode':args[1],'enable':bool(args[2]),
                'reasonCode':'0x'+args[3].to_bytes(32,'big').hex(),'eventWords':ops.words(ev[0]['data']),
                'input':chain['input'],'from':chain['from'],'to':chain['to'],'localArgs':t['arguments']})
        rows.sort(key=lambda r:r['nonce'])
        result={'transactions':rows,'currentPauseMode':int(ops.call(ops.REG,'getSecurityPauseMode(bytes32)',pre['securityId']),16)}
        ops.save('status-canonical-audit.json',result);print(json.dumps(result,indent=2))
    elif stage=='roles':
        pre=load();record,receipts=exercise('roles','GRANT_ROLES',count=sum(not x for x in pre['roles'].values()))
        assert all(int(ops.call(ops.REG,'hasRole(bytes32,address)',ops.cast('keccak',role),ACTOR),16)==1 for role in ROLES)
        assert len(events(receipts,ops.REG,'RoleGranted(bytes32,address,address)'))==3
        report()
    elif stage=='initialize':
        pre=load()
        assert int(ops.call(ops.REG,'isKnownPool(bytes32)',POOL),16)==0
        record,receipts=execute('initialize',ops.Target.INITIALIZE_POOLS,{'TSV_POOL_COUNT':'1',
          'TSV_POOL_CURRENCY0_0':Q,'TSV_POOL_CURRENCY1_0':W,'TSV_POOL_FEE_0':'2000','TSV_POOL_TICK_SPACING_0':'60',
          'TSV_POOL_HOOK_0':ops.HOOK,'TSV_POOL_SQRT_PRICE_X96_0':str(PRICE)},1)
        assert ops.state(POOL)['sqrtPriceX96']==str(PRICE)
        ev=events(receipts,ops.PM,'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)')
        assert len(ev)==1 and ev[0]['topics'][1].lower()==POOL.lower()
        assert ops.words(ev[0]['data'])==[2000,60,int(ops.HOOK,16),PRICE,276324]
        report()
    elif stage=='liquidity':
        load();record,receipts=exercise('liquidity','ADD_LIQUIDITY')
        verify_liquidity(receipts);report()
    elif stage=='status':
        pre=load();record,receipts=exercise('status','PAUSE_RESUME',count=4)
        ev=events(receipts,ops.REG,'SecurityStatusChanged(bytes32,uint8,uint8)')
        assert len(ev)==4
        values=[ops.words(e['data']) for e in ev]
        assert values==[[0,2],[2,0],[0,1],[1,0]],values
        assert all(e['topics'][1].lower()==pre['securityId'].lower() for e in ev)
        assert int(ops.call(ops.REG,'getSecurityPauseMode(bytes32)',pre['securityId']),16)==0
        ops.save('status-verification.json',[{'transactionHash':e['transactionHash'],'previousMode':v[0],'newMode':v[1]} for e,v in zip(ev,values)])
        report()
    elif stage=='quota':
        pre=load();sid=pre['securityId'];value=int(ops.call(LEDGER,'Quota(bytes32)',sid),16)
        reason=ops.cast('keccak','RWT_EXERCISE_20261023_QUOTA_SAME_VALUE')
        record,receipts=execute('quota',ops.Target.LEDGER_OPERATION,{'TSV_LEDGER_ACTION':'SET_QUOTA','TSV_LEDGER_SECURITY_ID':sid,
          'TSV_QUOTA_AMOUNT_WAD':str(value),'TSV_SET_QUOTA_REASON_CODE':reason},1)
        ev=events(receipts,LEDGER,'QuotaSet(bytes32,uint256,bytes32)');assert len(ev)==1
        assert ops.words(ev[0]['data'])==[value,int(reason,16)]
        assert int(ops.call(LEDGER,'Quota(bytes32)',sid),16)==value
        ops.save('quota-verification.json',{'securityId':sid,'previousQuotaWad':str(value),'newQuotaWad':str(value),'reasonCode':reason})
        report()
    elif stage=='used':
        pre=load();sid=pre['securityId'];day=int(ops.call(LEDGER,'currentESTDay()'),16)
        value=int(ops.call(LEDGER,'usedWad(bytes32,uint256)',sid,day),16)
        reason=ops.cast('keccak','RWT_EXERCISE_20261023_USED_SAME_VALUE')
        record,receipts=execute('used',ops.Target.LEDGER_OPERATION,{'TSV_LEDGER_ACTION':'SET_USED_WAD','TSV_LEDGER_SECURITY_ID':sid,
          'TSV_USED_WAD_COUNT':'1','TSV_USED_WAD_EST_DAY_0':str(day),'TSV_USED_WAD_AMOUNT_0':str(value),'TSV_SET_USED_WAD_REASON_CODE':reason},1)
        ev=events(receipts,LEDGER,'UsedWadSet(bytes32,uint256,uint256,bytes32)');assert len(ev)==1
        assert int(ev[0]['topics'][2],16)==day and ops.words(ev[0]['data'])==[value,int(reason,16)]
        assert int(ops.call(LEDGER,'usedWad(bytes32,uint256)',sid,day),16)==value
        ops.save('used-verification.json',{'securityId':sid,'ESTDay':day,'previousUsedWad':str(value),'newUsedWad':str(value),'reasonCode':reason})
        report()
    elif stage in ('unwind','verify_unwind'):
        load();position=saved('liquidity-verification.json');tid=position['tokenId']
        minQ=position['usdcRaw']*99//100;minU=position['rwtRaw']*99//100
        if stage=='verify_unwind':
            txs=saved('unwind.transactions.json')['transactions'];assert len(txs)==1
            receipts=[ops.rpc('eth_getTransactionReceipt',[t['hash']]) for t in txs]
            assert all(r and int(r['status'],16)==1 for r in receipts),'Receipt not yet available or failed; no retry broadcast'
            ops.save('unwind.receipts.json',receipts)
            record,receipts=canonicalize('unwind')
            assert record['transactions'][0]['function']=='unwindPositionByTsv(uint256,uint128,uint128,bytes)'
            assert [str(x) for x in record['transactions'][0]['arguments']]==[str(tid),str(minQ),str(minU),'0x']
            ops.save('unwind.journal.json',{'status':'verified','hashes':[r['transactionHash'] for r in receipts]})
        else:
            record,receipts=exercise('unwind','UNWIND',{'TSV_EXERCISE_TOKEN_ID':str(tid),
              'TSV_EXERCISE_EXPECTED_LIQUIDITY':position['liquidity'],'TSV_EXERCISE_MIN_Q':str(minQ),'TSV_EXERCISE_MIN_U':str(minU)},1)
        ev=events(receipts,ops.LP,'TsvPositionUnwound(uint256,address,address,address,address,uint256,uint256,uint256,uint256)')
        assert len(ev)==1 and int(ev[0]['topics'][1],16)==tid
        assert ops.address(ev[0]['topics'][2]).lower()==ACTOR.lower()
        vals=ops.words(ev[0]['data']);assert vals[:2]==[int(Q,16),int(W,16)] and vals[3]==vals[5]==0
        net=transfer_net(receipts);returnedQ=-net['usdcRaw'];returnedU=-net['rwtRaw']
        assert returnedQ==vals[2] and returnedQ>=minQ and returnedU>=minU
        # The deployed event reports zero for the adapter side after auto-redemption.
        # Actual underlying transfers are the authoritative returned-asset evidence.
        assert vals[4] in (0,returnedU)
        underlyingTransfers=events(receipts,U,'Transfer(address,address,uint256)')
        assert any(ops.address(l['topics'][1]).lower()==W.lower() and
                   ops.address(l['topics'][2]).lower()==ACTOR.lower() and int(l['data'],16)==returnedU
                   for l in underlyingTransfers)
        burns=[l for l in events(receipts,ops.LP,'Transfer(address,address,uint256)') if len(l['topics'])==4 and int(l['topics'][2],16)==0 and int(l['topics'][3],16)==tid]
        assert len(burns)==1 and ops.address(burns[0]['topics'][1]).lower()==ACTOR.lower()
        assert int(ops.call(ops.LP,'getPositionLiquidity(uint256)',tid),16)==0
        result={'tokenId':tid,'poolid':POOL,'nftBurned':True,'usdcReturnedRaw':returnedQ,'rwtReturnedRaw':returnedU,
          'usdcReturned':str(Decimal(returnedQ)/10**6),'rwtReturned':str(Decimal(returnedU)/10**18),
          'eventLpAmount0':str(vals[2]),'eventLpAmount1':str(vals[4]),
          'evidenceNote':'退出事件的 adapter 侧 lpAmount1 为 0；实际 RWT 返还依据底层 U 的 Transfer 日志和最终余额核验。',
          'minimumUsdcRaw':minQ,'minimumRwtRaw':str(minU),'recipient':ACTOR,'transactionHash':receipts[0]['transactionHash']}
        ops.save('unwind-verification.json',result);print(json.dumps(result,indent=2));report()
    elif stage=='final':
        pre=load();sid=pre['securityId'];block=ops.rpc('eth_blockNumber',[])
        qs=[('pool',ops.REG,'getPool(bytes32)',[POOL]),('pauseMode',ops.REG,'getSecurityPauseMode(bytes32)',[sid]),
          ('count',ops.REG,'getPoolTickCount(bytes32)',[POOL]),('quota',LEDGER,'Quota(bytes32)',[sid]),
          ('qBalance',Q,'balanceOf(address)',[ACTOR]),('uBalance',U,'balanceOf(address)',[ACTOR])]
        used=saved('used-verification.json');qs.append(('used',LEDGER,'usedWad(bytes32,uint256)',[sid,used['ESTDay']]))
        for role in ROLES:qs.append((role,ops.REG,'hasRole(bytes32,address)',[ops.cast('keccak',role),ACTOR]))
        raw=ops.batch(qs,block);pool=ops.words(raw['pool'])
        assert pool[:8]==[int(Q,16),int(W,16),2000,60,int(ops.HOOK,16),int(sid,16),2,1]
        assert int(raw['pauseMode'],16)==int(raw['count'],16)==0
        assert int(raw['quota'],16)==int(saved('quota-verification.json')['newQuotaWad'])
        assert int(raw['used'],16)==int(used['newUsedWad'])
        assert all(int(raw[r],16)==1 for r in ROLES)
        position=saved('liquidity-verification.json');unwind=saved('unwind-verification.json')
        assert int(raw['qBalance'],16)==int(pre['qBalance'])-position['usdcRaw']+unwind['usdcReturnedRaw']
        assert int(raw['uBalance'],16)==int(pre['uBalance'])-position['rwtRaw']+unwind['rwtReturnedRaw']
        slot='0x'+(int(ops.slot(POOL),16)+3).to_bytes(32,'big').hex()
        liquidity=int(ops.call(ops.PM,'extsload(bytes32)',slot,block=block),16)&((1<<128)-1)
        assert liquidity==0
        result={'poolid':POOL,'currency0':Q,'currency1':W,'fee':2000,'tickSpacing':60,'hooks':ops.HOOK,
          **ops.state(POOL,block),'securityId':sid,'tierId':2,'lifecycle':'LIST','activeLiquidity':str(liquidity),
          'positionCount':0,'pauseMode':0,'roles':{r:True for r in ROLES},'quotaWad':str(int(raw['quota'],16)),
          'usedWad':str(int(raw['used'],16)),'ESTDay':used['ESTDay'],'verificationBlock':int(block,16),
          'usdcBalanceRaw':str(int(raw['qBalance'],16)),'rwtBalanceRaw':str(int(raw['uBalance'],16))}
        ops.save('final-verification.json',result);print(json.dumps(result,indent=2));report()
    else:raise SystemExit('Unsupported action')
