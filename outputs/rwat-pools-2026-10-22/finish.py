"""Reconcile receipt evidence and verify only the newly registered pools."""
import json
import os
from pathlib import Path
import subprocess
import urllib.request
from decimal import Decimal

P = Path(__file__).resolve().parent
ROOT = P.parents[1]


def cast(*args):
    return subprocess.run(['cast', *map(str, args)], text=True, capture_output=True, check=True).stdout.strip()


def reconcile(s):
    topics = {name: cast('keccak', signature) for name, signature in {
        'created': 'PermissionsAdapterCreated(address,address)',
        'verified': 'PermissionsAdapterVerified(address,address)',
        'transfer': 'Transfer(address,address,uint256)',
        'registered': 'PermissionedCurrencyRegistered(address,address,bytes32,bytes32)',
        'initialized': 'Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)',
    }.items()}
    rows = {r['underlying'].lower(): r for r in s['tokens']}
    legal = {r['legalShareAdapter'].lower(): r for r in s['tokens']}
    pools = {r['poolId'].lower(): r for r in s['tokens'] if r.get('poolId')}
    receipts = []
    for stage in ['mint', 'create', 'verify', 'tier', 'register', 'pools']:
        path = P / (stage + '.receipts.json')
        if not path.exists():
            continue
        for rc in json.loads(path.read_text()):
            assert int(rc['status'], 16) == 1
            receipts.append(rc)
            tx = rc['transactionHash']
            if stage == 'mint':
                rows[rc['to'].lower()]['mintTx'] = tx
            if stage == 'create' and rc.get('contractAddress'):
                legal[rc['contractAddress'].lower()]['createLegalTx'] = tx
            for log in rc['logs']:
                ts = log['topics']
                emitter = log['address'].lower()
                if not ts:
                    continue
                if stage == 'create' and emitter == s['factory'].lower() and ts[0] == topics['created']:
                    row = rows['0x' + ts[2][-40:]]
                    assert row['adapter'].lower() == '0x' + ts[1][-40:]
                    row['createAdapterTx'] = tx
                if stage == 'verify' and emitter == s['factory'].lower() and ts[0] == topics['verified']:
                    row = rows['0x' + ts[2][-40:]]
                    assert row['adapter'].lower() == '0x' + ts[1][-40:]
                    row['verifyTx'] = tx
                if stage == 'verify' and emitter in rows and ts[0] == topics['transfer']:
                    row = rows[emitter]
                    if '0x' + ts[2][-40:] == row['adapter'].lower():
                        assert int(log['data'], 16) == int(row['depositRaw'])
                        row['depositTx'] = tx
                if stage == 'register' and emitter == s['registry'].lower() and ts[0] == topics['registered']:
                    row = rows['0x' + ts[2][-40:]]
                    assert row['adapter'].lower() == '0x' + ts[1][-40:]
                    assert row['securityId'].lower() == ts[3].lower()
                    row['registerTx'] = tx
                if stage == 'pools' and emitter == s['poolManager'].lower() and ts[0] == topics['initialized']:
                    row = pools[ts[1].lower()]
                    assert '0x' + ts[2][-40:] == row['currency0'].lower()
                    assert '0x' + ts[3][-40:] == row['currency1'].lower()
                    data = [int(log['data'][i:i+64], 16) for i in range(2, len(log['data']), 64)]
                    assert data[:3] == [s['fee'], s['tickSpacing'], int(s['hook'], 16)]
                    assert data[3] == int(row['sqrtPriceX96'])
                    row['initializeTx'] = tx
    assert len({r['transactionHash'] for r in receipts}) == len(receipts)
    s['transactionCount'] = len(receipts)
    s['gasCostWei'] = str(sum(int(r['gasUsed'],16) * int(r['effectiveGasPrice'],16) for r in receipts))
    s['gasCostOKB'] = str(Decimal(s['gasCostWei']) / Decimal(10**18))


def verify(s):
    deployment = json.loads((ROOT / 'script/xlayer/deployment.json').read_text())
    endpoint = os.environ.get('XLAYER_RPC_URL', deployment['rpcUrl'])
    def rpc(payload):
        req = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)
    block_reply = rpc({'jsonrpc':'2.0', 'id':1, 'method':'eth_blockNumber', 'params':[]})
    block = block_reply['result']
    requests = []
    def add(to, sig, *args):
        requests.append({'jsonrpc':'2.0', 'id':len(requests), 'method':'eth_call', 'params':[{'to':to, 'data':cast('calldata', sig, *args)}, block]})
    for row in s['tokens']:
        pid = row['poolId']
        slot = int(cast('keccak', cast('abi-encode', 'f(bytes32,uint256)', pid, 6)), 16)
        add(s['registry'], 'isKnownPool(bytes32)', pid)
        add(s['registry'], 'getPoolLifeCycle(bytes32)', pid)
        add(s['registry'], 'getPoolTickCount(bytes32)', pid)
        add(s['poolManager'], 'extsload(bytes32)', '0x' + format(slot, '064x'))
        add(s['poolManager'], 'extsload(bytes32)', '0x' + format(slot + 3, '064x'))
    add(s['registry'], 'getTierPolicy(uint8)', s['tier'])
    replies = {}
    for start in range(0, len(requests), 5):
        batch = rpc(requests[start:start+5])
        assert isinstance(batch, list), batch
        for reply in batch:
            assert 'error' not in reply, reply
            replies[reply['id']] = reply['result']
    for i, row in enumerate(s['tokens']):
        known, lifecycle, count, slot0, liquidity = [int(replies[i*5+j], 16) for j in range(5)]
        price = slot0 & (2**160-1)
        assert (known, lifecycle, count, liquidity & (2**128-1)) == (1, 1, 0, 0), row['poolId']
        assert price == int(row['sqrtPriceX96']), row['poolId']
        row['verification'] = {'poolLifecycle':'LIST', 'poolLiquidity':'0', 'poolTickCount':0, 'sqrtPriceX96':str(price), 'block':block}
    tier = replies[len(requests)-1]
    assert [int(tier[i:i+64],16) for i in range(2,len(tier),64)] == [40,22]
    s['verificationStartBlock'] = s['verificationEndBlock'] = block
    s['verificationScope'] = 'Pool state at one fixed block; prior stages reuse saved verified receipts.'
    if 'final' not in s['completedStages']:
        s['completedStages'].append('final')


if __name__ == '__main__':
    state = json.loads((P / 'execution.json').read_text())
    reconcile(state)
    if 'pools' in state['completedStages']:
        verify(state)
    (P / 'execution.json').write_text(json.dumps(state, indent=2) + '\n')
    subprocess.run(['python3', str(P / 'report.py')], check=True)
    print('Receipt mappings reconciled; verified pools:', sum(bool(r.get('verification')) for r in state['tokens']), flush=True)
