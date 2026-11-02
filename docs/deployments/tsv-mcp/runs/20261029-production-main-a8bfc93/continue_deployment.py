"""Public-input-only deployment preparation and independent chain verification."""
import datetime
import hashlib
import json
import math
import re
import subprocess
import sys
import uuid
from pathlib import Path

RUN = Path(__file__).resolve().parent
ZERO = "0x" + "00" * 20

def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], text=True).strip()

def rpc(method, params):
    endpoint = json.loads((RUN / "manifest.json").read_text())["network"]["rpcUrl"]
    response = json.loads(subprocess.check_output([
        "curl", "-sS", "--max-time", "30", endpoint,
        "-H", "Content-Type: application/json", "--data",
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
    ]))
    return response

def result(method, params):
    response = rpc(method, params)
    assert "result" in response, response
    return response["result"]

def call(address, signature, args=(), block="latest"):
    return result("eth_call", [{"to": address, "data": cast("calldata", signature, *args)}, block])

def artifact(name):
    return json.loads((RUN / "artifacts" / (name + ".json")).read_text())

def patch_links(code, references, addresses):
    code = code.removeprefix("0x")
    for libraries in references.values():
        for name, refs in libraries.items():
            for ref in refs:
                assert ref["length"] == 20
                start = ref["start"] * 2
                code = code[:start] + addresses[name][2:].lower() + code[start + 40:]
    bytes.fromhex(code)
    return code

def immutable_names():
    root = RUN.parents[4] / ".production-tsv-main-a8bfc93-20261029/out"
    names = {}
    def walk(value):
        if isinstance(value, dict):
            if value.get("nodeType") == "VariableDeclaration" and value.get("mutability") == "immutable":
                names[str(value["id"])] = value["name"]
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    for path in root.rglob("*.json"):
        walk(json.loads(path.read_text()).get("ast"))
    return names

def specifications(stage, m, a):
    d, c = m["dependencies"], m["configuration"]
    def implementation(name, args=()):
        abi = artifact(name)["abi"]
        constructors = [x for x in abi if x["type"] == "constructor"]
        types = [x["type"] for x in constructors[0]["inputs"]] if constructors else []
        assert len(types) == len(args)
        encoded = cast("abi-encode", "constructor(" + ",".join(types) + ")", *args) if args else "0x"
        return {"key": name, "artifact": name, "constructorArgs": list(args), "encodedArgs": encoded}
    def proxy(name, signature, args):
        init = cast("calldata", signature, *args)
        return {"key": name + "Proxy", "artifact": "TSVERC1967Proxy", "implementation": a[name],
                "initializerSignature": signature, "initializerArgs": list(args), "initData": init,
                "constructorArgs": [a[name], init],
                "encodedArgs": cast("abi-encode", "constructor(address,bytes)", a[name], init)}
    if stage == 2:
        return [implementation("TSVRegistryV1"), implementation("TSVSwapRouterV1", [d["poolManager"], a["PermissionsAdapterFactory"]])]
    if stage == 3:
        return [proxy("TSVRegistryV1", "initialize(address)", [m["registryInitialAdmin"]])]
    if stage == 4:
        return [proxy("TSVVolumeLedgerV1", "initialize(address)", [a["TSVRegistryV1Proxy"]]),
                proxy("TSVSwapRouterV1", "initialize(address,address)", [d["poolManager"], a["TSVRegistryV1Proxy"]]),
                implementation("TSVLPManagerV1", [d["poolManager"], d["permit2"], c["unsubscribeGasLimit"],
                    d["positionDescriptor"], d["wokb"], a["PermissionsAdapterFactory"], c["deliveryGasLimit"]])]
    if stage == 5:
        return [proxy("TSVLPManagerV1", "initialize(address)", [a["TSVRegistryV1Proxy"]])]
    assert stage == 6
    spec = proxy("TSVHookV1", "initialize(address,address,address,address,address)",
                 [d["poolManager"], a["TSVRegistryV1Proxy"], a["TSVVolumeLedgerV1Proxy"],
                  a["TSVSwapRouterV1Proxy"], a["TSVLPManagerV1Proxy"]])
    initcode = "0x" + artifact("TSVERC1967Proxy")["bytecode"]["object"].removeprefix("0x") + spec["encodedArgs"][2:]
    init_hash = cast("keccak", initcode)
    mining = cast("create2", "--deployer", a["TSVHookProxyFactoryV1"], "--init-code-hash", init_hash,
                  "--ends-with", "3fff", "--no-random", "--threads", "2", "--color", "never")
    (RUN / "hook-salt-mining.txt").write_text(mining + "\n")
    salt_match = re.search(r"Salt:\s*(0x[0-9a-fA-F]{64})", mining, re.I)
    address_match = re.search(r"Address:\s*(0x[0-9a-fA-F]{40})", mining, re.I)
    assert salt_match and address_match, mining
    salt, predicted = salt_match.group(1), address_match.group(1)
    onchain = "0x" + call(a["TSVHookProxyFactoryV1"], "predict(address,bytes,bytes32)",
                            [spec["implementation"], spec["initData"], salt])[-40:]
    assert onchain.lower() == predicted.lower() and int(predicted, 16) & 0x3FFF == 0x3FFF
    assert result("eth_getCode", [predicted, "latest"]) == "0x"
    spec.update({"factory": a["TSVHookProxyFactoryV1"], "salt": salt, "predictedAddress": predicted,
                 "initCodeHash": init_hash,
                 "factoryCalldata": cast("calldata", "deploy(address,bytes,bytes32)", spec["implementation"], spec["initData"], salt)})
    return [spec]

