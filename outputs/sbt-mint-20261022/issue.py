"""Issue exactly the requested SBT using the existing SDK credential loader."""
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
os.environ["FOUNDRY_SRC"] = "script/xlayer"
os.environ["FOUNDRY_SCRIPT"] = "script/xlayer"
os.environ["FOUNDRY_TEST"] = str(HERE / "empty-tests")
os.environ["FOUNDRY_SKIP"] = '["TradeDexRouterTSV.s.sol"]'
sys.path.insert(0, str(ROOT / "sdk/python"))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target

operation = Operation(Target.ISSUE_OPERATOR_SBT, "Issue requested SBT to 0x3A8A", {
    "TSV_SBT": "0x053ecef8ccb8844322bee86290dae016b9843b6d",
    "TSV_SBT_TOKEN_ID": "0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38",
    "TSV_SBT_RECIPIENT_COUNT": "1",
    "TSV_SBT_RECIPIENT_0": "0x3A8A0baC3481C452de5d53946c73De4980c8C668",
})
client = ExecutionClient(root=ROOT)
simulation = client.simulate(operation)
(HERE / "simulation.log").write_text(simulation.result.stdout + simulation.result.stderr)
print(simulation.result.stdout, flush=True)
print(simulation.result.stderr, flush=True)
if not simulation.result.succeeded:
    raise SystemExit(simulation.result.returncode)
if input("Simulation complete; enter BROADCAST to submit: ").strip() != "BROADCAST":
    raise SystemExit("Not broadcast")
result = client.broadcast(simulation, "BROADCAST")
(HERE / "broadcast.log").write_text(result.stdout + result.stderr)
print(result.stdout, flush=True)
print(result.stderr, flush=True)
raise SystemExit(result.returncode)
