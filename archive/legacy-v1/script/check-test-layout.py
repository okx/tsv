#!/usr/bin/env python3
"""Reject shared fixtures containing tests and suites inheriting executable test suites."""

from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
test_root = root / "test"
sources = {path: path.read_text() for path in test_root.rglob("*.sol")}
test_contracts = set()
errors = []

for path, source in sources.items():
    if path.name.endswith(".t.sol"):
        contracts = list(re.finditer(r"\bcontract\s+(\w+)\s+is\s+([^\{]+)\{", source))
        for index, match in enumerate(contracts):
            end = contracts[index + 1].start() if index + 1 < len(contracts) else len(source)
            if re.search(r"\bfunction\s+(?:test\w*|invariant\w*)\s*\(", source[match.end():end]):
                test_contracts.add(match.group(1))
    if "helpers" in path.relative_to(test_root).parts and re.search(r"\bfunction\s+(?:test\w*|invariant\w*)\s*\(", source):
        errors.append(f"{path.relative_to(root)}: shared helpers must not contain executable tests")

for path, source in sources.items():
    for match in re.finditer(r"\bcontract\s+(\w+)\s+is\s+([^\{]+)\{", source):
        inherited = set(re.findall(r"\b\w+\b", match.group(2))) & test_contracts
        if inherited:
            errors.append(f"{path.relative_to(root)}: {match.group(1)} inherits executable suite {', '.join(sorted(inherited))}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

print(f"Test layout valid: {len(test_contracts)} suites; fixtures contain no tests; no suite inheritance.")