def prepare(stage):
    m = json.loads((RUN / "manifest.json").read_text())
    a = json.loads((RUN / "addresses.json").read_text())["addresses"]
    directory = RUN / ("batch-" + str(stage))
    directory.mkdir(exist_ok=True)
    assert not (directory / "create-response.json").exists(), "Prior invocation exists; reconcile before retry"
    assert int(result("eth_chainId", []), 16) == 196
    names = immutable_names()
    values = {"poolManager": m["dependencies"]["poolManager"], "PERMISSIONS_ADAPTER_FACTORY": a["PermissionsAdapterFactory"],
              "permit2": m["dependencies"]["permit2"], "tokenDescriptor": m["dependencies"]["positionDescriptor"],
              "WETH9": m["dependencies"]["wokb"], "unsubscribeGasLimit": m["configuration"]["unsubscribeGasLimit"],
              "DELIVERY_GAS_LIMIT": m["configuration"]["deliveryGasLimit"],
              "_HASHED_NAME": cast("keccak", "Uniswap v4 Positions NFT"), "__self": "SELF_AT_RUNTIME"}
    specs = specifications(stage, m, a)
    tasks = []
    for spec in specs:
        compiled = artifact(spec["artifact"])
        if "factory" in spec:
            data = spec["factoryCalldata"]
        else:
            data = "0x" + patch_links(compiled["bytecode"]["object"], compiled["bytecode"].get("linkReferences", {}), a) + spec["encodedArgs"][2:]
        tx = {"from": m["privilegeAddress"], "data": data, "value": "0x0"}
        if "factory" in spec:
            tx["to"] = spec["factory"]
        estimate = rpc("eth_estimateGas", [tx])
        simulation = rpc("eth_call", [tx, "latest"])
        spec.update({"gasEstimateResponse": estimate, "simulationResponse": simulation,
                     "calldataSha256": hashlib.sha256(bytes.fromhex(data[2:])).hexdigest()})
        save(directory / "preflight-progress.json", specs)
        assert "result" in estimate and "result" in simulation, spec["key"] + " simulation failed"
        if "factory" in spec:
            assert "0x" + simulation["result"][-40:].lower() == spec["predictedAddress"].lower()
        else:
            assert len(simulation["result"]) > 2
        spec["expectedImmutableValues"] = {ident: {"name": names[ident], "value": values[names[ident]]}
             for ident in compiled["deployedBytecode"].get("immutableReferences", {})}
        task = {"name": "TSV-prod-20261029-a8bfc93-" + spec["key"],
                "desc": "TSV production; main " + m["source"]["commit"] + "; batch " + str(stage) + "; deployment and atomic initialization only",
                "chain_id": 196, "calldata": data, "gas_limit": math.ceil(int(estimate["result"], 16) * 1.2) + 50000,
                "privilege_address": m["privilegeAddress"], "signatures": m["mcp"]["approvalSignatures"], "value": "0"}
        if "factory" in spec:
            task["to_address"] = spec["factory"]
        tasks.append(task)
    # UUIDs are assigned only after all simulation work, immediately before transmission.
    for task, spec in zip(tasks, specs):
        task["uuid"] = str(uuid.uuid4())
        spec["uuid"] = task["uuid"]
    request = {"deptName": "Dex", "tasks": tasks}
    save(directory / "request.json", request)
    save(directory / "plan.json", {"preparedAt": now(), "stage": stage, "sourceCommit": m["source"]["commit"], "specs": specs,
                                   "requestSha256": hashlib.sha256((directory / "request.json").read_bytes()).hexdigest()})
    print(json.dumps({"stage": stage, "preflightPassed": len(tasks), "request": str(directory / "request.json"),
                      "contracts": [x["key"] for x in specs]}))

