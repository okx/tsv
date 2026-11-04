"""Verify only the requested SBT issuance; never sends transactions."""
import concurrent.futures
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
RPC = "https://xlayerrpc.okx.com"
SBT = "0x053ecef8ccb8844322bee86290dae016b9843b6d"
REGISTRY = "0x2233ea2044ffa04ccceeef0b9adfe0799505a908"
TOKEN_ID = "0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38"
RECIPIENTS = [
    "0x224467f6640abe0a62d1be98187912627b59722a",
    "0x486371f86335dd1d3420bffad40959dd6e4d034c",
]


def cast(*args):
    result = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def rpc(method, *params):
    encoded = [p if isinstance(p, str) else json.dumps(p) for p in params]
    return json.loads(cast("rpc", "--rpc-url", RPC, method, *encoded))


evidence = json.loads((HERE / "issue_sbt-receipts.json").read_text())
hashes = [tx["hash"] for tx in evidence["transactions"] if tx.get("hash")]
assert len(hashes) == 1, "Expected exactly one submitted batch issuance transaction"
receipt = rpc("eth_getTransactionReceipt", hashes[0])
assert receipt and receipt["status"] == "0x1", "Issuance receipt is not successful"
assert receipt["from"].lower() == RECIPIENTS[1], "Unexpected signing wallet"
assert receipt["to"].lower() == SBT, "Unexpected destination"
block = rpc("eth_blockNumber")


def call(address, signature, *args):
    data = cast("calldata", signature, *args)
    return int(rpc("eth_call", {"to": address, "data": data}, block), 16)


def verify_recipient(account):
    balance = call(SBT, "balanceOf(address,uint256)", account, TOKEN_ID)
    swap = call(REGISTRY, "isSbtAllowed(bytes2,address)", "0x0001", account)
    lp = call(REGISTRY, "isSbtAllowed(bytes2,address)", "0x0002", account)
    assert balance == 1, f"Expected one SBT at {account}"
    assert swap == 1 and lp == 1, f"SWAP or LP permission inactive at {account}"
    return {"address": account, "sbt_balance": balance, "swap_allowed": bool(swap), "lp_allowed": bool(lp)}


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    recipients = list(executor.map(verify_recipient, RECIPIENTS))
result = {
    "transaction_hash": hashes[0], "status": receipt["status"],
    "sender": receipt["from"], "sbt": SBT, "token_id": TOKEN_ID,
    "transaction_block": int(receipt["blockNumber"], 16),
    "verification_block": int(block, 16), "recipients": recipients,
    "liquidity_transaction_sent": False,
}
(HERE / "sbt-final-verification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
