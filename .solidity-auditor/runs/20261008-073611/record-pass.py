import json
import re
import sys
from datetime import datetime
from pathlib import Path

number = int(sys.argv[1])
run_dir = Path('.solidity-auditor/runs/20261008-073611')
bundle = Path('.audit-wS2ekY')
data = json.loads((run_dir / f'gated-pass-{number}.json').read_text())
sha = (run_dir / 'source-commit.txt').read_text().strip()[:7]
failed = data.get('failed_agents', [])
returned = data.get('returned_agents', 12 - len(failed))
header = f'# Run {number} — solidity-auditor\n\n<!--RUN pass={number} of=3 stamp=20261008-073611 sha={sha} agents={returned}/12-->\n\n'
header += f'Pass {number} of 3 · {datetime.now().date()} · `{sha}` · {returned}/12 agents returned'
header += (' — ' + ', '.join(failed) + ' failed the tool content check.' if failed else '.') + '\n\n'
if data.get('coverage_note'):
    header += data['coverage_note'].strip() + '\n\n'
sections = {'FINDING': [], 'LEAD': []}
rows = []
keys = []
for item in data['items']:
    key = item['key']
    kind = item['kind']
    title = item['title']
    location = item['contract'] + '.' + item['function']
    agents = item['agents']
    if kind == 'FINDING':
        confidence = item['confidence']
        body = f'<!--F key={key} conf={confidence} kind=FINDING agents={agents}-->\n\n[{confidence}] **{title}**\n\n`{location}` · Confidence: {confidence}\n\n**Description**\n{item["description"]}\n'
        if item.get('fix_options') and confidence >= 75:
            for option in item['fix_options']:
                body += '\n**Fix (Option ' + option['label'] + ')**:\n\n```diff\n' + option['diff'].rstrip() + '\n```\n'
        elif item.get('fix_diff') and confidence >= 75:
            body += '\n**Fix**\n\n```diff\n' + item['fix_diff'].rstrip() + '\n```\n'
    else:
        body = f'<!--F key={key} kind=LEAD agents={agents}-->\n\n- **{title}** — `{location}` — Code smells: {item["code_smells"]} — {item["description"]}\n'
    body += '\n<!--/F-->\n'
    sections[kind].append(body)
    keys.append(key)
    title = re.sub(r'[\t\r\n]+', ' ', title)[:80]
    rows.append(f'{key}\t{sha}\t{title}\t{kind}\n')
(run_dir / f'run-{number}.md').write_text(header + '## Findings\n\n' + '\n'.join(sections['FINDING']) + '\n## Leads\n\n' + '\n'.join(sections['LEAD']))
with (bundle / 'scan-rows.tsv').open('a') as stream:
    stream.writelines(rows)
(bundle / 'run-keys.tsv').write_text('\n'.join(keys) + ('\n' if keys else ''))
print(f'{returned}/12 agents recorded; {len(sections["FINDING"])} findings; {len(sections["LEAD"])} leads.')
