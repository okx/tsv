"""Add the authorized 23-USDC liquidity position through the existing SDK."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "sdk/python"))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target

os.environ["FOUNDRY_SRC"] = "script/xlayer"
os.environ["FOUNDRY_SCRIPT"] = "script/xlayer"
os.environ["FOUNDRY_TEST"] = "outputs/rwt-pool-20261020/empty-tests"
os.environ["FOUNDRY_SKIP"] = '["TradeDexRouterTSV.s.sol"]'
parser = argparse.ArgumentParser()
parser.add_argument("--broadcast", action="store_true")
args = parser.parse_args()
plan = json.loads((HERE / "plan.json").read_text())
evidence_path = HERE / "liquidity-receipts.json"
if args.broadcast and evidence_path.exists():
    previous = json.loads(evidence_path.read_text())
    if any(tx.get("hash") for tx in previous.get("transactions", [])):
        raise SystemExit("Submitted transactions already recorded; inspect receipts before any further broadcast")

operation = Operation(Target.ADD_LIQUIDITY, "Add 23 USDC with matching RWT", {
    "TSV_CURRENCY0": "0xb6ceceab302e2e4948951ee7843fc24e92933061",
    "TSV_CURRENCY1": "0xf6bb667b55d0cacdb9d2bb9d75d78b4ebe1f1b6c",
    "TSV_FEE": "2000", "TSV_TICK_SPACING": "40",
    "TSV_HOOK": "0xbc6d8c8a8b681872a93554116f01268f80c9ffff",
    "TSV_LIQUIDITY_EXPECTED_OWNER": plan["owner"],
    "TSV_LIQUIDITY_AMOUNT0_MAX": str(plan["quote_amount_max"]),
    "TSV_LIQUIDITY_AMOUNT1_MAX": str(plan["rwt_amount_max"]),
    "TSV_LIQUIDITY_TICK_RADIUS": "600",
})
print(json.dumps(dict(operation.inputs), indent=2), flush=True)
client = ExecutionClient(root=ROOT)
simulation = client.simulate(operation)
print(simulation.result.stdout, flush=True)
print(simulation.result.stderr, file=sys.stderr, flush=True)
(HERE / "simulation.log").write_text(simulation.result.stdout + simulation.result.stderr)
if not simulation.result.succeeded:
    raise SystemExit(simulation.result.returncode)
if args.broadcast:
    started = time.time()
    result = client.broadcast(simulation, "BROADCAST")
    print(result.stdout, flush=True)
    print(result.stderr, file=sys.stderr, flush=True)
    (HERE / "broadcast.log").write_text(result.stdout + result.stderr)
    receipt_file = ROOT / "broadcast/AddLiquidityTSV.s.sol/196/run-latest.json"
    if receipt_file.exists() and receipt_file.stat().st_mtime >= started:
        run = json.loads(receipt_file.read_text())
        evidence = {
            "action": "liquidity", "inputs": dict(operation.inputs), "returncode": result.returncode,
            "transactions": [{k: tx.get(k) for k in (
                "hash", "transactionType", "contractAddress", "function", "arguments",
            )} for tx in run.get("transactions", [])],
            "receipts": run.get("receipts", []),
        }
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    raise SystemExit(result.returncode)
