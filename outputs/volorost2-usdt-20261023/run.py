"""Create the explicitly requested 1:1 VOLOROST2/USDT0 pool."""
import importlib.util
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('previous_pool_ops', OUT.parent / 'volorost2-usdt-20261022/run.py')
ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ops)
ops.OUT = OUT
OLD = '0xbdf2fc001650f849065e99e1acbe47d07f62d4e5f5cc48335871282c2449f273'
FEE, SPACING, PRICE = 2000, 40, 1 << 96
POOL = ops.cast('keccak', ops.cast('abi-encode', 'f(address,address,uint24,int24,address)', ops.Q, ops.W, FEE, SPACING, ops.HOOK))
def inspect():
    assert int(ops.rpc('eth_chainId', []), 16) == 196
    block = ops.rpc('eth_blockNumber', [])
    signer = ops.owner()
    q = [
        ('oldPool', ops.REG, 'getPool(bytes32)', [OLD]),
        ('newPoolKnown', ops.REG, 'isKnownPool(bytes32)', [POOL]),
        ('underlying', ops.REG, 'getUnderlying(address)', [ops.U]),
        ('currencyUnderlying', ops.REG, 'getCurrencyUnderlying(address)', [ops.W]),
        ('quote', ops.REG, 'getQuoteToken(address)', [ops.Q]),
        ('registryFactory', ops.REG, 'permissionsAdapterFactory()', []),
        ('lpFactory', ops.LP, 'PERMISSIONS_ADAPTER_FACTORY()', []),
        ('verifiedAdapter', ops.FACT, 'verifiedPermissionsAdapterOf(address)', [ops.W]),
        ('adapterUnderlying', ops.W, 'PERMISSIONED_TOKEN()', []),
        ('checker', ops.W, 'allowListChecker()', []),
        ('allowedRouter', ops.W, 'allowedWrappers(address)', [ops.ROUTER]),
        ('allowedLP', ops.W, 'allowedWrappers(address)', [ops.LP]),
        ('allowedHook', ops.W, 'allowedHooks(address)', [ops.HOOK]),
        ('swappingEnabled', ops.W, 'swappingEnabled()', []),
        ('quoteDecimals', ops.Q, 'decimals()', []),
        ('wrapperDecimals', ops.W, 'decimals()', []),
        ('underlyingDecimals', ops.U, 'decimals()', []),
        ('creatorRole', ops.REG, 'hasRole(bytes32,address)', [ops.cast('keccak', 'POOL_CREATOR_ROLE'), signer]),
        ('registryPaused', ops.REG, 'isPaused()', []),
        ('tier', ops.REG, 'getTierPolicy(uint8)', [2]),
    ]
    data = ops.batch(q, block)
    assert all(isinstance(v, str) for v in data.values()), data
    for key in ['quoteDecimals', 'wrapperDecimals', 'underlyingDecimals']:
        assert int(data[key], 16) == 6, key
    for key in ['creatorRole', 'allowedRouter', 'allowedLP', 'allowedHook', 'swappingEnabled']:
        assert int(data[key], 16) == 1, key
    assert int(data['registryPaused'], 16) == 0
    for key in ['registryFactory', 'lpFactory']:
        assert ops.address(data[key]).lower() == ops.FACT.lower()
    for key in ['currencyUnderlying', 'verifiedAdapter', 'adapterUnderlying']:
        assert ops.address(data[key]).lower() == ops.U.lower()
    assert ops.address(data['checker']).lower() == ops.CHECKER.lower()
    assert ops.words(data['quote']) == [6, 1]
    underlying = ops.words(data['underlying'])
    assert underlying[2:] == [6, 1]
    old = ops.words(data['oldPool'])
    assert old[:5] == [int(ops.Q,16),int(ops.W,16),2000,60,int(ops.HOOK,16)]
    assert underlying[0] == old[5]
    security_id = '0x' + underlying[0].to_bytes(32, 'big').hex()
    security = ops.words(ops.call(ops.REG, 'getSecurity(bytes32)', security_id, block=block))
    assert security[1:4] == [underlying[0], 2, 1]
    balance = int(ops.rpc('eth_getBalance', [signer, block]), 16)
    assert balance > 10**15, 'Insufficient native gas buffer'
    new_state = ops.state(POOL, block)
    result = {'chainId':196,'block':int(block,16),'signer':signer,'poolid':POOL,'oldPoolid':OLD,
              'currency0':ops.Q,'currency1':ops.W,'fee':FEE,'tickSpacing':SPACING,'hooks':ops.HOOK,
              'sqrtPriceX96':str(PRICE),'tick':0,'securityId':security_id,'tierId':2,
              'nativeBalance':str(balance),'newPoolState':new_state,'oldPoolState':ops.state(OLD,block),
              'raw':data}
    ops.save('preflight.json', result)
    return result

