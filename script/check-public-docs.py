#!/usr/bin/env python3
"""Check the public tree, first-party document links and dependency URLs."""
from pathlib import Path
import configparser
import fnmatch
import json
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
# These are complete upstream dependencies, not TSV-authored documentation.
VENDORED = ("lib/v4-core/", "lib/v4-periphery/", "lib/TestToken/backed-token-contract/", "lib/TestToken/securitize-dstoken/")
OPERATIONS_ONLY = [line.strip() for line in (ROOT / "script/operations-only-paths.txt").read_text().splitlines()
                   if line.strip() and not line.startswith("#")]
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
errors = []
modules = configparser.ConfigParser()
modules.read(ROOT / ".gitmodules")
for section in modules.sections():
    url = modules.get(section, "url", fallback="")
    host = urlsplit(url).hostname or ""
    if not url.startswith("https://") or host == "okg.com" or host.endswith(".okg.com"):
        errors.append(f".gitmodules: {section}: dependency must use public HTTPS")
# Public catalogs must not retain local links to files moved into the operations archive.
for catalog in (ROOT / "deployment").glob("*/addresses.json"):
    for source in json.loads(catalog.read_text()).get("sources", []):
        if not (catalog.parent / source).is_file():
            errors.append(f"{catalog.relative_to(ROOT)}: missing local source {source}")
link = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
for name in sorted(set(paths)):
    if not name:
        continue
    path = ROOT / name
    if not path.is_file():
        continue  # Staged deletions and gitlinks have no document body.
    if any(name == pattern or name.startswith(pattern + "/") or fnmatch.fnmatchcase(name, pattern)
           for pattern in OPERATIONS_ONLY):
        errors.append(f"{name}: operations-only content must stay on ops/deployment")
    if name.startswith(VENDORED) or path.suffix not in (".md", ".html", ".svg"):
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for url in re.findall(r"https?://[^\s<>\"')]+", line):
            try:
                host = urlsplit(url).hostname or ""
            except ValueError:
                continue  # Bracketed URL placeholders can occur in examples.
            if host == "okg.com" or host.endswith((".okg.com", ".larksuite.com", ".feishu.cn", ".larkoffice.com")):
                errors.append(f"{name}:{number}: private web reference")
        if path.suffix != ".md":
            continue
        for target in link.findall(line):
            target = target.split()[0].strip("<>")
            if urlsplit(target).scheme or target.startswith(("#", "/")):
                continue
            target = unquote(target.split("#", 1)[0])
            if target and not (path.parent / target).exists():
                errors.append(f"{name}:{number}: missing relative target {target}")
if errors:
    raise SystemExit("\n".join(errors))
print("Public tree and first-party documentation references valid.")
