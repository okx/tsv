#!/usr/bin/env python3
"""Encode a bounded AA operation offline. Output contains signatures: never log it.

Chain state (nonce, slot0, liquidity) must be read immediately before invocation.
All deployed addresses are read from the relative deployment manifest.
"""
import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def cast(*args):
    return subprocess.check_output(['cast', *map(str, args)], cwd=ROOT, text=True, stderr=subprocess.DEVNULL).strip()
def enc(sig, *args):
    return cast('abi-encode', sig, *args)
def data(sig, *args):
    return cast('calldata', sig, *args)
def h(value):
    return cast('keccak', value)
def sqrt_tick(tick):
    source = (ROOT/'lib/v4-core/src/libraries/TickMath.sol').read_text()
    factors = [(1, int('fffcb933bd6fad37aa2d162d1a594001', 16))]
    factors += [(int(a, 16), int(b, 16)) for a,b in re.findall(r'absTick & (0x[0-9a-f]+) != 0\) price = \(price \* (0x[0-9a-f]+)\)', source)]
    price = 1 << 128
    for bit,factor in factors:
        if abs(tick) & bit:
            price = price * factor >> 128
    if tick > 0:
        price = ((1 << 256)-1)//price
    return (price+(1 << 32)-1) >> 32

p = argparse.ArgumentParser()
p.add_argument('action', choices=['add','swap','reverse','collect','remove'])
p.add_argument('--aa-nonce', type=int, required=True)
p.add_argument('--slot0')
p.add_argument('--position', type=int, default=2)
p.add_argument('--liquidity', type=int, default=0)
a = p.parse_args()
j = json.loads((ROOT/'dployment/XLAYER_MAINNET_SMOKE_20261014.json').read_text())
assets, proxies = j['assets'], j['proxies']
wallet, impl = j['aa']['wallet'], j['aa']['implementation']
q,u,w = assets['usdt0'],assets['mock8056'],assets['wrappedMock8056']
assert int(q,16) < int(w,16), 'this offline helper requires quote currency0'
key = f"({q},{w},{j['pool']['fee']},{j['pool']['tickSpacing']},{proxies['hook']})"
deadline = int(time.time()) + 3600
calls = []
details = {'action':a.action,'aaNonce':a.aa_nonce}
def approve(token, spender, amount):
    calls.extend([(token,0,data('approve(address,uint256)',spender,0)),(token,0,data('approve(address,uint256)',spender,amount))])
if a.action in ['swap','reverse']:
    forward = a.action == 'swap'
    amount, minimum = (int(j['smoke']['swapInput']),int(j['smoke']['swapMinOutput'])) if forward else (500000000000000,490)
    approve(q if forward else u,proxies['router'],amount)
    request = f"({key},{str(forward).lower()},{amount},{minimum},{deadline},1000000000000000000)"
    calls.append((proxies['router'],0,data('swapExactInput(((address,address,uint24,int24,address),bool,uint128,uint128,uint64,uint256))',request)))
    details.update(inputRaw=str(amount),minOutputRaw=str(minimum))
else:
    if a.action == 'add':
        assert a.slot0
        slot = int(a.slot0,16)
        price = slot & ((1 << 160)-1)
        tick = (slot >> 160) & ((1 << 24)-1)
        if tick >= 1 << 23: tick -= 1 << 24
        spacing = j['pool']['tickSpacing']
        lower = tick//spacing*spacing-j['pool']['rangeSpacings']*spacing
        upper = lower+2*j['pool']['rangeSpacings']*spacing
        lo,hi = sqrt_tick(lower),sqrt_tick(upper)
        assert lo < price < hi
        m0,m1 = int(j['smoke']['quoteMax']),int(j['smoke']['underlyingMax'])
        liq = min(m0*((price*hi)//(1 << 96))//(hi-price),m1*(1 << 96)//(price-lo))
        assert liq >= int(j['smoke']['minLiquidity'])
        approve(u,proxies['lpManager'],m1)
        approve(q,proxies['lpManager'],m0)
        params = [enc('f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)',key,lower,upper,liq,m0,m1,wallet,'0x'),enc('f(address,address)',q,w)]
        actions = '0x020d'
        details.update(positionId=a.position,liquidity=str(liq),tickLower=lower,tickUpper=upper)
    else:
        liq = a.liquidity if a.action == 'remove' else 0
        assert a.action != 'remove' or liq > 0
        minimum = 1 if a.action == 'remove' else 0
        params = [enc('f(uint256,uint256,uint128,uint128,bytes)',a.position,liq,minimum,minimum,'0x'),enc('f(address,address,address)',q,w,wallet)]
        actions = '0x0111'
        details.update(positionId=a.position,liquidity=str(liq))
    unlock = enc('f(bytes,bytes[])',actions,'['+','.join(params)+']')
    calls.append((proxies['lpManager'],0,data('modifyLiquidities(bytes,uint256)',unlock,deadline)))
selector = cast('sig','executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)')
calldata = selector+enc('f((address,uint256,bytes)[])','['+','.join(f'({t},{v},{d})' for t,v,d in calls)+']')[2:]
gaslimits = '0x'+((2000000 << 128)|2000000).to_bytes(32,'big').hex()
fees = '0x'+((1 << 128)|40000001).to_bytes(32,'big').hex()
inner = h(enc('f(address,uint256,bytes32,bytes32,bytes32,uint256,bytes32,bytes32)',wallet,a.aa_nonce,h('0x'),h(calldata),gaslimits,100000,fees,h('0x')))
entrypoint = '0x0000000071727de22e5e9d8baf0edac6f37da032'
rawhash = h(enc('f(bytes32,address,uint256)',inner,entrypoint,196))
binding = h(enc('f(bytes32,uint48,address)',rawhash,deadline,impl))
signer = j['deployer']
signature = cast('wallet','sign','--private-key',os.environ['PK'],binding)
signature = h(signer)+deadline.to_bytes(6,'big').hex()+signature[2:]
op = [wallet,str(a.aa_nonce),'0x',calldata,gaslimits,'100000',fees,'0x',signature]
handle = data('handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)','[('+','.join(op)+')]',signer)
print(json.dumps({'op':op,'rawHash':rawhash,'handleOpsData':handle,'details':details}))
