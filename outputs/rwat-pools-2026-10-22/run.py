from pathlib import Path
import sys, os, json, subprocess, urllib.request, math, shutil, time, tomllib
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'sdk/python'))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target
client=ExecutionClient(root=ROOT)
probe=Operation(Target.INSPECT_ASSETS,'Load operator configuration',{})
env=client._environment(probe)
RPC=env['XLAYER_RPC_URL']
REG=env['TSV_REGISTRY']; FACT='0x92cdb229613da8ca45e375cf69df4b3b645ff48d'
LP=env['TSV_LP_MANAGER']; PM=env['TSV_POOL_MANAGER']; HOOK=env['TSV_HOOK']; CHECKER=env['TSV_ALLOWLIST_CHECKER']; Q=env['TSV_EXISTING_POOL_CURRENCY0']
# Only the SDK loads credentials. The shell expands the key without printing it.
a=subprocess.run(['bash','-c','cast wallet address --private-key "$XLAYER_PRIVATE_KEY"'],env=env,capture_output=True,text=True)
if a.returncode: raise RuntimeError('Unable to derive operation wallet')
OWNER=a.stdout.strip()
def cast(*args):
 p=subprocess.run(['cast',*map(str,args)],capture_output=True,text=True)
 if p.returncode: raise RuntimeError(p.stderr)
 return p.stdout.strip()
def rpc(method,params):
 req=urllib.request.Request(RPC,data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=30) as r: data=json.load(r)
 if 'error' in data: raise RuntimeError(str(data['error']))
 return data['result']
def call(to,sig,*args):return rpc('eth_call',[{'to':to,'data':cast('calldata',sig,*args)},'latest'])
def words(h):return [int(h[i:i+64],16) for i in range(2,len(h),64)]
def addr(h):return '0x'+h[-40:]
def save(name,data):OUT.joinpath(name).write_text(json.dumps(data,indent=2)+'\n')
def getstate():
 s=json.loads(OUT.joinpath('execution.json').read_text())
 assert s['owner'].lower()==OWNER.lower(),'operation wallet changed'
 assert s['registry'].lower()==REG.lower(),'registry changed'
 return s
TOKENS=json.loads(OUT.joinpath('inventory.json').read_text())['proxies']
BASE={'FOUNDRY_SRC':str(OUT/'empty'),'FOUNDRY_TEST':str(OUT/'empty'),'FOUNDRY_SCRIPT':str(OUT/'empty')}
# Explicit Permit2 mapping is needed when the temporary source directory is empty.
BASE['FOUNDRY_REMAPPINGS']='\n'.join(tomllib.loads((ROOT/'foundry.toml').read_text())['profile']['default']['remappings']+['permit2/=lib/v4-periphery/lib/permit2/'])
def execute(label,target,inputs):
 op=Operation(target,label,{**BASE,**inputs})
 print('SIMULATING',label,flush=True)
 sim=client.simulate(op)
 OUT.joinpath(label+'.simulation.log').write_text(sim.result.stdout+'\n'+sim.result.stderr)
 if not sim.result.succeeded: raise RuntimeError('Simulation failed: '+label+'; see sanitized simulation log')
 print('SIMULATION PASSED; BROADCASTING',label,flush=True)
 journal=OUT/(label+'.journal.json')
 if journal.exists():raise RuntimeError('Existing broadcast journal; reconcile before retry: '+label)
 save(label+'.journal.json',{'status':'broadcasting','startedAt':int(time.time()),'target':target.name,'inputs':inputs})
 result=client.broadcast(sim,'BROADCAST')
 OUT.joinpath(label+'.broadcast.log').write_text(result.stdout+'\n'+result.stderr)
 if not result.succeeded: raise RuntimeError('Broadcast did not finish successfully: '+label+'; inspect receipts before any retry')
 script=target.script.split(':')[0]
 record=json.loads((ROOT/'broadcast'/script/'196/run-latest.json').read_text())
 save(label+'.broadcast.json',record)
 hashes=[t['hash'] for t in record['transactions']]
 receipts=[]
 for h in hashes:
  receipt=rpc('eth_getTransactionReceipt',[h])
  if not receipt or int(receipt['status'],16)!=1:raise RuntimeError('Missing or failed receipt '+h)
  receipts.append(receipt)
 save(label+'.receipts.json',receipts)
 save(label+'.journal.json',{'status':'verified','hashes':hashes})
 print('VERIFIED',label,len(receipts),'successful receipts',flush=True)
 return record,receipts
