"""Read-only receipt and state verification using public X Layer RPC."""
import concurrent.futures
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
RPC = "https://xlayerrpc.okx.com"
REGISTRY = "0x2233ea2044ffa04ccceeef0b9adfe0799505a908"
POOL_MANAGER = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
W = "0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c"
U = "0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0"
Q = "0xb6ceceab302e2e4948951ee7843fc24e92933061"
OWNER = "0x224467f6640AbE0A62D1be98187912627b59722A"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def rpc(method, params):
    encoded = [value if isinstance(value, str) else json.dumps(value) for value in params]
    output = subprocess.check_output(
        ["cast", "rpc", "--rpc-url", RPC, method, *encoded], text=True, timeout=45,
    )
    return json.loads(output)


block = rpc("eth_blockNumber", [])


def call(address, signature, *args):
    return rpc("eth_call", [{"to": address, "data": cast("calldata", signature, *args)}, block])


pool_id = cast("keccak", cast(
    "abi-encode", "f(address,address,uint24,int24,address)", Q, W, "2000", "40",
    "0xbc6d8c8a8b681872a93554116f01268f80c9ffff",
))
state_slot = cast("keccak", cast("abi-encode", "f(bytes32,uint256)", pool_id, "6"))
liquidity_slot = "0x" + (int(state_slot, 16) + 3).to_bytes(32, "big").hex()
jobs = {
    "underlying": lambda: call(REGISTRY, "getCurrencyUnderlying(address)", W),
    "known_pool": lambda: call(REGISTRY, "isKnownPool(bytes32)", pool_id),
    "tradable": lambda: call(REGISTRY, "isTradable(bytes32)", pool_id),
    "position_count": lambda: call(REGISTRY, "getPoolTickCount(bytes32)", pool_id),
    "lp_sbt_allowed": lambda: call(REGISTRY, "isSbtAllowed(bytes2,address)", "0x0002", OWNER),
    "rwt_balance": lambda: call(U, "balanceOf(address)", OWNER),
    "quote_balance": lambda: call(Q, "balanceOf(address)", OWNER),
    "slot0": lambda: call(POOL_MANAGER, "extsload(bytes32)", state_slot),
    "active_liquidity": lambda: call(POOL_MANAGER, "extsload(bytes32)", liquidity_slot),
}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    pending = {name: executor.submit(fn) for name, fn in jobs.items()}
    state = {name: result.result() for name, result in pending.items()}
receipts = []
for path in sorted(HERE.glob("*-receipts.json")):
    saved = json.loads(path.read_text())
    for receipt in saved["receipts"]:
        live = rpc("eth_getTransactionReceipt", [receipt["transactionHash"]])
        if live is None:
            raise RuntimeError(f"Receipt missing: {receipt['transactionHash']}")
        receipts.append({
            "action": saved["action"], "hash": live["transactionHash"],
            "status": live["status"], "block": int(live["blockNumber"], 16),
        })
        if live["status"] != "0x1":
            raise RuntimeError(f"Transaction failed: {live['transactionHash']}")
slot0 = int(state["slot0"], 16)
tick_unsigned = (slot0 >> 160) & ((1 << 24) - 1)
result = {
    "chain_id": int(rpc("eth_chainId", []), 16),
    "block": int(block, 16),
    "pool_id": pool_id,
    "owner": OWNER,
    "underlying": "0x" + state["underlying"][-40:],
    **{name: int(state[name], 16) for name in (
        "known_pool", "tradable", "position_count", "lp_sbt_allowed",
        "rwt_balance", "quote_balance", "active_liquidity",
    )},
    "sqrt_price_x96": slot0 & ((1 << 160) - 1),
    "tick": tick_unsigned - (1 << 24) if tick_unsigned & (1 << 23) else tick_unsigned,
    "receipts": receipts,
}
(HERE / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