def verify(stage):
    directory = RUN / ("batch-" + str(stage))
    plan = json.loads((directory / "plan.json").read_text())
    req = json.loads((directory / "request.json").read_text())
    statuses = json.loads((directory / "latest-status.json").read_text())["tasks"]
    m = json.loads((RUN / "manifest.json").read_text())
    addresses_file = json.loads((RUN / "addresses.json").read_text())
    addresses = addresses_file["addresses"]
    head = int(result("eth_blockNumber", []), 16)
    records = []
    for spec in plan["specs"]:
        status = next(x for x in statuses if x["uuid"] == spec["uuid"])
        data = json.loads(status["result"]["content"][0]["text"])["data"]
        assert data["task_status_name"] == "TASK_BROADCAST_SUCCESS_AND_TRANSACTION_SUCCESS", data
        task = next(x for x in req["tasks"] if x["uuid"] == spec["uuid"])
        tx = result("eth_getTransactionByHash", [data["tx_hash"]])
        receipt = result("eth_getTransactionReceipt", [data["tx_hash"]])
        assert tx and receipt and int(receipt["status"], 16) == 1
        assert tx["from"].lower() == m["privilegeAddress"].lower() and int(tx["value"], 16) == 0
        assert int(tx["chainId"], 16) == 196 and tx["input"].lower() == task["calldata"].lower()
        if "factory" in spec:
            assert tx["to"].lower() == spec["factory"].lower()
            address = spec["predictedAddress"]
            topic = cast("keccak", "HookProxyDeployed(address,address,bytes32)")
            events = [x for x in receipt["logs"] if x["address"].lower() == spec["factory"].lower() and x["topics"][0] == topic]
            assert len(events) == 1
            assert events[0]["topics"][1][-40:].lower() == address[2:].lower()
            assert events[0]["topics"][2][-40:].lower() == spec["implementation"][2:].lower()
            assert events[0]["topics"][3].lower() == spec["salt"].lower()
        else:
            assert tx["to"] is None
            address = receipt["contractAddress"]
        assert address
        block = receipt["blockNumber"]
        code = result("eth_getCode", [address, block])
        compiled = artifact(spec["artifact"])
        expected = patch_links(compiled["deployedBytecode"]["object"], compiled["deployedBytecode"].get("linkReferences", {}), addresses)
        for ident, refs in compiled["deployedBytecode"].get("immutableReferences", {}).items():
            value = spec["expectedImmutableValues"][ident]["value"]
            value = address if value == "SELF_AT_RUNTIME" else value
            integer = int(value, 16) if isinstance(value, str) else value
            for ref in refs:
                start, length = ref["start"] * 2, ref["length"] * 2
                encoded = format(integer, "0" + str(length) + "x")
                assert len(encoded) == length
                expected = expected[:start] + encoded + expected[start + length:]
        assert code[2:].lower() == expected.lower(), spec["key"] + " runtime mismatch"
        checks = {"receiptStatus": 1, "creationCalldataMatches": True, "runtimeMatches": True}
        if "implementation" in spec:
            slot = hex(int(cast("keccak", "eip1967.proxy.implementation"), 16) - 1)
            stored = result("eth_getStorageAt", [address, slot, block])
            assert stored[-40:].lower() == spec["implementation"][2:].lower()
            checks["erc1967ImplementationMatches"] = True
        if spec["key"] == "TSVRegistryV1Proxy":
            upgrade = cast("keccak", "UPGRADE_ADMIN_ROLE")
            for role in ["0x" + "00" * 32, upgrade]:
                assert int(call(address, "hasRole(bytes32,address)", [role, m["registryInitialAdmin"]], block), 16) == 1
                assert int(call(address, "hasRole(bytes32,address)", [role, m["privilegeAddress"]], block), 16) == 0
            assert int(call(address, "isPaused()", block=block), 16) == 0
            for getter in ["hook()", "lpManager()", "permissionsAdapterFactory()"]:
                assert int(call(address, getter, block=block), 16) == 0
            checks["adminAndUpgradeRolesVerified"] = True
            checks["businessComponentsUnconfigured"] = True
        elif spec["key"].endswith("Proxy"):
            expected_getters = {"registry()": addresses["TSVRegistryV1Proxy"]}
            if spec["key"] in ["TSVSwapRouterV1Proxy", "TSVLPManagerV1Proxy", "TSVHookV1Proxy"]:
                expected_getters["poolManager()"] = m["dependencies"]["poolManager"]
            if spec["key"] in ["TSVSwapRouterV1Proxy", "TSVLPManagerV1Proxy"]:
                expected_getters["PERMISSIONS_ADAPTER_FACTORY()"] = addresses["PermissionsAdapterFactory"]
            if spec["key"] == "TSVLPManagerV1Proxy":
                expected_getters.update({"permit2()": m["dependencies"]["permit2"], "WETH9()": m["dependencies"]["wokb"],
                   "tokenDescriptor()": m["dependencies"]["positionDescriptor"]})
                assert int(call(address, "nextTokenId()", block=block), 16) == 1
                assert int(call(address, "unsubscribeGasLimit()", block=block), 16) == m["configuration"]["unsubscribeGasLimit"]
                assert int(call(address, "DELIVERY_GAS_LIMIT()", block=block), 16) == m["configuration"]["deliveryGasLimit"]
            if spec["key"] == "TSVHookV1Proxy":
                expected_getters.update({"ledger()": addresses["TSVVolumeLedgerV1Proxy"], "router()": addresses["TSVSwapRouterV1Proxy"],
                                        "lpManager()": addresses["TSVLPManagerV1Proxy"]})
                assert int(address, 16) & 0x3FFF == 0x3FFF
                checks["create2FactoryEventAndFlagsVerified"] = True
            for getter, expected_address in expected_getters.items():
                actual = "0x" + call(address, getter, block=block)[-40:]
                assert actual.lower() == expected_address.lower(), getter
            checks["initializedDependenciesMatch"] = True
        if "initializerSignature" in spec:
            replay = rpc("eth_call", [{"from": m["privilegeAddress"], "to": address, "data": spec["initData"]}, block])
            assert "error" in replay, "Proxy can be initialized again"
            checks["reinitializationReverts"] = True
            checks["reinitializationResponse"] = replay
        record = {"contract": spec["key"], "uuid": spec["uuid"], "address": address, "txHash": tx["hash"],
                  "block": int(block, 16), "confirmationsAtCheck": head - int(block, 16) + 1, "checks": checks}
        save(RUN / "transactions" / (tx["hash"] + ".json"), {"transaction": tx, "receipt": receipt, "runtimeCodeAtReceiptBlock": code})
        save(RUN / "verification" / (spec["key"] + ".json"), record)
        addresses[spec["key"]] = address
        records.append(record)
    save(RUN / "addresses.json", addresses_file)
    save(directory / "chain-verification.json", {"checkedAt": now(), "status": "ALL_VERIFIED_SUCCESS", "contracts": records})
    m["status"] = "BATCH_" + str(stage) + "_DEPLOYED_AND_VERIFIED"
    m.setdefault("completedBatches", [1]).append(stage)
    m["transactions"].extend({"contract": r["contract"], "uuid": r["uuid"], "txHash": r["txHash"], "address": r["address"],
                               "block": r["block"], "receiptStatus": 1} for r in records)
    save(RUN / "manifest.json", m)
    with (RUN / "events.jsonl").open("a") as output:
        output.write(json.dumps({"at": now(), "type": "DEPENDENT_BATCH_VERIFIED", "stage": stage, "contracts": records}, ensure_ascii=False) + "\n")
    print(json.dumps({"stage": stage, "status": "ALL_VERIFIED_SUCCESS", "contracts": [{k: r[k] for k in ["contract", "address", "txHash"]} for r in records]}))

if __name__ == "__main__":
    command, stage = sys.argv[1], int(sys.argv[2])
    assert command in {"prepare", "verify"}
    (prepare if command == "prepare" else verify)(stage)