stage=sys.argv[1]
if stage=='preflight':
 assert int(rpc('eth_chainId',[]),16)==196
 assert addr(call(REG,'permissionsAdapterFactory()')).lower()==FACT.lower()
 assert addr(call(LP,'PERMISSIONS_ADAPTER_FACTORY()')).lower()==FACT.lower()
 assert words(call(REG,'isPaused()'))==[0]
 assert words(call(REG,'getQuoteToken(address)',Q))[1]==1
 assert int(call(REG,'hasRole(bytes32,address)',cast('keccak','SYMBOL_ADMIN_ROLE'),OWNER),16)==1
 assert int(call(REG,'hasRole(bytes32,address)',cast('keccak','POOL_CREATOR_ROLE'),OWNER),16)==1
 qdec=int(call(Q,'decimals()'),16)
 tier=words(call(REG,'getTierPolicy(uint8)',3))
 assert tier[1]==0 and tier[0] in (0,40),tier
 rows=[]
 for i,u in enumerate(TOKENS):
  dec=int(call(u,'decimals()'),16); bal=int(call(u,'balanceOf(address)',OWNER),16)
  assert dec==18,('unexpected decimals',u,dec)
  assert words(call(REG,'getUnderlying(address)',u))==[0,0,0,0]
  sid=cast('keccak','RWAT:196:'+u.lower())
  rows.append({'index':i+1,'underlying':u,'securityId':sid,'depositRaw':str(10**17),'balanceBefore':str(bal)})
 state={'chainId':196,'owner':OWNER,'registry':REG,'factory':FACT,'lpManager':LP,'poolManager':PM,'hook':HOOK,'checker':CHECKER,'quote':Q,'quoteDecimals':qdec,'fee':2000,'tickSpacing':60,'initialPriceQuotePerUnderlying':'1','tier':3,'tierCapacity':40,'nativeBalanceBefore':rpc('eth_getBalance',[OWNER,'latest']),'tokens':rows,'completedStages':[]}
 state['preflightPassed']=all(int(r['balanceBefore'])>=10**17 for r in rows)
 save('execution.json',state)
 print(json.dumps({k:v for k,v in state.items() if k!='tokens'},indent=2));print('All 22 token balances and registrations checked.')
 print('Insufficient balance:',json.dumps([r['underlying'] for r in rows if int(r['balanceBefore'])<10**17]))
elif stage=='mint':
 s=getstate();assert 'mint' not in s['completedStages']
 inputs={'TSV_MINT_COUNT':str(len(s['tokens']))}
 for i,r in enumerate(s['tokens']):inputs.update({f'TSV_MINT_TOKEN_{i}':r['underlying'],f'TSV_MINT_TARGET_{i}':r['depositRaw']})
 rec,_=execute('mint',Target.MINT_VERIFICATION_TOKENS,inputs)
 txs={t['contractAddress'].lower():t['hash'] for t in rec['transactions']}
 for r in s['tokens']:
  assert int(call(r['underlying'],'balanceOf(address)',OWNER),16)>=int(r['depositRaw'])
  r['mintTx']=txs.get(r['underlying'].lower())
 s['preflightPassed']=True;s['completedStages'].append('mint');save('execution.json',s)
elif stage=='create':
 s=getstate();assert s['preflightPassed'];assert 'create' not in s['completedStages']
 inputs={'TSV_CREATE_STOCK_COUNT':str(len(TOKENS))}
 for i,u in enumerate(TOKENS):
  inputs.update({f'TSV_CREATE_STOCK_UNDERLYING_{i}':u,f'TSV_CREATE_STOCK_OWNER_{i}':OWNER,f'TSV_CREATE_STOCK_ALLOWLIST_{i}':CHECKER})
 rec,receipts=execute('create',Target.CREATE_STOCK_ADAPTERS,inputs)
 created=[t for t in rec['transactions'] if t.get('transactionType')=='CREATE']
 topic=cast('keccak','PermissionsAdapterCreated(address,address)')
 ws={};txs={}
 for r in receipts:
  for l in r['logs']:
   if l['address'].lower()==FACT.lower() and l['topics'][0].lower()==topic.lower():
    u=addr(l['topics'][2]);ws[u.lower()]=addr(l['topics'][1]);txs[u.lower()]=r['transactionHash']
 legal={}
 for t in created:
  address=t['contractAddress'];u=addr(call(address,'poolCurrency()'));legal[u.lower()]=(address,t['hash'])
 assert len(ws)==len(legal)==22,(len(ws),len(legal))
 for row in s['tokens']:
  u=row['underlying'].lower();row.update(adapter=ws[u],legalShareAdapter=legal[u][0],createAdapterTx=txs[u],createLegalTx=legal[u][1])
 s['completedStages'].append('create');save('execution.json',s)
