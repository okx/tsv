#!/usr/bin/env python3
"""Single entry point for TSV + AA + SBT deployment/upgrades/trading on chain 196."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import re

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENT_FILE = Path("dployment/XLAYER_MAINNET_SMOKE_20261014.json")
SCRIPT = "script/TSVProtocol.s.sol:TSVProtocol"
REFERENCE = "78e2fcaa82c628f2ca6540f797b20d7bfe170c50"
USER_OP_EVENT = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"


def run(args, capture=False):
    attempts = 4 if args[0] == "cast" else 1
    for attempt in range(attempts):
        result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
        if result.returncode == 0:
            break
        if attempt + 1 < attempts:
            time.sleep(attempt + 1)
    if result.returncode:
        # Print only call names from failed simulations; never arguments/signatures.
        calls = [line.split("(", 1)[0].strip() for line in result.stdout.splitlines() if "::" in line or "[Revert]" in line]
        for line in calls[-12:]:
            print(line[:180], file=sys.stderr)
        reason = next((line for line in reversed(result.stdout.splitlines() + result.stderr.splitlines()) if line.startswith("Error:")), "")
        safe_reason = re.sub(r"https?://[^\s)]+", "<RPC>", reason)[:200]
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}): {safe_reason}")
    if capture:
        return result.stdout
    for line in result.stdout.splitlines():
        if any(label in line for label in ("ONCHAIN EXECUTION", "Script ran", "AA position id", "New Registry", "New PermissionsAdapterFactory", "New HookProxyFactory", "AA Wallet", "Compiler run successful")):
            print(line)
    return ""


def read_manifest():
    data = json.loads(DEPLOYMENT_FILE.read_text())
    if data.get("chainId") != 196:
        raise RuntimeError("manifest must target X Layer mainnet (196)")
    if data.get("sourceVerification") is not False:
        raise RuntimeError("sourceVerification must remain false")
    return data


def write_manifest(data):
    tmp = DEPLOYMENT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(DEPLOYMENT_FILE)


def prepare_aa(repo):
    repo = Path(repo).resolve()
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    if head != REFERENCE:
        raise RuntimeError(f"AA reference must be checked out at {REFERENCE}")
    subprocess.run(["forge", "build", "src/SmartWalletEntry.sol", "src/SmartWalletFactory.sol", "--no-metadata"], cwd=repo, check=True)
    dest = ROOT / "dployment/aa"
    dest.mkdir(parents=True, exist_ok=True)
    manifest = read_manifest()
    for name, key in [("SmartWalletEntry", "implementation"), ("SmartWalletFactory", "factory")]:
        src = repo / "out" / f"{name}.sol" / f"{name}.json"
        artifact = json.loads(src.read_text())
        code = artifact["bytecode"]["object"]
        if not code or "__" in code:
            raise RuntimeError(f"{name} artifact empty or has unlinked libraries")
        artifact_file = dest / f"{name}.json"
        # Keep only deployable bytes, not source/debug/compiler input.
        artifact_file.write_text(json.dumps({"bytecode": {"object": code}}, indent=2) + "\n")
        manifest["aa"][f"{key}Artifact"] = str(artifact_file.relative_to(ROOT))
        digest = run(["cast", "keccak", code], capture=True).strip()
        manifest["aa"][f"{key}ArtifactHash"] = digest
    manifest["aa"]["referenceCommit"] = REFERENCE
    write_manifest(manifest)
    print("AA deployment artifacts prepared locally; source metadata disabled.")


def receipt_success(receipt):
    status = receipt.get("status")
    if status not in (1, "0x1", "0x01", "1", "success"):
        raise RuntimeError(f"transaction failed: {receipt.get('transactionHash')}")
    user_ops = []
    for log in receipt.get("logs", []):
        topics = log.get("topics", [])
        if topics and topics[0].lower() == USER_OP_EVENT:
            payload = bytes.fromhex(log["data"][2:])
            if len(payload) != 128 or int.from_bytes(payload[32:64], "big") != 1:
                raise RuntimeError("mined UserOperationEvent.success is false")
            user_ops.append(topics[1])
    return user_ops


def execute(sig, values, action, rpc, broadcast):
    original = DEPLOYMENT_FILE.read_bytes()
    before_proxies = read_manifest()["proxies"].copy()
    if int(run(["cast", "chain-id", "--rpc-url", rpc], capture=True).strip()) != 196:
        raise RuntimeError("RPC is not X Layer mainnet")
    if broadcast:
        history = ROOT / "dployment/history"
        history.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        (history / f"{stamp}-{action}.json").write_bytes(original)
    if action == "deploy" or (action == "bootstrap" and not read_manifest()["configuration"]["preserveProxies"]):
        manifest = read_manifest()
        manifest["transactions"] = {}
        manifest["testResults"] = {}
        manifest["operations"] = {"receipts": []}
        manifest["supportingContracts"].pop("smokeSbt", None)
        manifest["factoryDeployment"] = "fresh"
        write_manifest(manifest)
    started_at = time.time()
    function = sig.split("(", 1)[0]
    broadcast_file = ROOT / f"broadcast/TSVProtocol.s.sol/196/{function}-latest.json"
    command = ["forge", "script", SCRIPT, "--rpc-url", rpc, "--no-metadata", "--sig", sig]
    if broadcast:
        command += ["--broadcast", "--slow"]
    command += values
    try:
        run(command)
        if action == "verify":
            print("Protocol bindings and implementation slots verified."); return
        if not broadcast:
            print("Fork simulation completed; deployment JSON restored.")
            return
        function = sig.split("(", 1)[0]
        artifact = ROOT / f"broadcast/TSVProtocol.s.sol/196/{function}-latest.json"
        result = json.loads(artifact.read_text())
        txs = result.get("transactions", [])
        if result.get("pending"):
            raise RuntimeError("broadcast still contains pending transactions")
        manifest = read_manifest()
        if before_proxies and action != "deploy" and not (action == "bootstrap" and not manifest["configuration"]["preserveProxies"]):
            if manifest["proxies"] != before_proxies:
                raise RuntimeError("protocol proxy addresses changed")
        operations = manifest.setdefault("operations", {})
        records = operations.setdefault("receipts", [])
        found_user_ops = []
        for tx in txs:
            tx_hash = tx.get("hash")
            if not tx_hash:
                raise RuntimeError("broadcast transaction missing hash")
            receipt = json.loads(run(["cast", "receipt", tx_hash, "--rpc-url", rpc, "--json"], capture=True))
            ops = receipt_success(receipt)
            found_user_ops += ops
            records.append({"action": action, "transactionHash": tx_hash, "status": "success", "userOpHashes": ops})
        if action in ("swap", "add", "collect", "remove", "smoke") and not found_user_ops:
            raise RuntimeError("AA action missing mined UserOperationEvent")
        if action in ("deploy", "bootstrap", "upgrade", "migrate-sbt"):
            run(["forge", "script", SCRIPT, "--rpc-url", rpc, "--sig", "verify()"])
            manifest["deploymentStatus"] = "confirmed"
        for linked in result.get("libraries", []):
            name, address = linked.rsplit(":", 2)[-2:]
            manifest.setdefault("supportingContracts", {})[name] = address
        manifest["sourceVerification"] = False
        write_manifest(manifest)
        print(f"Confirmed {len(txs)} mined transactions; JSON updated: {DEPLOYMENT_FILE}")
    except Exception:
        if broadcast and (not broadcast_file.exists() or broadcast_file.stat().st_mtime < started_at):
            DEPLOYMENT_FILE.write_bytes(original)
        elif broadcast:
            # Partial deployments must never silently become a confirmed operational manifest.
            manifest = read_manifest()
            manifest["deploymentStatus"] = "pending"
            write_manifest(manifest)
        raise
    finally:
        if not broadcast:
            DEPLOYMENT_FILE.write_bytes(original)


def main():
    os.chdir(ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default=os.environ.get("TSV_RPC_URL", "https://xlayerrpc.okx.com"))
    parser.add_argument("--broadcast", action="store_true", help="send mainnet transactions; default is fork simulation")
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("deploy", "deploy-aa", "deploy-mock", "issue-sbt", "bootstrap", "verify", "smoke", "upgrade-all", "migrate-sbt"):
        sub.add_parser(name)
    p = sub.add_parser("prepare-aa"); p.add_argument("--aa-repo", required=True)
    p = sub.add_parser("fund-aa"); p.add_argument("underlying_raw"); p.add_argument("quote_raw")
    p = sub.add_parser("upgrade"); p.add_argument("component", choices=["registry", "ledger", "router", "lpManager", "hook"]); p.add_argument("--migration", default="0x")
    p = sub.add_parser("swap"); p.add_argument("direction", choices=["quote-to-underlying", "underlying-to-quote"]); p.add_argument("amount_in_raw"); p.add_argument("min_out_raw")
    p = sub.add_parser("add"); p.add_argument("underlying_max_raw"); p.add_argument("quote_max_raw"); p.add_argument("min_liquidity")
    p = sub.add_parser("collect"); p.add_argument("token_id")
    p = sub.add_parser("remove"); p.add_argument("token_id"); p.add_argument("amount0_min_raw"); p.add_argument("amount1_min_raw")
    args = parser.parse_args()
    if args.action == "prepare-aa":
        prepare_aa(args.aa_repo); return
    if args.action == "upgrade-all":
        for index, component in enumerate(["registry", "ledger", "router", "lpManager", "hook"]):
            execute("upgrade(uint8,bytes)", [str(index), "0x"], "upgrade", args.rpc_url, args.broadcast)
        return
    signatures = {"deploy": "deploy()", "deploy-aa": "deployAA()", "deploy-mock": "deployMock()", "migrate-sbt": "migrateSbt()", "issue-sbt": "issueSbt()", "bootstrap": "bootstrap()", "verify": "verify()", "smoke": "smoke()"}
    values = []
    if args.action == "fund-aa":
        sig = "fundAA(uint256,uint256)"; values = [args.underlying_raw, args.quote_raw]
    elif args.action == "upgrade":
        sig = "upgrade(uint8,bytes)"; values = [str(["registry", "ledger", "router", "lpManager", "hook"].index(args.component)), args.migration]
    elif args.action == "swap":
        sig = "swap(bool,uint128,uint128)"; values = [str(args.direction == "quote-to-underlying").lower(), args.amount_in_raw, args.min_out_raw]
    elif args.action == "add":
        sig = "addLiquidityAuto(uint128,uint128,uint128)"; values = [args.underlying_max_raw, args.quote_max_raw, args.min_liquidity]
    elif args.action == "collect":
        sig = "collect(uint256)"; values = [args.token_id]
    elif args.action == "remove":
        sig = "removeLiquidity(uint256,uint128,uint128)"; values = [args.token_id, args.amount0_min_raw, args.amount1_min_raw]
    else:
        sig = signatures[args.action]
    execute(sig, values, args.action, args.rpc_url, args.broadcast)

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
