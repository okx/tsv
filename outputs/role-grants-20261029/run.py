"""Four explicit role grants using SDK simulation/broadcast and canonical RPC evidence."""
import importlib.util
import json
import sys
import time
from pathlib import Path

OUT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('ops',OUT.parent/'volorost2-usdt-20261022/run.py')
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o);o.OUT=OUT
PAIRS=[('HALT_REPORTER_ROLE','0x3936b9299821a108bda6dc31caf3ebd2ff7add3c'),
       ('HALT_REPORTER_ROLE','0x94b9097cca1a368f7bd6aba0e38a6333bfd42936'),
       ('FORCE_EXIT_ADMIN_ROLE','0x466ef4a1008772af2d0fa52cd2fc8b5391863a76'),
       ('FORCE_EXIT_ADMIN_ROLE','0x323ef02b3ce1a90d631f461a1eeec23cd639651f')]
def saved(name):return json.loads((OUT/name).read_text())
def preflight():
    assert int(o.rpc('eth_chainId',[]),16)==196
    assert o.REG.lower()=='0x2233ea2044ffa04ccceeef0b9adfe0799505a908'
    actor=o.owner();block=o.rpc('eth_blockNumber',[]);rows=[]
    assert o.rpc('eth_getCode',[o.REG,block])!='0x'
    for name,account in PAIRS:
        role=o.cast('keccak',name);admin=o.call(o.REG,'getRoleAdmin(bytes32)',role,block=block)
        assert int(o.call(o.REG,'hasRole(bytes32,address)',admin,actor,block=block),16)==1
        rows.append({'role':name,'roleHash':role,'account':account,
                     'before':bool(int(o.call(o.REG,'hasRole(bytes32,address)',role,account,block=block),16))})
    nonce=int(o.rpc('eth_getTransactionCount',[actor,'pending']),16)
    assert nonce==int(o.rpc('eth_getTransactionCount',[actor,'latest']),16),'pending transactions'
    balance=int(o.rpc('eth_getBalance',[actor,block]),16);assert balance>10**14
    result={'chainId':196,'registry':o.REG,'operator':actor,'block':int(block,16),'startNonce':nonce,'nativeBalance':str(balance),'grants':rows}
    o.save('preflight.json',result);print(json.dumps(result,indent=2),flush=True)
def verify():
    pre=saved('preflight.json')
    artifact=json.loads((o.ROOT/'broadcast/GrantRequestedRoles20261029.s.sol/196/run-latest.json').read_text())
    hashes=[t['hash'] for t in artifact['transactions']]
    expected={(x['roleHash'].lower(),x['account'].lower()) for x in pre['grants'] if not x['before']}
    assert len(hashes)==len(set(hashes))==len(expected)
    rows=[];receipts=[];seen=set();topic=o.cast('keccak','RoleGranted(bytes32,address,address)')
    for h in hashes:
        receipt=None
        for attempt in range(6):
            receipt=o.rpc('eth_getTransactionReceipt',[h])
            if receipt:break
            time.sleep(2)
        assert receipt and receipt['status']=='0x1','Missing/failed receipt; do not repeat broadcast'
        tx=o.rpc('eth_getTransactionByHash',[h]);assert tx['from'].lower()==pre['operator'].lower() and tx['to'].lower()==o.REG.lower()
        assert int(tx['value'],16)==0 and tx['input'][:10]==o.cast('sig','grantRole(bytes32,address)')
        role,account=json.loads(o.cast('decode-calldata','--json','grantRole(bytes32,address)',tx['input']))
        pair=(role.lower(),account.lower());assert pair in expected and pair not in seen;seen.add(pair)
        logs=[l for l in receipt['logs'] if l['address'].lower()==o.REG.lower() and l['topics'][0]==topic]
        assert len(logs)==1 and logs[0]['topics'][1].lower()==role.lower()
        assert o.address(logs[0]['topics'][2]).lower()==account.lower()
        assert o.address(logs[0]['topics'][3]).lower()==pre['operator'].lower()
        name=next(x['role'] for x in pre['grants'] if x['roleHash'].lower()==role.lower())
        rows.append({'role':name,'roleHash':role,'account':account,'txHash':h,'nonce':int(tx['nonce'],16),'block':int(receipt['blockNumber'],16),'gasUsed':int(receipt['gasUsed'],16),'status':'success'})
        receipts.append(receipt)
    assert seen==expected
    rows.sort(key=lambda x:x['nonce'])
    assert [x['nonce'] for x in rows]==list(range(pre['startNonce'],pre['startNonce']+len(rows)))
    block=o.rpc('eth_blockNumber',[])
    assert all(int(o.call(o.REG,'hasRole(bytes32,address)',x['roleHash'],x['account'],block=block),16)==1 for x in pre['grants'])
    o.save('verified-transactions.json',rows);o.save('verified-receipts.json',receipts)
    o.save('final.json',{'verificationBlock':int(block,16),'allFourRolesGranted':True,'grants':[{**x,'after':True} for x in pre['grants']]})
    o.save('grant.journal.json',{'status':'verified','hashes':hashes})
    lines=['# X Layer 角色授权记录（2026-10-29）','',f'Registry：`{o.REG}`',f'操作账户：`{pre["operator"]}`','',
      '各写操作先模拟后广播；交易参数由链上 calldata 解码，已验证成功回执、RoleGranted 事件及 hasRole。','',
      '| 角色 | 地址 | 交易 | 区块 | 结果 |','| --- | --- | --- | --- | --- |']
    for row in rows:lines.append(f'| {row["role"]} | `{row["account"]}` | [{row["txHash"]}](https://www.oklink.com/xlayer/tx/{row["txHash"]}) | {row["block"]} | hasRole=true |')
    for row in pre['grants']:
        if row['before']:lines.append(f'| {row["role"]} | `{row["account"]}` | 已持有，无需重复授权 | — | hasRole=true |')
    lines+=['',f'最终核验区块：{int(block,16)}。四组角色/地址均为 true。','',
            'Lark 日志此前返回 forBidden，本次不自动重试；交易证据保留于本目录。','']
    (OUT/'TRANSACTIONS.md').write_text('\n'.join(lines));print(json.dumps(rows,indent=2),flush=True)
if __name__=='__main__':
    action=sys.argv[1]
    if action=='preflight':preflight()
    elif action=='execute':
        pre=saved('preflight.json');assert pre['operator'].lower()==o.owner().lower()
        assert int(o.rpc('eth_getTransactionCount',[pre['operator'],'pending']),16)==pre['startNonce']
        assert any(not x['before'] for x in pre['grants']),'All roles already held'
        o.execute('grant',o.Target.GRANT_REQUESTED_ROLES,{'TSV_EXPECTED_ROLE_OPERATOR':pre['operator']})
        verify()
    elif action=='verify':verify()
    else:raise SystemExit('Unknown action')
