#!/usr/bin/env bash
set -euo pipefail
audit_bundle=.audit-wS2ekY
audit_refs=.agents/skills/solidity-auditor/references
audit_ledger=${1:-$audit_bundle/memory-before.tsv}
awk -F'\t' '
FILENAME==ARGV[1] { nm[$1]=$2; next }
FNR==1 { next }
{
  split($1, p, "|")
  c = (p[1] in nm) ? nm[p[1]] : p[1]
  f = (p[2] in nm) ? nm[p[2]] : p[2]
  h = c "." f
  if (!(h in seen)) { seen[h]=1; ord[++n]=h }
  body[h] = body[h] "- `" p[3] "` — " $6 ", seen in " $3 ($3==1 ? " scan" : " scans") " — " $5 "\n"
}
END { for (i=1; i<=n; i++) printf "## %s\n\n%s\n", ord[i], body[ord[i]] }
' "$audit_bundle/source-names.tsv" "$audit_ledger" > "$audit_bundle/known-findings.body.md"
if [ -s "$audit_bundle/known-findings.body.md" ]; then
  sed -n '/^# Known findings — ground already walked$/,/^<body — one /p' .agents/skills/solidity-auditor/SKILL.md | sed '$d' > "$audit_bundle/known-findings.md"
  cat "$audit_bundle/known-findings.body.md" >> "$audit_bundle/known-findings.md"
else
  rm -f "$audit_bundle/known-findings.body.md" "$audit_bundle/known-findings.md"
fi
audit_specialties=(math-precision access-control economic-security execution-trace invariant periphery first-principles asymmetry boundary numerical-gap trust-gap flow-gap)
for audit_index in "${!audit_specialties[@]}"; do
  audit_number=$((audit_index + 1))
  audit_output="$audit_bundle/agent-$audit_number-bundle.md"
  cat "$audit_bundle/source.md" "$audit_refs/senior-auditor-sop.md" "$audit_refs/hacking-agents/${audit_specialties[$audit_index]}-agent.md" "$audit_refs/hacking-agents/shared-rules.md" "$audit_refs/report-language.md" > "$audit_output"
  if [ -s "$audit_bundle/known-findings.md" ]; then cat "$audit_bundle/known-findings.md" >> "$audit_output"; fi
done
python3 - <<'PY'
from pathlib import Path
import re
bundle = Path('.audit-wS2ekY')
templates = re.findall(r'```\n(You are an attacker\.[\s\S]*?)\n```', Path('.agents/skills/solidity-auditor/references/agent-prompts.md').read_text())
for number in range(1, 13):
    path = bundle / f'agent-{number}-bundle.md'
    lines = len(path.read_text().splitlines())
    prompt = templates[0 if number < 10 else 1]
    prompt = prompt.replace('{bundle_dir}', './.audit-wS2ekY').replace('agent-N-bundle.md', f'agent-{number}-bundle.md').replace('XXXX lines', f'{lines} lines')
    if not (bundle / 'known-findings.md').exists():
        prompt = re.sub(r'Your bundle ends with "Known findings[^\n]*\n(?:[^\n]*\n){3}\n', '', prompt)
    (bundle / f'agent-{number}-prompt.txt').write_text(prompt + '\n')
PY
wc -l "$audit_bundle/source.md" "$audit_bundle"/agent-*-bundle.md
