#!/usr/bin/env python3
"""Complete and verify this session's deployment using unlocked local Anvil accounts."""

import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "broadcast/local-31337"
RPC = "http://127.0.0.1:8545"
DEPLOYER = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
GOVERNOR = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
GUARDIAN = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
COUNCIL = "0x90f79bf6eb2c4f870365e785982e1f101e93b906"
ANCHOR = "0xdc64a140aa3e981100a9beca4e685f962f0cf6c9"
PM = "0x5fbdb2315678afecb367f032d93f642f64180aa3"
SBT = "0xe7f1725e7734ce288f8367e1bb143e90bb3f0512"
LIBRARY = "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0"
FACTORY = "0xcf7ed3acca5a467e9e704c703e8d87f634fb0fc9"
INITIAL_COMPONENTS = {
    "registry": ("0x0165878a594ca255338adfa4d48449f69242eb8f", "0x5fc8d32690cc91d4c39d9d3abcbd16989f875707"),
    "volumeLedger": ("0x2279b7a0a67db372996a5fab50d91eaa73d2ebe6", "0xa513e6e4b8f2a923d98304ec87f64353c4d5c853"),
    "dataInbox": ("0x610178da211fef7d417bc0e6fed39f05609ad788", "0x8a791620dd6260079bf849dc5567adc3f2fdc318"),
    "swapRouter": ("0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0", "0xb7f8bc63bbcad18155201308c8f3540b07f84f5e"),
    "lpManager": ("0x9a676e781a523b5d0c0e43731313a708cb607508", "0x0dcd1bf9a1b36ce34237eeafef220932846bcd82"),
}
ORDER = ["registry", "volumeLedger", "dataInbox", "hook", "swapRouter", "lpManager"]
ENV_NAMES = ["TSV_REGISTRY", "TSV_VOLUME_LEDGER", "TSV_DATA_INBOX", "TSV_HOOK", "TSV_SWAP_ROUTER", "TSV_LP_MANAGER"]
ROLES = [
    ("symbolAdmins", "registry", "SYMBOL_ADMIN_ROLE", "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65"),
    ("poolCreators", "lpManager", "POOL_CREATOR_ROLE", "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc"),
    ("haltReporters", "dataInbox", "HALT_REPORTER_ROLE", "0x976ea74026e726554db657fa54763abd0c3a0aa9"),
    ("volumeOracles", "dataInbox", "VOLUME_ORACLE_ROLE", "0x14dc79964da2c08b23698b3d3cc7ca32193d9955"),
    ("emergencyPausers", "registry", "EMERGENCY_PAUSER_ROLE", "0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f"),
    ("emergencyResumers", "registry", "EMERGENCY_RESUMER_ROLE", "0xa0ee7a142d267c1f36714e4a8f75612f20a79720"),
    ("revokeExitExecutors", "lpManager", "REVOKE_EXIT_EXECUTOR_ROLE", "0x0000000000000000000000000000000000001001"),
    ("forceExitAdmins", "lpManager", "FORCE_EXIT_ADMIN_ROLE", "0x0000000000000000000000000000000000001002"),
]
PARTICIPANT = "0x0000000000000000000000000000000000001003"
LINK = f"src/v1/libraries/PermissionedValidationLib.sol:PermissionedValidationLib:{LIBRARY}"


def run(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, env=env)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(json.dumps(result["error"]))
    return result["result"]


def call(address, signature, *args, sender=None):
    command = ["cast", "call", address, signature, *map(str, args), "--rpc-url", RPC]
    if sender:
        command += ["--from", sender]
    # All calls in this helper have one scalar output (or an empty 0x result).
    # Cast annotates large integers, for example: 14400 [1.44e4].
    return run(*command).lower().split()[0]


def check(label, actual, expected):
    if actual != str(expected).lower():
        raise RuntimeError(f"{label}: expected {expected}, received {actual}")
    print(f"PASS {label}", flush=True)
    checks.append({"check": label, "passed": True, "actual": actual})


