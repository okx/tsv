#!/usr/bin/env python3
"""Check a local successful-MCP archive; does not query RPC or send transactions."""

import argparse
import hashlib
import json
from pathlib import Path


def load(path):
    return json.loads(path.read_text())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def responses(value):
    """Decode the MCP content text while retaining the original archive intact."""
    if isinstance(value, dict):
        if isinstance(value.get("data"), dict) and "task_status_name" in value["data"]:
            yield value
        for key, item in value.items():
            if key == "text" and isinstance(item, str):
                try:
                    yield from responses(json.loads(item))
                except json.JSONDecodeError:
                    pass
            elif isinstance(item, (dict, list)):
                yield from responses(item)
    elif isinstance(value, list):
        for item in value:
            yield from responses(item)


def validate(run):
    manifest = load(run / "manifest.json")
    records = manifest.get("transactions", manifest.get("deployments", []))
    require(records, "manifest has no successful deployments")
    indexed = {item["uuid"]: item for item in records}
    require(len(indexed) == len(records), "duplicate UUID in manifest")
    require(len({x["address"].lower() for x in records}) == len(records), "duplicate deployment address")
    chain_id = manifest.get("chainId", manifest.get("network", {}).get("chainId"))
    require(chain_id is not None, "missing chain ID")
    matched = set()
    for request_path in sorted(run.glob("batch-*/request.json")):
        request = load(request_path)
        require(request.get("deptName") == "Dex", f"{request_path}: missing Dex department")
        result_list = list(responses(load(request_path.parent / "status.json")))
        statuses = {x["data"]["uuid"]: x for x in result_list}
        request_ids = {x["uuid"] for x in request["tasks"]}
        require(len(request_ids) == len(request["tasks"]), f"{request_path}: duplicate task UUID")
        require(set(statuses) == request_ids, f"{request_path}: status UUIDs differ from request")
        for task in request["tasks"]:
            uuid = task["uuid"]
            require(uuid not in matched and uuid in indexed, f"{uuid}: unlisted/repeated task")
            matched.add(uuid)
            record = indexed[uuid]
            tx_hash = record.get("txHash", record.get("hash"))
            result = statuses[uuid]
            status = result["data"]
            require(result["code"] == 0, f"{uuid}: nonzero response code")
            require(status["task_status_name"] == "TASK_BROADCAST_SUCCESS_AND_TRANSACTION_SUCCESS", f"{uuid}: not successful")
            require(status["tx_hash"].lower() == tx_hash.lower(), f"{uuid}: status hash mismatch")
            chain = load(run / "transactions" / f"{tx_hash}.json")
            tx, receipt = chain["transaction"], chain["receipt"]
            require(number(receipt["status"]) == 1, f"{uuid}: failed receipt")
            require(tx["to"] is None, f"{uuid}: not EOA CREATE")
            require(tx["input"].lower() == task["calldata"].lower(), f"{uuid}: input differs from submitted calldata")
            require(tx["from"].lower() == task["privilege_address"].lower(), f"{uuid}: sender mismatch")
            require(number(tx["chainId"]) == number(task["chain_id"]) == number(chain_id) == number(status["chain_id"]), f"{uuid}: wrong chain")
            require(tx["hash"].lower() == receipt["transactionHash"].lower() == tx_hash.lower(), f"{uuid}: receipt hash mismatch")
            require(receipt["contractAddress"].lower() == record["address"].lower(), f"{uuid}: address mismatch")
            require(number(receipt["blockNumber"]) == number(record["block"]), f"{uuid}: block mismatch")
            require(number(tx["value"]) == number(task.get("value", "0")), f"{uuid}: value mismatch")
    require(matched == set(indexed), "manifest deployments missing from submitted batches")
    hashes = load(run / "SHA256SUMS.json")
    actual = {str(p.relative_to(run)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in run.rglob("*") if p.is_file() and p.name != "SHA256SUMS.json"}
    require(hashes == actual, "SHA256SUMS.json does not match archive contents")
    return {"run": str(run), "successfulDeployments": len(matched), "hashedFiles": len(actual)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.run), ensure_ascii=False))
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(1, f"Invalid deployment archive: {error}\n")


if __name__ == "__main__":
    main()
