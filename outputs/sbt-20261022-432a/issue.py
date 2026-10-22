"""Issue only the explicitly requested SBT using the existing credential loader."""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.environ.update({
    "FOUNDRY_SRC": "script/xlayer",
    "FOUNDRY_SCRIPT": "script/xlayer",
    "FOUNDRY_TEST": "outputs/sbt-20261022-432a/empty-tests",
    "FOUNDRY_SKIP": '["TradeDexRouterTSV.s.sol"]',
    "XLAYER_RPC_URL": "https://xlayerrpc.okx.com",
    "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1",
})
sys.path.insert(0, str(ROOT / "sdk/python"))
from tsv_xlayer_sdk import ExecutionClient, Operation, Target

operation = Operation(Target.ISSUE_OPERATOR_SBT, "Issue requested SBT to both 0x432a17c63787748be2b85af8cfbdb565a4cefd59 and 0x30588116d727204c01f62f444a43c88cd87f81f9", {
    "TSV_REGISTRY": "0x2233ea2044ffa04ccceeef0b9adfe0799505a908",
    "TSV_SBT": "0x053ecef8ccb8844322bee86290dae016b9843b6d",
    "TSV_SBT_TOKEN_ID": "0xfeb8f7a2d260241fea015286fede6aeceee45bb911b64de0d6105a7fbd0e7a38",
    "TSV_SBT_RECIPIENT_COUNT": "2",
    "TSV_SBT_RECIPIENT_0": "0x432a17c63787748be2b85af8cfbdb565a4cefd59",
    "TSV_SBT_RECIPIENT_1": "0x30588116d727204c01f62f444a43c88cd87f81f9",
})
client = ExecutionClient(root=ROOT)
simulation = client.simulate(operation)
print(simulation.result.stdout, flush=True)
print(simulation.result.stderr, file=sys.stderr, flush=True)
if not simulation.result.succeeded:
    raise SystemExit(simulation.result.returncode)
confirmation = input("Simulation succeeded. Broadcast this issuance: ").strip()
result = client.broadcast(simulation, confirmation)
print(result.stdout, flush=True)
print(result.stderr, file=sys.stderr, flush=True)
raise SystemExit(result.returncode)
