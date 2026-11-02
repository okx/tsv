"""Resolve checkout-local Foundry remappings for the two fixed audit snapshots."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tomllib


def run(baseline: str) -> int:
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    snapshot = here.parent / 'baselines' / baseline
    config = tomllib.loads((root / 'foundry.toml').read_text())['profile']['default']
    remappings = []
    for item in config['remappings']:
        left, right = item.split('=', 1)
        if ':' in left:
            context, alias = left.split(':', 1)
            parent = snapshot if context.startswith('src/') else root
            left = str((parent / context).resolve()) + '/:' + alias
        target = snapshot / 'src/v1' if left == 'tsv-v1/' else root / right
        remappings.append(left + '=' + str(target.resolve()) + '/')
    os.environ['FOUNDRY_REMAPPINGS'] = json.dumps(remappings)
    os.environ['FOUNDRY_ALLOW_PATHS'] = json.dumps([
        str(root), str((root / 'dependencies').resolve()), str((root / 'lib/v4-periphery').resolve())
    ])
    return subprocess.run(['forge', 'test', '-vv', '--root', str(here / baseline)]).returncode


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', choices=['main', 'audit-fix'], required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.baseline))