elif stage=='tier':
 s=getstate();assert 'tier' not in s['completedStages']
 rec,_=execute('tier',Target.REGISTRY_OPERATION,{'TSV_REGISTRY_ACTION':'SET_TIER_POLICY','TSV_TIER_ID':'3','TSV_TIER_MAX_LISTED':'40','TSV_TIER_POLICY_REASON_CODE':cast('keccak','RWAT_BATCH_20261022_TIER_3_CAPACITY_40')})
 assert words(call(REG,'getTierPolicy(uint8)',3))==[40,0]
 s['tierTx']=rec['transactions'][0]['hash'];s['completedStages'].append('tier');save('execution.json',s)
elif stage=='verify':
 s=getstate();assert 'create' in s['completedStages'] and 'verify' not in s['completedStages']
 inputs={'TSV_VERIFY_STOCK_COUNT':'22'}
 for i,r in enumerate(s['tokens']):inputs.update({f'TSV_VERIFY_STOCK_WRAPPED_{i}':r['adapter'],f'TSV_VERIFY_STOCK_UNDERLYING_{i}':r['underlying'],f'TSV_VERIFY_STOCK_AMOUNT_{i}':r['depositRaw']})
 rec,_=execute('verify',Target.VERIFY_STOCK_ADAPTERS,inputs)
 assert len(rec['transactions'])==44
 for i,r in enumerate(s['tokens']):
  assert addr(call(FACT,'verifiedPermissionsAdapterOf(address)',r['adapter'])).lower()==r['underlying'].lower()
  assert int(call(r['underlying'],'balanceOf(address)',r['adapter']),16)==10**17
  r['depositTx']=rec['transactions'][i*2]['hash'];r['verifyTx']=rec['transactions'][i*2+1]['hash']
 s['completedStages'].append('verify');save('execution.json',s)
elif stage=='register':
 s=getstate();assert {'verify','tier'}<=set(s['completedStages']) and 'register' not in s['completedStages']
 inputs={'TSV_STOCK_COUNT':'22'}
 for i,r in enumerate(s['tokens']):
  vals={'WRAPPED':r['adapter'],'UNDERLYING':r['underlying'],'SECURITY_ID':r['securityId'],'LEGAL_SHARE_ADAPTER':r['legalShareAdapter'],'TIER_ID':'3','REASON':cast('keccak','RWAT_REGISTER_20261022:'+r['underlying'].lower())}
  inputs.update({f'TSV_STOCK_{k}_{i}':v for k,v in vals.items()})
 rec,_=execute('register',Target.REGISTER_STOCKS,inputs)
 for i,r in enumerate(s['tokens']):
  assert addr(call(REG,'getCurrencyUnderlying(address)',r['adapter'])).lower()==r['underlying'].lower()
  r['registerTx']=rec['transactions'][i]['hash']
 assert words(call(REG,'getTierPolicy(uint8)',3))==[40,22]
 s['completedStages'].append('register');save('execution.json',s)