def save():
    (OUTPUT / "deployment.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (OUTPUT / "verification.json").write_text(json.dumps(checks, indent=2) + "\n")


def send(address, signature, *args, sender=GOVERNOR):
    result = json.loads(run("cast", "send", address, signature, *map(str, args),
                            "--rpc-url", RPC, "--unlocked", "--from", sender, "--json"))
    if result["status"] not in ("0x1", 1):
        raise RuntimeError(f"Failed transaction: {result}")
    manifest["releaseEvidence"]["configurationTransactions"].append({
        "to": address, "signature": signature, "from": sender,
        "transactionHash": result["transactionHash"], "blockNumber": result["blockNumber"],
    })
    save()
    print(f"MINED {signature}: {result['transactionHash']}", flush=True)
    return result


def deploy(label, contract):
    output = run("forge", "create", contract, "--rpc-url", RPC, "--unlocked",
                 "--from", DEPLOYER, "--broadcast", "--offline", "--json")
    (OUTPUT / f"{label}-deployment.log").write_text(output + "\n")
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", output):
        try:
            result, _ = decoder.raw_decode(output[match.start():])
        except json.JSONDecodeError:
            continue
        if isinstance(result, dict) and "deployedTo" in result:
            receipt = rpc("eth_getTransactionReceipt", [result["transactionHash"]])
            if receipt["status"] != "0x1":
                raise RuntimeError(f"Deployment reverted: {label}")
            print(f"DEPLOYED {label}: {result['deployedTo']}", flush=True)
            return result["deployedTo"].lower()
    raise RuntimeError(f"Cannot read deployment result for {label}: {output}")


def expect_revert(label, address, signature, args, sender, error_signature):
    selector = run("cast", "sig", error_signature).lower()
    try:
        call(address, signature, *args, sender=sender)
    except RuntimeError as error:
        if selector not in str(error).lower():
            raise RuntimeError(f"{label}: unexpected revert: {error}") from error
        print(f"PASS {label}", flush=True)
        checks.append({"check": label, "passed": True, "expectedError": error_signature})
    else:
        raise RuntimeError(f"{label}: expected revert")


if __name__ == "__main__":
    retail_id = int(os.environ["TSV_RETAIL_SBT_TOKEN_ID"])
    marketmaker_id = int(os.environ["TSV_MARKETMAKER_SBT_TOKEN_ID"])
    retail_mask = int(os.environ["TSV_RETAIL_SBT_PERMISSIONS"])
    marketmaker_mask = int(os.environ["TSV_MARKETMAKER_SBT_PERMISSIONS"])
    if retail_id == marketmaker_id or not (0 <= retail_mask <= 3 and 0 <= marketmaker_mask <= 3):
        raise SystemExit("Provide distinct retail/marketmaker IDs and permissions in 0..3.")
    if rpc("eth_chainId", []) != hex(31337) or "anvil" not in rpc("web3_clientVersion", []).lower():
        raise SystemExit("This helper requires the local Anvil chain 31337.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    checks = []
    manifest_file = OUTPUT / "deployment.json"
    if manifest_file.exists():
        manifest = json.loads(manifest_file.read_text())
    else:
        manifest = json.loads((ROOT / "docs/DEPLOYMENT_MANIFEST_V1.example.json").read_text())
        manifest["releaseEvidence"]["configurationTransactions"] = []
        manifest["releaseEvidence"]["localTestEvidence"] = {}
    manifest["status"] = "LOCAL_DEPLOYMENT_IN_PROGRESS"
    manifest["productionReady"] = False
    manifest["network"] = {"name": "anvil-local", "chainId": 31337, "rpcUrl": RPC,
                           "poolManager": {"address": PM, "v4Version": "repository-pinned"}}
    manifest["build"].update({"gitCommit": run("git", "rev-parse", "HEAD"),
                              "workingTreeClean": not bool(run("git", "status", "--porcelain")),
                              "foundryVersion": run("forge", "--version")})
    manifest["governance"].update({"governanceAnchor": ANCHOR, "governor": GOVERNOR,
                                   "guardian": GUARDIAN, "recoveryCouncil": COUNCIL})
    for name, (proxy, implementation) in INITIAL_COMPONENTS.items():
        manifest["businessProxies"][name] = {"proxy": proxy, "implementation": implementation}
        check(f"{name} implementation", call(proxy, "tsvImplementation()(address)"), implementation)
        check(f"{name} anchor", call(proxy, "governanceAnchor()(address)"), ANCHOR)
    check("Registry shared library", call(INITIAL_COMPONENTS["registry"][0], "permissionedValidationLibrary()(address)"), LIBRARY)
    check("Router shared library", call(INITIAL_COMPONENTS["swapRouter"][0], "permissionedValidationLibrary()(address)"), LIBRARY)
    check("Governor", call(ANCHOR, "governor()(address)"), GOVERNOR)
    check("Guardian", call(ANCHOR, "guardian()(address)"), GUARDIAN)
    check("Council", call(ANCHOR, "recoveryCouncil()(address)"), COUNCIL)
    save()

    hook_record = manifest["businessProxies"]["hook"]
    if not hook_record["implementation"]:
        hook_record["implementation"] = deploy("hook-implementation", "src/v1/core/TSVHookV1.sol:TSVHookV1")
        save()
    if not manifest["hookDeployment"]["factory"]:
        manifest["hookDeployment"]["factory"] = deploy("hook-factory", "src/v1/deployment/TSVHookProxyFactoryV1.sol:TSVHookProxyFactoryV1")
        save()
    addresses = {name: item["proxy"] for name, item in manifest["businessProxies"].items()}
    if not hook_record["proxy"]:
        init_data = run("cast", "calldata", "initialize(address,address,address,address,address,address)",
                        ANCHOR, PM, addresses["registry"], addresses["volumeLedger"], addresses["swapRouter"], addresses["lpManager"])
        proxy_code = run("forge", "inspect", "src/v1/deployment/TSVERC1967Proxy.sol:TSVERC1967Proxy", "bytecode", "--offline")
        constructor_data = run("cast", "abi-encode", "constructor(address,bytes)", hook_record["implementation"], init_data)
        init_code_hash = run("cast", "keccak", proxy_code + constructor_data[2:])
        factory = manifest["hookDeployment"]["factory"]
        mined = run("cast", "create2", "--deployer", factory, "--init-code-hash", init_code_hash,
                    "--ends-with", "3fff", "--no-random")
        (OUTPUT / "hook-mining.log").write_text(mined + "\n")
        predicted = re.search(r"Address: (0x[0-9a-fA-F]{40})", mined).group(1).lower()
        salt = re.search(r"Salt: (0x[0-9a-fA-F]{64})", mined).group(1)
        check("Hook factory prediction", call(factory, "predict(address,bytes,bytes32)(address)", hook_record["implementation"], init_data, salt), predicted)
        check("Hook permission bits", hex(int(predicted, 16) & 0x3FFF), "0x3fff")
        if rpc("eth_getCode", [predicted, "latest"]) != "0x":
            raise RuntimeError("Mined Hook address is occupied")
        send(factory, "deploy(address,bytes,bytes32)", hook_record["implementation"], init_data, salt, sender=DEPLOYER)
        hook_record["proxy"] = predicted
        manifest["hookDeployment"].update({"salt": salt, "predictedProxy": predicted,
                                           "actualProxy": predicted, "actualPermissionFlags": "0x3FFF",
                                           "tsvImplementation": hook_record["implementation"]})
        save()
    addresses["hook"] = hook_record["proxy"]
    registry, ledger, inbox, hook, router, lp = [addresses[name] for name in ORDER]
    check("Hook initialized implementation", call(hook, "tsvImplementation()(address)"), hook_record["implementation"])
    if call(registry, "hook()(address)") == "0x" + "0" * 40:
        binding = send(registry, "bindComponents(address,address,address,address,address)", hook, lp, inbox, FACTORY, SBT)
        manifest["permissionedEnvironment"]["bindingTransaction"] = binding["transactionHash"]
    if call(ledger, "hook()(address)") == "0x" + "0" * 40:
        send(ledger, "bindWriters(address,address)", hook, inbox)
    proxies = "[" + ",".join(addresses[name] for name in ORDER) + "]"
    if call(ANCHOR, "proxiesBound()(bool)") == "false":
        send(ANCHOR, "bindProxies(address[6])", proxies)
    for token_id, mask in [(retail_id, retail_mask), (marketmaker_id, marketmaker_mask)]:
        expected = ["true", f"0x{mask:04x}"]
        if call(registry, "sbtIdentityConfig(uint256)(bool,bytes2)", token_id).splitlines() != expected:
            send(
                registry,
                "setSbtConfig(uint256,bytes2,bytes32)",
                token_id,
                expected[1],
                "0x5445535400000000000000000000000000000000000000000000000000000000",
            )
    check("Configured SBT address", call(registry, "participantSbt()(address)"), SBT)
    manifest["sbt"] = {"address": SBT, "identities": [
        {"name": "retail", "tokenId": retail_id, "permissions": retail_mask},
        {"name": "marketmaker", "tokenId": marketmaker_id, "permissions": marketmaker_mask}], "mock": True}
    manifest["permissionedEnvironment"].update({"realFactory": FACTORY, "routerPermissionsAdapterFactory": FACTORY,
        "poolManager": PM, "router": router, "validationLibrary": LIBRARY})
    manifest["localSimulation"] = {"participant": PARTICIPANT, "additionalRoleAddressesAreSimulationIdentities": True,
        "assetsConfigured": False, "liquidityConfigured": False,
        "limitations": ["Production Wrapped LP is not delivered.", "No production issuer assets or live SBT were configured."]}
    for key, component, role_name, holder in ROLES:
        target = addresses[component]
        role = call(target, role_name + "()(bytes32)")
        if call(target, "hasRole(bytes32,address)(bool)", role, holder) == "false":
            send(target, "grantRole(bytes32,address)", role, holder)
        check(role_name + " holder", call(target, "hasRole(bytes32,address)(bool)", role, holder), "true")
        manifest["roles"][key] = [holder]
    save()

    expect_revert(
        "Deployer cannot configure SBT",
        registry,
        "setSbtConfig(uint256,bytes2,bytes32)",
        [retail_id, "0x0003", "0x5445535400000000000000000000000000000000000000000000000000000000"],
        DEPLOYER,
        "AccessControlUnauthorizedAccount(address,bytes32)",
    )
    expect_revert("Registry cannot be initialized twice", registry, "initialize(address)", [ANCHOR], DEPLOYER, "InvalidInitialization()")
    if call(SBT, "holds(address,uint256)(bool)", PARTICIPANT, retail_id) == "false":
        send(SBT, "setHolder(address,uint256,bool)", PARTICIPANT, retail_id, "true", sender=DEPLOYER)
    check("SBT eligible participant", call(registry, "isAllowed(bytes2,address)(bool)", "0x0001", PARTICIPANT), "true")
    check("SBT ineligible non-holder", call(registry, "isAllowed(bytes2,address)(bool)", "0x0001", DEPLOYER), "false")
    send(SBT, "setPaused(bool)", "true", sender=DEPLOYER)
    try:
        check("Paused SBT rejects participant", call(registry, "isAllowed(bytes2,address)(bool)", "0x0001", PARTICIPANT), "false")
    finally:
        send(SBT, "setPaused(bool)", "false", sender=DEPLOYER)

    check("Upgrades initially open", call(ANCHOR, "upgradesFrozen()(bool)"), "false")
    expect_revert("Governor cannot freeze upgrades", ANCHOR, "freezeUpgrades()", [], GOVERNOR, "Unauthorized()")
    send(ANCHOR, "freezeUpgrades()", sender=GUARDIAN)
    freeze_id = call(ANCHOR, "freezeId()(bytes32)")
    implementations = "[" + ",".join(manifest["businessProxies"][name]["implementation"] for name in ORDER) + "]"
    empty_calls = "[" + ",".join("0x" for _ in ORDER) + "]"
    try:
        for name in ORDER:
            entry = manifest["businessProxies"][name]
            expect_revert(name + " upgrade blocked while frozen", entry["proxy"], "upgradeToAndCall(address,bytes)",
                          [entry["implementation"], "0x"], GOVERNOR, "UpgradeFrozen()")
        expect_revert("Batch upgrade blocked while frozen", ANCHOR, "upgradeBatch(address[],address[],bytes[])",
                      [proxies, implementations, empty_calls], GOVERNOR, "UpgradeFrozen()")
        for label, sender in [("Governor", GOVERNOR), ("Council", COUNCIL)]:
            expect_revert(label + " cannot unfreeze upgrades", ANCHOR, "unfreezeUpgrades(bytes32)",
                          [freeze_id], sender, "Unauthorized()")
    finally:
        send(ANCHOR, "unfreezeUpgrades(bytes32)", freeze_id, sender=GUARDIAN)
    check("Guardian restored upgrade availability", call(ANCHOR, "upgradesFrozen()(bool)"), "false")
    for name in ORDER:
        entry = manifest["businessProxies"][name]
        check(name + " Governor upgrade dry-run", call(entry["proxy"], "upgradeToAndCall(address,bytes)", entry["implementation"], "0x", sender=GOVERNOR), "0x")
        check(name + " implementation unchanged", call(entry["proxy"], "tsvImplementation()(address)"), entry["implementation"])
    check("Governor batch upgrade dry-run", call(ANCHOR, "upgradeBatch(address[],address[],bytes[])", proxies, implementations, empty_calls, sender=GOVERNOR), "0x")

    environment = {"TSV_RPC_URL": RPC, "TSV_CHAIN_ID": "31337", "TSV_DEPLOYER": DEPLOYER,
                   "TSV_GOVERNOR": GOVERNOR, "TSV_GUARDIAN": GUARDIAN, "TSV_RECOVERY_COUNCIL": COUNCIL,
                   "TSV_GOVERNANCE_ANCHOR": ANCHOR, "TSV_POOL_MANAGER": PM, "TSV_SBT": SBT,
                   "TSV_RETAIL_SBT_TOKEN_ID": str(retail_id), "TSV_MARKETMAKER_SBT_TOKEN_ID": str(marketmaker_id),
                   "TSV_RETAIL_SBT_PERMISSIONS": str(retail_mask), "TSV_MARKETMAKER_SBT_PERMISSIONS": str(marketmaker_mask), "TSV_DAY_START_OFFSET_SECONDS": "14400",
                   "TSV_PERMISSIONED_VALIDATION_LIBRARY": LIBRARY, "TSV_PERMISSIONS_ADAPTER_FACTORY": FACTORY,
                   "TSV_HOOK_FACTORY": manifest["hookDeployment"]["factory"],
                   "TSV_HOOK_SALT": manifest["hookDeployment"]["salt"], "TSV_LIBRARY_LINK": LINK}
    for name, variable in zip(ORDER, ENV_NAMES):
        environment[variable] = addresses[name]
        environment[variable + "_IMPLEMENTATION"] = manifest["businessProxies"][name]["implementation"]
    (OUTPUT / "public.env").write_text("# Local simulation addresses; contains no private keys.\n" +
        "\n".join(f'export {key}="{value}"' for key, value in environment.items()) + "\n")
    process_env = os.environ.copy()
    process_env.update(environment)
    print("Running repository VerifyDeploymentV1...", flush=True)
    verification = run("forge", "script", "script/VerifyDeploymentV1.s.sol:VerifyDeploymentV1",
                       "--rpc-url", RPC, "--libraries", LINK, "--offline", "-vv", env=process_env)
    (OUTPUT / "verify-deployment.log").write_text(verification + "\n")
    if "TSV governance, six proxy links and implementation addresses verified." not in verification:
        raise RuntimeError("Repository verifier did not report success")
    check("Repository deployment verifier", "passed", "passed")
    check("Ledger day-start offset", call(ledger, "initialDayStartOffsetSeconds()(uint32)"), "14400")
    manifest["governance"].update({"upgradesFrozen": False,
                                  "freezeEpoch": int(call(ANCHOR, "freezeEpoch()(uint64)")), "freezeId": freeze_id})
    manifest["bindings"] = {"anchorProxyOrder": [addresses[name] for name in ORDER],
        "registryHook": hook, "registryLpManager": lp, "registryDataInbox": inbox,
        "ledgerHook": hook, "ledgerDataInbox": inbox, "routerPoolManager": PM,
        "routerRegistry": registry, "lpPoolManager": PM, "lpRegistry": registry,
        "hookPoolManager": PM, "hookRegistry": registry, "hookLedger": ledger, "hookRouter": router, "hookLpManager": lp}
    receipts = []
    deployments = []
    latest = int(rpc("eth_blockNumber", []), 16)
    for height in range(1, latest + 1):
        for transaction in rpc("eth_getBlockByNumber", [hex(height), True])["transactions"]:
            receipt = rpc("eth_getTransactionReceipt", [transaction["hash"]])
            receipts.append(receipt)
            if receipt.get("contractAddress"):
                deployments.append({"address": receipt["contractAddress"], "transactionHash": transaction["hash"], "blockNumber": height})
    manifest["releaseEvidence"]["deploymentTransactions"] = deployments
    manifest["releaseEvidence"]["indexerStartBlock"] = 1
    manifest["releaseEvidence"]["postDeploymentChecks"] = checks
    manifest["releaseEvidence"].update({"wrappedRouterReady": False, "wrappedLiquidityReady": False,
                                        "wrappedSwapLocalVerified": False})
    for key, address in [("registryRuntimeSizeBytes", INITIAL_COMPONENTS["registry"][1]),
                         ("routerRuntimeSizeBytes", INITIAL_COMPONENTS["swapRouter"][1]),
                         ("permissionedValidationLibraryRuntimeSizeBytes", LIBRARY)]:
        manifest["build"][key] = (len(rpc("eth_getCode", [address, "latest"])) - 2) // 2
    manifest["status"] = "LOCAL_DEPLOYMENT_VERIFIED"
    manifest["localSimulation"]["lastBlock"] = latest
    (OUTPUT / "receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")
    (OUTPUT / "anvil-state.hex").write_text(rpc("anvil_dumpState", []) + "\n")
    save()
    print(f"COMPLETE: {len(checks)} checks passed; artifacts in {OUTPUT}", flush=True)