stage = sys.argv[1]
if stage == 'inspect':
    data = inspect()
    print(json.dumps({k:v for k,v in data.items() if k!='raw'},indent=2))
elif stage == 'initialize':
    data = inspect()
    assert int(data['raw']['newPoolKnown'], 16) == 0, 'New PoolKey is already registered'
    assert int(data['newPoolState']['sqrtPriceX96']) == 0, 'New pool is already initialized'
    inputs = {'TSV_POOL_COUNT':'1','TSV_POOL_CURRENCY0_0':ops.Q,'TSV_POOL_CURRENCY1_0':ops.W,
              'TSV_POOL_FEE_0':str(FEE),'TSV_POOL_TICK_SPACING_0':str(SPACING),
              'TSV_POOL_HOOK_0':ops.HOOK,'TSV_POOL_SQRT_PRICE_X96_0':str(PRICE)}
    record, receipts = ops.execute('initialize', ops.Target.INITIALIZE_POOLS, inputs)
    assert len(receipts)==1
    ops.save('execution.json', {**data, 'txhash':receipts[0]['transactionHash']})
    print('INITIALIZED', POOL, receipts[0]['transactionHash'])
elif stage == 'verify':
    data = json.loads((OUT/'execution.json').read_text())
    receipt = ops.rpc('eth_getTransactionReceipt', [data['txhash']])
    assert receipt and receipt['status']=='0x1'
    assert receipt['from'].lower()==data['signer'].lower() and receipt['to'].lower()==ops.LP.lower()
    topic = ops.cast('keccak','Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)')
    logs = [l for l in receipt['logs'] if l['address'].lower()==ops.PM.lower() and l['topics'][0].lower()==topic.lower()]
    assert len(logs)==1
    log=logs[0]
    assert log['topics'][1].lower()==POOL.lower()
    assert ops.address(log['topics'][2]).lower()==ops.Q.lower() and ops.address(log['topics'][3]).lower()==ops.W.lower()
    assert ops.words(log['data'])==[FEE,SPACING,int(ops.HOOK,16),PRICE,0]
    block=ops.rpc('eth_blockNumber',[])
    raw=ops.batch([('pool',ops.REG,'getPool(bytes32)',[POOL]),('tradable',ops.REG,'isTradable(bytes32)',[POOL]),
                   ('lpAllowed',ops.REG,'isLPAllowed(bytes32)',[POOL]),('tier',ops.REG,'getTierPolicy(uint8)',[2]),
                   ('oldPool',ops.REG,'getPool(bytes32)',[OLD])],block)
    pool=ops.words(raw['pool'])
    assert pool[:8]==[int(ops.Q,16),int(ops.W,16),FEE,SPACING,int(ops.HOOK,16),int(data['securityId'],16),2,1]
    current=ops.state(POOL,block)
    assert current['sqrtPriceX96']==str(PRICE) and current['tick']==0 and current['lpFee']==FEE
    assert int(raw['tradable'],16)==int(raw['lpAllowed'],16)==1
    assert raw['tier']==data['raw']['tier']
    liqslot='0x'+(int(ops.slot(POOL),16)+3).to_bytes(32,'big').hex()
    liquidity=int(ops.call(ops.PM,'extsload(bytes32)',liqslot,block=block),16)&((1<<128)-1)
    result={k:data[k] for k in ['chainId','poolid','currency0','currency1','fee','tickSpacing','hooks','sqrtPriceX96','tick','securityId','tierId','txhash']}
    result.update(lifecycle='LIST',liquidity=str(liquidity),isTradable=True,isLPAllowed=True,
                  transactionBlock=int(receipt['blockNumber'],16),verificationBlock=int(block,16))
    ops.save('pool.json',result)
    ops.save('verification.json',{'pool':result,'rawReadback':raw,'state':current,'initializeEvent':log,'receipt':receipt})
    print(json.dumps(result,indent=2))
else:
    raise SystemExit('Use inspect, initialize, or verify')
