#!/usr/bin/env python3
"""Regenerate or verify public ABI/layout snapshots from one complete build."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "docs/artifacts"
TARGETS = {
    "TSVRegistryV1": "src/v1/core/TSVRegistryV1.sol",
    "TSVVolumeLedgerV1": "src/v1/core/TSVVolumeLedgerV1.sol",
    "TSVHookV1": "src/v1/core/TSVHookV1.sol",
    "TSVSwapRouterV1": "src/v1/periphery/TSVSwapRouterV1.sol",
    "TSVLPManagerV1": "src/v1/periphery/TSVLPManagerV1.sol",
    "ITSVPermissionedRegistry": "src/v1/interfaces/ITSVPermissionedRegistry.sol",
    "PermissionedValidationLib": "src/v1/libraries/PermissionedValidationLib.sol",
}


def serialized(value):
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def stable_layout(value):
    """Keep slot/type information without compilation-unit-specific AST identifiers."""
    if isinstance(value, str):
        return re.sub(r"(t_(?:struct|enum|contract|userDefinedValueType)\([^()]*\))[0-9]+", r"\1", value)
    if isinstance(value, list):
        return [stable_layout(item) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == "astId":
                continue
            key, item = stable_layout(key), stable_layout(item)
            if key in result and result[key] != item:
                raise ValueError(f"Conflicting normalized storage types: {key}")
            result[key] = item
        return result
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    subprocess.run(["forge", "build"], cwd=ROOT, check=True)
    expected = {}
    for name, source in TARGETS.items():
        artifact = json.loads((ROOT / "out" / Path(source).name / (name + ".json")).read_text())
        if name != "PermissionedValidationLib":
            expected[name + ".abi.json"] = serialized(artifact["abi"])
        if name != "ITSVPermissionedRegistry":
            expected[name + ".storage-layout.json"] = serialized(stable_layout(artifact["storageLayout"]))
    config = tomllib.loads((ROOT / "foundry.toml").read_text())["profile"]["default"]
    expected["manifest.json"] = serialized({
        "format_version": 1,
        "compiler": {key: config[key] for key in ["solc_version", "evm_version", "optimizer", "optimizer_runs", "via_ir", "bytecode_hash"]},
        "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT / "src/v1").rglob("*.sol"))},
        "artifact_sha256": {name: hashlib.sha256(body.encode()).hexdigest() for name, body in expected.items()},
    })
    stale = []
    for name, body in expected.items():
        path = DEST / name
        if args.check:
            if not path.is_file() or path.read_text() != body:
                stale.append(name)
        else:
            path.write_text(body)
    if stale:
        raise SystemExit("Stale snapshots; run make artifacts: " + ", ".join(stale))
    print(f"{'Verified' if args.check else 'Generated'} {len(expected)} ABI/layout/manifest files.")


if __name__ == "__main__":
    main()
