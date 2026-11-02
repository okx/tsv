"""Verify the user-supplied Factory transaction without attributing it to MCP."""
import datetime
import json
from pathlib import Path
from zoneinfo import ZoneInfo
import continue_deployment as dep

P = Path(__file__).resolve().parent
manual = json.loads((P / "manual-hook-deployment.json").read_text())
source = json.loads((P / "hook-manual-transaction-check.json").read_text())
tx, receipt = source["transaction"], source["receipt"]
assert int(receipt["status"], 16) == 1
assert int(tx["chainId"], 16) == 196 and int(tx["value"], 16) == 0
assert tx["to"].lower() == manual["to"].lower()
assert tx["input"].lower() == manual["data"].lower()
proxy = manual["expectedHookProxy"]
implementation = manual["args"]["implementation"]
topic = dep.cast("keccak", "HookProxyDeployed(address,address,bytes32)")
events = [x for x in receipt["logs"] if x["address"].lower() == manual["to"].lower() and x["topics"][0] == topic]
assert len(events) == 1
event = events[0]
assert event["topics"][1][-40:].lower() == proxy[2:].lower()
assert event["topics"][2][-40:].lower() == implementation[2:].lower()
assert event["topics"][3].lower() == manual["args"]["salt"].lower()
block = receipt["blockNumber"]
code = dep.result("eth_getCode", [proxy, block])
assert code.lower() == dep.artifact("TSVERC1967Proxy")["deployedBytecode"]["object"].lower()
slot = hex(int(dep.cast("keccak", "eip1967.proxy.implementation"), 16) - 1)
assert dep.result("eth_getStorageAt", [proxy, slot, block])[-40:].lower() == implementation[2:].lower()
assert dep.call(proxy, "tsvImplementation()", block=block)[-40:].lower() == implementation[2:].lower()
assert int(proxy, 16) & 0x3FFF == 0x3FFF
getters = {"poolManager()": "poolManager", "registry()": "registry", "ledger()": "ledger", "router()": "router", "lpManager()": "lpManager"}
bindings = {}
for getter, key in getters.items():
    value = "0x" + dep.call(proxy, getter, block=block)[-40:]
    assert value.lower() == manual["initializerDecoded"][key].lower()
    bindings[getter] = value
replay = dep.rpc("eth_call", [{"from": tx["from"], "to": proxy, "data": manual["args"]["initData"]}, block])
assert "error" in replay and dep.cast("sig", "InvalidInitialization()").lower() in json.dumps(replay).lower()
header = dep.result("eth_getBlockByNumber", [block, False])
timestamp = datetime.datetime.fromtimestamp(int(header["timestamp"], 16), datetime.timezone.utc)
head = int(dep.result("eth_blockNumber", []), 16)
record = {"contract": "TSVHookV1Proxy", "address": proxy, "txHash": tx["hash"], "block": int(block, 16),
          "deploymentTimeUTC": timestamp.isoformat(), "deploymentTimeShanghai": timestamp.astimezone(ZoneInfo("Asia/Shanghai")).isoformat(),
          "deploymentChannel": "USER_MANUAL_FACTORY_CALL", "transactionSender": tx["from"], "taskId": None, "uuid": None,
          "confirmationsAtCheck": head - int(block, 16) + 1,
          "checks": {"receiptStatus": 1, "factoryCalldataMatchesPreparedParameters": True,
                     "factoryEventAndSaltMatches": True, "runtimeMatchesCompiledProxy": True,
                     "erc1967ImplementationMatches": True, "hookPermissionBits": "0x3fff", "initializedDependencies": bindings,
                     "reinitializationReverts": True, "reinitializationResponse": replay}}
dep.save(P / "verification/TSVHookV1Proxy.json", record)
dep.save(P / "transactions" / (tx["hash"] + ".json"), {"transaction": tx, "receipt": receipt, "runtimeCodeAtReceiptBlock": code})
addresses = json.loads((P / "addresses.json").read_text())
addresses["addresses"]["TSVHookV1Proxy"] = proxy
addresses.pop("batch", None)
addresses["completedDeploymentBatches"] = [1, 2, 3, 4, 5, "manual Hook CREATE2"]
dep.save(P / "addresses.json", addresses)
m = json.loads((P / "manifest.json").read_text())
m["status"] = "ALL_15_CORE_CONTRACTS_DEPLOYED_AND_INITIALIZED"
m["hookManualDeployment"] = record
m["remainingDeployment"] = "Core deployment complete. Business binding, assets, pools and quotas are a separate configuration phase."
m["supportingBootstrap"]["status"] = "NOT_DEPLOYED_NOT_NEEDED_MANUAL_FACTORY_COMPLETED"
if not any(x.get("txHash") == tx["hash"] for x in m["transactions"]):
    m["transactions"].append({"contract": "TSVHookV1Proxy", "txHash": tx["hash"], "address": proxy,
                              "block": int(block, 16), "receiptStatus": 1, "deploymentChannel": "USER_MANUAL_FACTORY_CALL"})
dep.save(P / "manifest.json", m)
with (P / "events.jsonl").open("a") as output:
    output.write(json.dumps({"timestamp": dep.now(), "type": "MANUAL_HOOK_DEPLOYMENT_VERIFIED", "record": record}, ensure_ascii=False) + "\n")
print(json.dumps({"status": "HOOK_DEPLOYED_INITIALIZED_VERIFIED", "proxy": proxy, "implementation": implementation,
                  "txHash": tx["hash"], "sender": tx["from"], "timeShanghai": record["deploymentTimeShanghai"],
                  "confirmations": record["confirmationsAtCheck"]}, ensure_ascii=False))
