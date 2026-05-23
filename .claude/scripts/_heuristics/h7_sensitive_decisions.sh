#!/usr/bin/env bash
# H7 heuristic: sensitive-decisions audit.
#
# Fires when .claude/state/decisions.md contains >= ORCH_MONITOR_H7_THRESHOLD
# entries marked **Severity:** sensitive scoped to the current plan's section.
# Workers in auto_recommended=true mode should not be making many sensitive
# decisions unattended — this surfaces plans that warrant a pre-merge audit.
#
# Hash: H7-PLAN${PLAN_NUM}  (one finding per plan; stable hash prevents
#       re-flooding the issue tracker on every sweep after threshold is hit).
#
# Env:
#   STATE_FILE                  — path to plan state.json (set by monitor-sweep.sh)
#   DECISIONS_FILE              — path to decisions.md (default: .claude/state/decisions.md)
#   ORCH_MONITOR_H7_THRESHOLD   — min sensitive entries before firing (default 3)

set -uo pipefail

_H7_DECISIONS_FILE="${DECISIONS_FILE:-.claude/state/decisions.md}"
_H7_THRESHOLD="${ORCH_MONITOR_H7_THRESHOLD:-3}"

_h7_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
_h7_pnum="${_h7_plan_file##*PLAN-}"
_h7_pnum="${_h7_pnum%%-*}"
_h7_pnum="${_h7_pnum:-00}"

# Parse decisions.md scoped to the current plan.
# Output: line 1 = count of sensitive entries; subsequent lines = decision excerpts.
_h7_result=$(python3 - "$_h7_pnum" "$_H7_DECISIONS_FILE" <<'PYEOF' 2>/dev/null || echo "0"
import sys, re

plan_num = sys.argv[1]
decisions_path = sys.argv[2]

sensitive = []
cur_header = None
cur_block = []

plan_pat = re.compile(r'— Plan ' + re.escape(plan_num) + r' Task')
sev_pat  = re.compile(r'\*\*Severity:\*\*\s+sensitive')
dec_pat  = re.compile(r'\*\*Decision:\*\*\s+(.*)')

def flush_block():
    if cur_header is None or not plan_pat.search(cur_header):
        return
    if not any(sev_pat.match(l.strip()) for l in cur_block):
        return
    for l in cur_block:
        m = dec_pat.match(l.strip())
        if m:
            sensitive.append(m.group(1)[:80])
            return
    sensitive.append("(no **Decision:** line found in block)")

try:
    with open(decisions_path) as f:
        for line in f:
            line = line.rstrip('\n')
            if re.match(r'^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}', line):
                flush_block()
                cur_header = line
                cur_block = []
            else:
                cur_block.append(line)
    flush_block()
except FileNotFoundError:
    pass

print(len(sensitive))
for d in sensitive:
    print(d)
PYEOF
)

_h7_count=$(printf '%s\n' "$_h7_result" | head -1)

if [ "${_h7_count:-0}" -ge "$_H7_THRESHOLD" ] 2>/dev/null; then
  _h7_hash="H7-PLAN${_h7_pnum}"
  _h7_decision_excerpt=$(printf '%s\n' "$_h7_result" | tail -n +2 | \
    while IFS= read -r _d; do printf '  - %s\n' "$_d"; done)

  _h7_body="**Plan:** ${_h7_plan_file}
**Sensitive decisions:** ${_h7_count} (threshold: ${_H7_THRESHOLD})

Workers in auto-resolve mode made an unusually high number of sensitive-severity
decisions without human approval. These warrant a pre-merge audit.

**Offending decisions:**
${_h7_decision_excerpt}

**Audit:** \`grep -A3 'Severity.*sensitive' .claude/state/decisions.md\`
**Operator action:** review each decision above, then remove this issue label
to acknowledge or address before merging the plan's PRs."

  monitor_finding "$_h7_hash" \
    "Plan ${_h7_pnum} has ${_h7_count} sensitive auto-decisions — audit before merge" \
    "$_h7_body"
fi
