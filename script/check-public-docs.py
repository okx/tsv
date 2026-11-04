#!/usr/bin/env python3
"""Reject private web dependencies and missing repository links in public docs."""
from pathlib import Path
import configparser
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
errors = []
modules = configparser.ConfigParser()
modules.read(ROOT / ".gitmodules")
for section in modules.sections():
    url = modules.get(section, "url", fallback="")
    host = urlsplit(url).hostname or ""
    if not url.startswith("https://") or host == "okg.com" or host.endswith(".okg.com"):
        errors.append(f".gitmodules: {section}: dependency must use public HTTPS")
link = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
for name in sorted(set(paths)):
    if not name or name.startswith("lib/") or not name.endswith((".md", ".html")):
        continue
    path = ROOT / name
    if not path.is_file():
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for url in re.findall(r"https?://[^\s<>\"')]+", line):
            try:
                host = urlsplit(url).hostname or ""
            except ValueError:
                continue  # Documentation can contain bracketed URL placeholders.
            if host == "gitlab.okg.com" or host.endswith(".larksuite.com"):
                errors.append(f"{name}:{number}: private web reference")
        # Validate maintained documentation, not archived transaction reports or tool templates.
        if not (name == "README.md" or name.startswith(("docs/", "sdk/", ".agents/skills/xlayer-tsv-operator/"))):
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
print("Public documentation references valid.")
