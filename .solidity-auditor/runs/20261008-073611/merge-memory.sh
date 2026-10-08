#!/usr/bin/env bash
set -euo pipefail
audit_pass=$1
audit_bundle=.audit-wS2ekY
audit_run=.solidity-auditor/runs/20261008-073611
awk -F'\t' -v OFS='\t' '
FILENAME==ARGV[1] {
  if (FNR==1) next
  o_st[$1]=$2; o_sc[$1]=$3; o_sha[$1]=$4; o_ti[$1]=$5; o_ki[$1]=$6
  if (!($1 in o_seen)) { o_seen[$1]=1; oord[++on]=$1 }
  next
}
{
  if (!($1 in n_seen)) { n_seen[$1]=1; nord[++nn]=$1 }
  n_sha[$1]=$2; n_ti[$1]=$3; n_ki[$1]=$4
}
END {
  print "#solidity-auditor-memory v1", "key", "status", "scans", "sha", "title", "kind"
  for (i=1; i<=on; i++) {
    k = oord[i]
    if (k in n_seen) print k, "KNOWN", o_sc[k]+1, n_sha[k], n_ti[k], n_ki[k]
    else print k, o_st[k], o_sc[k], o_sha[k], o_ti[k], o_ki[k]
  }
  for (i=1; i<=nn; i++) {
    k = nord[i]
    if (!(k in o_seen)) print k, "NEW", 1, n_sha[k], n_ti[k], n_ki[k]
  }
}
' "$audit_bundle/memory-before.tsv" "$audit_bundle/scan-rows.tsv" > .solidity-auditor/memory.tsv.tmp
mv .solidity-auditor/memory.tsv.tmp .solidity-auditor/memory.tsv
printf '%s\t%s\n' mem_after "$(( $(wc -l < .solidity-auditor/memory.tsv) - 1 ))" >> "$audit_run/scope.tsv"
printf '%s\t%s\n' mem_sha "$(cut -c1-7 "$audit_run/source-commit.txt")" >> "$audit_run/scope.tsv"
printf '%s\t%s\n' "pass_${audit_pass}_agents" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("returned_agents",12-len(d.get("failed_agents", []))))+"/12")' "$audit_run/gated-pass-${audit_pass}.json")" >> "$audit_run/scope.tsv"