elif stage=='pools':
 s=getstate();assert 'register' in s['completedStages'] and 'pools' not in s['completedStages']
 inputs={'TSV_POOL_COUNT':'22'}
 for i,r in enumerate(s['tokens']):
  w=r['adapter']; c0,c1=sorted([w,Q],key=lambda a:int(a,16))
  d0,d1=(18,s['quoteDecimals']) if c0==w else (s['quoteDecimals'],18)
  price=math.isqrt((2**192*10**d1)//10**d0)
  key=f'({c0},{c1},2000,60,{HOOK})'
  encoded=cast('abi-encode','f((address,address,uint24,int24,address))',key)
  r.update(currency0=c0,currency1=c1,sqrtPriceX96=str(price),poolId=cast('keccak',encoded))
  vals={'CURRENCY0':c0,'CURRENCY1':c1,'FEE':'2000','TICK_SPACING':'60','HOOK':HOOK,'SQRT_PRICE_X96':str(price)}
  inputs.update({f'TSV_POOL_{k}_{i}':v for k,v in vals.items()})
 save('execution.json',s)
 rec,_=execute('pools',Target.INITIALIZE_POOLS,inputs)
 for i,r in enumerate(s['tokens']):r['initializeTx']=rec['transactions'][i]['hash']
 s['completedStages'].append('pools');save('execution.json',s)
elif stage=='final':
 from decimal import Decimal
 s=getstate();assert 'pools' in s['completedStages']
 s['verificationStartBlock']=rpc('eth_blockNumber',[])
 for r in s['tokens']:
  w,u,pid=r['adapter'],r['underlying'],r['poolId']
  assert addr(call(w,'owner()')).lower()==OWNER.lower()
  assert addr(call(w,'PERMISSIONED_TOKEN()')).lower()==u.lower()
  assert addr(call(w,'allowListChecker()')).lower()==CHECKER.lower()
  assert addr(call(FACT,'verifiedPermissionsAdapterOf(address)',w)).lower()==u.lower()
  assert int(call(u,'balanceOf(address)',w),16)==10**17
  assert int(call(w,'totalSupply()'),16)==0
  flags={'swappingEnabled':int(call(w,'swappingEnabled()'),16),'allowedLPManager':int(call(w,'allowedWrappers(address)',LP),16),'allowedRouter':int(call(w,'allowedWrappers(address)',env['TSV_ROUTER']),16),'allowedHook':int(call(w,'allowedHooks(address)',HOOK),16)}
  assert not any(flags.values()),flags
  assert int(call(REG,'isKnownPool(bytes32)',pid),16)==1
  assert int(call(REG,'getPoolLifeCycle(bytes32)',pid),16)==1
  assert int(call(REG,'getPoolTickCount(bytes32)',pid),16)==0
  slot=int(cast('keccak',cast('abi-encode','f(bytes32,uint256)',pid,6)),16)
  slot0=int(call(PM,'extsload(bytes32)','0x'+format(slot,'064x')),16)
  liquidity=int(call(PM,'extsload(bytes32)','0x'+format(slot+3,'064x')),16)&(2**128-1)
  price=slot0&(2**160-1)
  assert price==int(r['sqrtPriceX96']) and liquidity==0,(pid,price,liquidity)
  r['verification']={'adapterUnderlyingBalance':str(10**17),'adapterSupply':'0','poolLiquidity':'0','poolTickCount':0,'poolLifecycle':'LIST','sqrtPriceX96':str(price),**flags}
  print('VERIFIED POOL',r['index'],pid,flush=True)
  save('execution.json',s)
 assert words(call(REG,'getTierPolicy(uint8)',3))==[40,22]
 s['verificationEndBlock']=rpc('eth_blockNumber',[])
 receipts=[]
 for label in ['mint','create','tier','verify','register','pools']:
  receipts.extend(json.loads(OUT.joinpath(label+'.receipts.json').read_text()))
 assert len({r['transactionHash'] for r in receipts})==len(receipts)
 s['transactionCount']=len(receipts)
 s['gasCostWei']=str(sum(int(r['gasUsed'],16)*int(r['effectiveGasPrice'],16) for r in receipts))
 s['gasCostOKB']=str(Decimal(s['gasCostWei'])/Decimal(10**18))
 s['completedStages'].append('final');save('execution.json',s)
 print('ALL POOLS VERIFIED',len(s['tokens']),'transactions',len(receipts),'gas OKB',s['gasCostOKB'],flush=True)
elif stage=='diagnostic':
 rows=[]
 print('Operation wallet:',OWNER,flush=True)
 for u in TOKENS:
  row={'underlying':u}
  for key,sig,args in [('balance','balanceOf(address)',[OWNER]),('trust','getDSService(uint256)',[1]),('compliance','getDSService(uint256)',[8]),('rebasing','getDSService(uint256)',[8196])]:
   try:
    v=call(u,sig,*args);row[key]=str(int(v,16)) if key=='balance' else addr(v)
   except RuntimeError as e:row[key]={'error':str(e)}
  if isinstance(row['balance'],str):
   balance=int(row['balance'])
   try:
    if balance < 10**17:
     data=cast('calldata','issueTokens(address,uint256)',OWNER,10**17-balance)
     row['mintSimulation']=rpc('eth_call',[{'from':OWNER,'to':u,'data':data},'latest'])
    else:row['mintSimulation']='not needed'
   except RuntimeError as e:row['mintSimulation']={'error':str(e)}
  rows.append(row); print(json.dumps(row),flush=True)
  save('diagnostic.json',{'owner':OWNER,'tokens':rows})
elif stage=='remaining':
 for next_stage in ['register','pools','final']:
  subprocess.run([sys.executable,str(Path(__file__).resolve()),next_stage],check=True,cwd=ROOT)
  subprocess.run([sys.executable,str(OUT/'report.py')],check=True,cwd=ROOT)
else:raise ValueError(stage)
