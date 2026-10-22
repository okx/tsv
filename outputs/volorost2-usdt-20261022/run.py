"""Task-scoped X Layer pool operations and public RPC evidence."""
import json, os, subprocess, sys, urllib.request, tomllib, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'sdk/python'))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target
client = ExecutionClient(root=ROOT)
env = client._environment(Operation(Target.INSPECT_ASSETS, 'Read operator configuration', {}))
RPC = env['XLAYER_RPC_URL']
REG = env['TSV_REGISTRY']; LP = env['TSV_LP_MANAGER']; PM = env['TSV_POOL_MANAGER']; ROUTER = env['TSV_ROUTER']
U = '0xC03484ab791B5BD2C3DA860BEa2Ba96C76248BFD'
W = '0x9f212c1DCc9e8026d30Ff38b01B72687EAab747b'
Q = '0x779ded0c9e1022225f8e0630b35a9b54be713736'
HOOK = '0xbc6d8c8a8b681872a93554116f01268f80c9ffff'
CHECKER = '0xbB1716d2a3fc6215C306a8942A2842F486e1C4B1'
FACT = '0x92cdb229613dA8ca45E375cf69dF4b3b645FF48D'
OLD = '0x2d3060b174b06265f3dd0659975b1c85c5082a6bb81506520316d19635e358ae'
def cast(*args):
    p = subprocess.run(['cast', *map(str,args)], capture_output=True, text=True, timeout=45)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()
def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=30) as response: data=json.load(response)
    if 'error' in data: raise RuntimeError(str(data['error']))
    return data['result']
def save(name, value): (OUT / name).write_text(json.dumps(value,indent=2)+'\n')
def words(value): return [int(value[i:i+64],16) for i in range(2,len(value),64)]
def address(value): return '0x'+value[-40:]
def call(to,sig,*args,block='latest'): return rpc('eth_call',[{'to':to,'data':cast('calldata',sig,*args)},block])
def batch(queries,block):
    if len(queries)>10:
        result={}
        for start in range(0,len(queries),10): result.update(batch(queries[start:start+10],block))
        return result
    requests=[{'jsonrpc':'2.0','id':i,'method':'eth_call','params':[{'to':to,'data':cast('calldata',sig,*args)},block]} for i,(_,to,sig,args) in enumerate(queries)]
    req=urllib.request.Request(RPC,data=json.dumps(requests).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=45) as r: responses=json.load(r)
    if not isinstance(responses,list): raise RuntimeError(str(responses))
    return {queries[r['id']][0]:r.get('result',r.get('error')) for r in responses}
def owner():
    p=subprocess.run(['bash','-c','cast wallet address --private-key "$XLAYER_PRIVATE_KEY"'],env=env,capture_output=True,text=True)
    if p.returncode: raise RuntimeError('Cannot derive operation wallet')
    return p.stdout.strip()
def slot(poolid): return cast('keccak',cast('abi-encode','f(bytes32,uint256)',poolid,6))
def state(poolid,block='latest'):
    n=int(call(PM,'extsload(bytes32)',slot(poolid),block=block),16)
    tick=(n>>160)&((1<<24)-1)
    if tick & (1<<23): tick-=1<<24
    return {'sqrtPriceX96':str(n&((1<<160)-1)),'tick':tick,'protocolFee':(n>>184)&((1<<24)-1),'lpFee':(n>>208)&((1<<24)-1)}
def loadplan():
    p=json.loads((OUT/'plan.json').read_text())
    assert p['signer'].lower()==owner().lower(), 'Operation wallet changed'
    return p
