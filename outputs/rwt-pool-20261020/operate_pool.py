"""Task-specific TSV operations. Credentials stay in the existing SDK loader."""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
# Compile only the operator scripts and their transitive imports. Unrelated
# vendor source copies in the working tree require a different solc version.
os.environ["FOUNDRY_SRC"] = "script/xlayer"
os.environ["FOUNDRY_SCRIPT"] = "script/xlayer"
os.environ["FOUNDRY_TEST"] = "outputs/rwt-pool-20261020/empty-tests"
os.environ["FOUNDRY_SKIP"] = '["TradeDexRouterTSV.s.sol"]'
sys.path.insert(0, str(ROOT / "sdk/python"))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target

W = "0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c"
U = "0x28Ccb07e804c6541634C07f1809f7Eaae3B523B0"
Q = "0xb6ceceab302e2e4948951ee7843fc24e92933061"
HOOK = "0xbc6d8c8a8b681872a93554116f01268f80c9ffff"
KEY = {
    "TSV_CURRENCY0": Q,
    "TSV_CURRENCY1": W,
    "TSV_FEE": "2000",
    "TSV_TICK_SPACING": "40",
    "TSV_HOOK": HOOK,
}

operations = {
    "grant_symbol": Operation(Target.REGISTRY_OPERATION, "Enable required RWT registration role", {
        "TSV_REGISTRY_ACTION": "GRANT_SYMBOL_ADMIN_ROLE",
        "TSV_ROLE_ACCOUNT": "0x224467f6640AbE0A62D1be98187912627b59722A",
    }),
    "grant_creator": Operation(Target.REGISTRY_OPERATION, "Enable required pool creation role", {
        "TSV_REGISTRY_ACTION": "GRANT_POOL_CREATOR_ROLE",
        "TSV_ROLE_ACCOUNT": "0x224467f6640AbE0A62D1be98187912627b59722A",
    }),
    "issue_sbt": Operation(Target.ISSUE_OPERATOR_SBT, "Issue one SWAP|LP SBT to each requested wallet", {
        "TSV_SBT": "0x053ecef8ccb8844322bee86290dae016b9843b6d",
        "TSV_SBT_TOKEN_ID": "0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38",
        "TSV_SBT_EXPECTED_ISSUER": "0x486371f86335dd1d3420bffad40959dd6e4d034c",
        "TSV_SBT_RECIPIENT_COUNT": "2",
        "TSV_SBT_RECIPIENT_0": "0x224467f6640abe0a62d1be98187912627b59722a",
        "TSV_SBT_RECIPIENT_1": "0x486371f86335dd1d3420bffad40959dd6e4d034c",
    }),
    "register": Operation(Target.REGISTER_STOCKS, "Register specified RWT wrapper", {
        "TSV_STOCK_COUNT": "1",
        "TSV_STOCK_WRAPPED_0": W,
        "TSV_STOCK_UNDERLYING_0": U,
        "TSV_STOCK_SECURITY_ID_0": "0xe29c89c6170c14d1aec33ef8c32df8beb88a6ff3e6e3c30a8bcb27e4321773e3",
        "TSV_STOCK_LEGAL_SHARE_ADAPTER_0": "0x1501e20d4990f4A33f3807a9482AF910bDcD3F68",
        "TSV_STOCK_TIER_ID_0": "2",
        "TSV_STOCK_REASON_0": "0x" + b"RWT_POOL_20261020".ljust(32, b"\0").hex(),
    }),
    "initialize": Operation(Target.INITIALIZE_POOLS, "Initialize RWT and specified quote pool", {
        "TSV_POOL_COUNT": "1",
        "TSV_POOL_CURRENCY0_0": Q,
        "TSV_POOL_CURRENCY1_0": W,
        "TSV_POOL_FEE_0": "2000",
        "TSV_POOL_TICK_SPACING_0": "40",
        "TSV_POOL_HOOK_0": HOOK,
        "TSV_POOL_SQRT_PRICE_X96_0": str((1 << 96) * 10**6),
    }),
    "liquidity": Operation(Target.ADD_LIQUIDITY, "Add up to 10 RWT and 10 quote tokens", {
        **KEY,
        "TSV_LIQUIDITY_EXPECTED_OWNER": "0x224467f6640abe0a62d1be98187912627b59722a",
        "TSV_LIQUIDITY_AMOUNT0_MAX": "10000000",
        "TSV_LIQUIDITY_AMOUNT1_MAX": "10000000000000000000",
        "TSV_LIQUIDITY_TICK_RADIUS": "600",
    }),
    "inspect": Operation(Target.INSPECT_POOL, "Inspect selected RWT pool", KEY),
}

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=operations)
parser.add_argument("--broadcast", action="store_true")
args = parser.parse_args()
operation = operations[args.action]
print(json.dumps({"action": args.action, "inputs": dict(operation.inputs)}, indent=2), flush=True)
client = ExecutionClient(root=ROOT)
simulation = client.simulate(operation)
print(simulation.result.stdout, flush=True)
print(simulation.result.stderr, file=sys.stderr, flush=True)
if not simulation.result.succeeded:
    raise SystemExit(simulation.result.returncode)
if args.broadcast:
    result = client.broadcast(simulation, "BROADCAST")
    print(result.stdout, flush=True)
    print(result.stderr, file=sys.stderr, flush=True)
    receipt_file = ROOT / "broadcast" / operation.target.script.split(":")[0] / "196/run-latest.json"
    if receipt_file.exists():
        public_run = json.loads(receipt_file.read_text())
        evidence = {
            "action": args.action,
            "inputs": dict(operation.inputs),
            "returncode": result.returncode,
            "transactions": [
                {k: tx.get(k) for k in ("hash", "transactionType", "contractAddress", "function", "arguments")}
                for tx in public_run.get("transactions", [])
            ],
            "receipts": public_run.get("receipts", []),
        }
        (Path(__file__).parent / f"{args.action}-receipts.json").write_text(json.dumps(evidence, indent=2) + "\n")
    raise SystemExit(result.returncode)
