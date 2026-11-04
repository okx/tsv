"""Verify liquidity receipts, exact net token inputs, pool and NFT state."""
import concurrent.futures
from decimal import Decimal
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
RPC = os.environ.get("XLAYER_RPC_URL", "https://rpc.xlayer.tech")
REGISTRY = "0x2233ea2044ffa04ccceeef0b9adfe0799505a908"
PM = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
LP = "0xf73d8683b948564d2795c62a2a909012ea168d29"
OWNER = "0x224467f6640abe0a62d1be98187912627b59722a"
Q = "0xb6ceceab302e2e4948951ee7843fc24e92933061"
U = "0x28ccb07e804c6541634c07f1809f7eaae3b523b0"
W = "0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c"
HOOK = "0xbc6d8c8a8b681872a93554116f01268f80c9ffff"
POOL_ID = "0xcaba439292b23398ddabe09f68668d3969c3d2d3eea90108b3c2ee9766d5c0a3"


def cast(*args):
    result = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def rpc(method, *params):
    return json.loads(cast("rpc", "--rpc-url", RPC, method, *[
        p if isinstance(p, str) else json.dumps(p) for p in params
    ]))


def words(data):
    raw = data.removeprefix("0x")
    assert len(raw) % 64 == 0
    return [int(raw[i:i + 64], 16) for i in range(0, len(raw), 64)]


def signed(value, bits=256):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


saved = json.loads((HERE / "liquidity-receipts.json").read_text())
hashes = [tx["hash"] for tx in saved["transactions"]]
assert hashes and all(hashes), "Not all expected transactions have hashes"
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    receipts = list(executor.map(lambda h: rpc("eth_getTransactionReceipt", h), hashes))
assert all(r and r["status"] == "0x1" for r in receipts), "A receipt is missing or failed"
assert all(r["from"].lower() == OWNER for r in receipts), "Unexpected transaction sender"
transfer_topic = cast("keccak", "Transfer(address,address,uint256)")
modify_topic = cast("keccak", "ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)")
nft_mints = []
modifications = []
net_inputs = {Q: 0, U: 0}
for receipt in receipts:
    for log in receipt["logs"]:
        address = log["address"].lower()
        topics = [t.lower() for t in log["topics"]]
        if not topics:
            continue
        if topics[0] == transfer_topic and address == LP and len(topics) == 4:
            if int(topics[1], 16) == 0 and ("0x" + topics[2][-40:]) == OWNER:
                nft_mints.append((int(topics[3], 16), receipt["transactionHash"]))
        if topics[0] == transfer_topic and address in net_inputs and len(topics) == 3:
            amount = int(log["data"], 16)
            if "0x" + topics[1][-40:] == OWNER:
                net_inputs[address] += amount
            if "0x" + topics[2][-40:] == OWNER:
                net_inputs[address] -= amount
        if address == PM and topics[0] == modify_topic and topics[1] == POOL_ID:
            assert "0x" + topics[2][-40:] == LP
            values = words(log["data"])
            modifications.append({
                "tick_lower": signed(values[0]), "tick_upper": signed(values[1]),
                "liquidity_delta": signed(values[2]), "salt": values[3],
            })
assert len(nft_mints) == 1 and len(modifications) == 1
token_id, liquidity_tx = nft_mints[0]
modification = modifications[0]
assert modification["salt"] == token_id and modification["liquidity_delta"] > 0
plan = json.loads((HERE / "plan.json").read_text())
assert 0 < net_inputs[Q] <= plan["quote_amount_max"]
assert 0 < net_inputs[U] <= plan["rwt_amount_max"]
block = rpc("eth_blockNumber")
state_slot = cast("keccak", cast("abi-encode", "f(bytes32,uint256)", POOL_ID, "6"))
liquidity_slot = "0x" + (int(state_slot, 16) + 3).to_bytes(32, "big").hex()


def call(address, signature, *args):
    return rpc("eth_call", {"to": address, "data": cast("calldata", signature, *args)}, block)


jobs = {
    "nft_owner": lambda: call(LP, "ownerOf(uint256)", str(token_id)),
    "position_liquidity": lambda: call(LP, "getPositionLiquidity(uint256)", str(token_id)),
    "pool_and_position": lambda: call(LP, "getPoolAndPositionInfo(uint256)", str(token_id)),
    "position_count": lambda: call(REGISTRY, "getPoolTickCount(bytes32)", POOL_ID),
    "active_liquidity": lambda: call(PM, "extsload(bytes32)", liquidity_slot),
    "slot0": lambda: call(PM, "extsload(bytes32)", state_slot),
    "quote_balance": lambda: call(Q, "balanceOf(address)", OWNER),
    "rwt_balance": lambda: call(U, "balanceOf(address)", OWNER),
}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    pending = {name: executor.submit(fn) for name, fn in jobs.items()}
    state = {name: future.result() for name, future in pending.items()}
assert "0x" + state["nft_owner"][-40:] == OWNER
assert int(state["position_liquidity"], 16) == modification["liquidity_delta"]
key_info = words(state["pool_and_position"])
assert key_info[:5] == [int(Q, 16), int(W, 16), 2000, 40, int(HOOK, 16)]
assert signed((key_info[5] >> 8) & 0xFFFFFF, 24) == modification["tick_lower"]
assert signed((key_info[5] >> 32) & 0xFFFFFF, 24) == modification["tick_upper"]
slot0 = int(state["slot0"], 16)
tick = signed((slot0 >> 160) & 0xFFFFFF, 24)
assert modification["tick_lower"] <= tick < modification["tick_upper"]
assert int(state["active_liquidity"], 16) >= modification["liquidity_delta"]
assert int(state["position_count"], 16) > 0
result = {
    "pool_id": POOL_ID, "owner": OWNER, "nft_token_id": token_id,
    "liquidity_transaction": liquidity_tx, "verification_block": int(block, 16),
    "actual_quote_raw": net_inputs[Q], "actual_rwt_raw": net_inputs[U],
    "actual_quote": str(Decimal(net_inputs[Q]) / Decimal(10**6)),
    "actual_rwt": str(Decimal(net_inputs[U]) / Decimal(10**18)),
    **modification,
    "current_tick": tick, "sqrt_price_x96": slot0 & ((1 << 160) - 1),
    "lp_fee": (slot0 >> 208) & 0xFFFFFF,
    **{name: int(state[name], 16) for name in (
        "position_liquidity", "position_count", "active_liquidity", "quote_balance", "rwt_balance",
    )},
    "receipts": [{
        "hash": r["transactionHash"], "status": r["status"],
        "block": int(r["blockNumber"], 16), "to": r["to"],
    } for r in receipts],
}
(HERE / "liquidity-final-verification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