def execute(label,target,inputs):
    journal=OUT/(label+'.journal.json')
    assert not journal.exists(), 'Existing broadcast journal: reconcile before any retry'
    (OUT/'empty').mkdir(exist_ok=True)
    base={'FOUNDRY_SRC':str(OUT/'empty'),'FOUNDRY_SCRIPT':str(OUT/'empty'),'FOUNDRY_TEST':str(OUT/'empty')}
    base['FOUNDRY_REMAPPINGS']='\n'.join(tomllib.loads((ROOT/'foundry.toml').read_text())['profile']['default']['remappings']+['permit2/=lib/v4-periphery/lib/permit2/'])
    op=Operation(target,label,{**base,**inputs})
    print('SIMULATING',label,flush=True)
    sim=client.simulate(op)
    (OUT/(label+'.simulation.log')).write_text(sim.result.stdout+'\n'+sim.result.stderr)
    print(sim.result.stdout,flush=True)
    if not sim.result.succeeded:
        print(sim.result.stderr,flush=True)
        raise RuntimeError('Simulation failed; no broadcast')
    save(journal.name,{'status':'broadcasting','time':int(time.time()),'inputs':inputs})
    print('SIMULATION PASSED; BROADCASTING',label,flush=True)
    result=client.broadcast(sim,'BROADCAST')
    (OUT/(label+'.broadcast.log')).write_text(result.stdout+'\n'+result.stderr)
    print(result.stdout,flush=True)
    if not result.succeeded:
        print(result.stderr,flush=True)
        raise RuntimeError('Broadcast incomplete; reconcile receipts before retry')
    record=json.loads((ROOT/'broadcast'/target.script.split(':')[0]/'196/run-latest.json').read_text())
    public={'transactions':[{k:t.get(k) for k in ['hash','transactionType','contractAddress','function','arguments']} for t in record['transactions']]}
    save(label+'.transactions.json',public)
    receipts=[rpc('eth_getTransactionReceipt',[t['hash']]) for t in public['transactions']]
    save(label+'.receipts.json',receipts)
    assert receipts and all(r and int(r['status'],16)==1 for r in receipts), 'Missing or failed receipt'
    save(journal.name,{'status':'verified','hashes':[r['transactionHash'] for r in receipts]})
    return public,receipts
if __name__=='__main__':
    stage=sys.argv[1]
    if stage=='preflight':
        assert int(rpc('eth_chainId',[]),16)==196
        block=rpc('eth_blockNumber',[]); signer=owner()
        queries=[('oldPool',REG,'getPool(bytes32)',[OLD]),('underlying',REG,'getUnderlying(address)',[U]),('currencyUnderlying',REG,'getCurrencyUnderlying(address)',[W]),('quote',REG,'getQuoteToken(address)',[Q]),('registryFactory',REG,'permissionsAdapterFactory()',[]),('lpFactory',LP,'PERMISSIONS_ADAPTER_FACTORY()',[]),('routerFactory',ROUTER,'PERMISSIONS_ADAPTER_FACTORY()',[]),('factoryVerified',FACT,'verifiedPermissionsAdapterOf(address)',[W]),('adapterUnderlying',W,'PERMISSIONED_TOKEN()',[]),('adapterChecker',W,'allowListChecker()',[]),('adapterPoolManager',W,'POOL_MANAGER()',[]),('swappingEnabled',W,'swappingEnabled()',[]),('allowedRouter',W,'allowedWrappers(address)',[ROUTER]),('allowedLP',W,'allowedWrappers(address)',[LP]),('allowedHook',W,'allowedHooks(address)',[HOOK]),('tokenDecimals',U,'decimals()',[]),('tokenSymbol',U,'symbol()',[]),('quoteDecimals',Q,'decimals()',[]),('quoteSymbol',Q,'symbol()',[]),('multiplier',U,'uiMultiplier()',[]),('paused',REG,'isPaused()',[])]
        for role in ['SYMBOL_ADMIN_ROLE','POOL_CREATOR_ROLE']:
            queries.append((role,REG,'hasRole(bytes32,address)',[cast('keccak',role),signer]))
        data=batch(queries,block)
        data.update(chainId=196,block=int(block,16),signer=signer,nativeBalance=rpc('eth_getBalance',[signer,block]),oldState=state(OLD,block))
        save('preflight.json',data)
        print(json.dumps(data,indent=2))
    elif stage=='prepare':
        p=json.loads((OUT/'preflight.json').read_text())
        for name in ['registryFactory','lpFactory','routerFactory']: assert address(p[name]).lower()==FACT.lower()
        for name in ['factoryVerified','adapterUnderlying']: assert address(p[name]).lower()==U.lower()
        assert address(p['adapterChecker']).lower()==CHECKER.lower()
        assert address(p['adapterPoolManager']).lower()==PM.lower()
        for name in ['swappingEnabled','allowedRouter','allowedLP','allowedHook','SYMBOL_ADMIN_ROLE','POOL_CREATOR_ROLE']: assert int(p[name],16)==1,name
        assert int(p['paused'],16)==0
        assert words(p['underlying'])==[0,0,0,0]
        assert int(p['currencyUnderlying'],16)==0
        old=words(p['oldPool']); assert old[2:4]==[2000,60]
        sid=cast('keccak','VOLOROST2:196:'+U.lower())
        poolid=cast('keccak',cast('abi-encode','f(address,address,uint24,int24,address)',Q,W,2000,60,HOOK))
        checks=batch([('tier',REG,'getTierPolicy(uint8)',[old[6]]),('security',REG,'getSecurity(bytes32)',[sid]),('known',REG,'isKnownPool(bytes32)',[poolid]),('wrapperDecimals',W,'decimals()',[])],'latest')
        checks['tier3']=call(REG,'getTierPolicy(uint8)',3)
        save('registration-checks.json',checks)
        print('Tier capacity:',words(checks['tier']),'Tier 3:',words(checks['tier3']),flush=True)
        assert words(checks['security'])[1]==0, 'Security ID already exists'
        assert int(checks['known'],16)==0, 'Pool already exists'
        assert int(checks['wrapperDecimals'],16)==int(p['tokenDecimals'],16)==6
        assert int(p['nativeBalance'],16)>10**15, 'Insufficient native gas buffer'
        plan={'chainId':196,'signer':p['signer'],'underlying':U,'adapter':W,'checker':CHECKER,'factory':FACT,'currency0':Q,'currency1':W,'fee':2000,'tickSpacing':60,'hooks':HOOK,'sqrtPriceX96':'79228162514264337593543','poolId':poolid,'securityId':sid,'tierId':old[6],'reasonCode':cast('keccak','REGISTER_VOLOROST2_USDT_20261022'),'checks':checks}
        save('plan.json',plan); print(json.dumps(plan,indent=2))
    elif stage=='legal':
        p=loadplan()
        record,receipts=execute('legal',Target.DEPLOY_LEGAL_ADAPTER,{'TSV_LEGAL_ADAPTER_UNDERLYING':U})
        txs=record['transactions']; assert len(txs)==1 and txs[0]['transactionType']=='CREATE'
        legal=txs[0]['contractAddress']
        assert address(call(legal,'poolCurrency()')).lower()==U.lower()
        assert int(call(legal,'currentMultiplier(address)',U),16)==10**18
        p.update(legalShareAdapter=legal,legalTx=txs[0]['hash']);save('plan.json',p)
        print('Verified Legal-share Adapter:',legal,flush=True)
    elif stage=='tier':
        p=loadplan()
        assert p['tierId']==2
        before=words(call(REG,'getTierPolicy(uint8)',2))
        assert before==[2,2], ('Tier state changed; reassess before changing capacity',before)
        reason=cast('keccak','VOLOROST2_20261022_TIER2_CAPACITY3')
        record,receipts=execute('tier',Target.REGISTRY_OPERATION,{'TSV_REGISTRY_ACTION':'SET_TIER_POLICY','TSV_TIER_ID':'2','TSV_TIER_MAX_LISTED':'3','TSV_TIER_POLICY_REASON_CODE':reason})
        assert words(call(REG,'getTierPolicy(uint8)',2))==[3,2]
        p['tierTx']=record['transactions'][0]['hash'];save('plan.json',p)
        print('Verified Tier 2 capacity: 3; listed: 2',flush=True)
    elif stage=='register':
        p=loadplan()
        inputs={'TSV_STOCK_COUNT':'1','TSV_STOCK_WRAPPED_0':W,'TSV_STOCK_UNDERLYING_0':U,'TSV_STOCK_SECURITY_ID_0':p['securityId'],'TSV_STOCK_LEGAL_SHARE_ADAPTER_0':p['legalShareAdapter'],'TSV_STOCK_TIER_ID_0':str(p['tierId']),'TSV_STOCK_REASON_0':p['reasonCode']}
        record,receipts=execute('register',Target.REGISTER_STOCKS,inputs)
        assert address(call(REG,'getCurrencyUnderlying(address)',W)).lower()==U.lower()
        ur=words(call(REG,'getUnderlying(address)',U))
        assert ur==[int(p['securityId'],16),int(p['legalShareAdapter'],16),6,1]
        p['registerTx']=record['transactions'][0]['hash'];save('plan.json',p)
        print('Verified Registry registration',flush=True)
    elif stage=='initialize':
        p=loadplan()
        inputs={'TSV_POOL_COUNT':'1','TSV_POOL_CURRENCY0_0':Q,'TSV_POOL_CURRENCY1_0':W,'TSV_POOL_FEE_0':'2000','TSV_POOL_TICK_SPACING_0':'60','TSV_POOL_HOOK_0':HOOK,'TSV_POOL_SQRT_PRICE_X96_0':p['sqrtPriceX96']}
        record,receipts=execute('initialize',Target.INITIALIZE_POOLS,inputs)
        assert len(record['transactions'])==1
        p['initializeTx']=record['transactions'][0]['hash'];save('plan.json',p)
        print('Pool initialized:',p['poolId'],flush=True)
    elif stage=='verify':
        p=loadplan(); block=rpc('eth_blockNumber',[])
        data=batch([('pool',REG,'getPool(bytes32)',[p['poolId']]),('tradable',REG,'isTradable(bytes32)',[p['poolId']]),('lpAllowed',REG,'isLPAllowed(bytes32)',[p['poolId']]),('underlying',REG,'getUnderlying(address)',[U]),('currencyUnderlying',REG,'getCurrencyUnderlying(address)',[W]),('verifiedAdapter',FACT,'verifiedPermissionsAdapterOf(address)',[W]),('tier',REG,'getTierPolicy(uint8)',[2])],block)
        current=state(p['poolId'],block)
        assert current['sqrtPriceX96']==p['sqrtPriceX96'] and current['tick']==-276325 and current['lpFee']==2000
        pr=words(data['pool']); assert pr[:8]==[int(Q,16),int(W,16),2000,60,int(HOOK,16),int(p['securityId'],16),p['tierId'],1]
        assert int(data['tradable'],16)==int(data['lpAllowed'],16)==1
        assert words(data['tier'])==[3,3]
        liqslot='0x'+(int(slot(p['poolId']),16)+3).to_bytes(32,'big').hex()
        liquidity=int(call(PM,'extsload(bytes32)',liqslot,block=block),16)&((1<<128)-1)
        assert liquidity==0
        receipt=rpc('eth_getTransactionReceipt',[p['initializeTx']]); assert receipt['status']=='0x1'
        initTopic=cast('keccak','Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)')
        logs=[l for l in receipt['logs'] if l['address'].lower()==PM.lower() and l['topics'][0].lower()==initTopic.lower()]
        assert len(logs)==1 and logs[0]['topics'][1].lower()==p['poolId'].lower()
        assert words(logs[0]['data'])[:4]==[2000,60,int(HOOK,16),int(p['sqrtPriceX96'])]
        result={**p,**current,'verificationBlock':int(block,16),'transactionBlock':int(receipt['blockNumber'],16),'lifecycle':'LIST','tradable':True,'lpAllowed':True,'liquidity':str(liquidity),'tickCount':pr[8],'rawReadback':data,'initializeEvent':logs[0]}
        save('verified.json',result);print(json.dumps(result,indent=2))
