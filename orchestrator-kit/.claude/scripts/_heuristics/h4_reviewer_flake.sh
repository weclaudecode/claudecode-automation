#!/usr/bin/env bash
# H4 heuristic: reviewer-flake detector.
#
# Fires when a PR's HEAD SHA has been reviewed ≥3 times with ≥2 distinct
# verdicts (e.g. CHANGES_REQUESTED → APPROVED → CHANGES_REQUESTED), which
# suggests the reviewer prompt is under-specified and the automated reviewer
# is oscillating rather than converging.
#
# Hash: H4-PR${pr}-SHA${short_sha}
# Body: the reviews on the offending SHA, suggestion to disambiguate the prompt.
#
# ── Stub-hook pattern for testing ─────────────────────────────────────────────
# If STATE_FILE contains ._test_reviews_fixture (JSON object keyed by PR number),
# the heuristic reads reviews from that field instead of calling `gh api`.
# Shape:
#   ._test_reviews_fixture["<pr_number>"] = [
#     { "commit_id": "<sha>", "state": "CHANGES_REQUESTED" | "APPROVED" | ... },
#     ...
#   ]
# Future heuristics that call gh api should use this same pattern.
# ──────────────────────────────────────────────────────────────────────────────
#
# Env:
#   STATE_FILE  — path to plan state.json (set by monitor-sweep.sh)
#   REPO        — owner/repo string (not needed in test mode)

set -uo pipefail

while IFS= read -r _h4_entry; do
  _h4_task_num=$(jq -r '.key' <<< "$_h4_entry")
  _h4_pr=$(jq -r '.value.pr' <<< "$_h4_entry")

  # Resolve reviews — use _test_reviews_fixture when present (offline test stub).
  if jq -e '._test_reviews_fixture' "$STATE_FILE" >/dev/null 2>&1; then
    _h4_reviews=$(jq -c --arg pr "$_h4_pr" '._test_reviews_fixture[$pr] // []' "$STATE_FILE")
  else
    # gh api --paginate collects all pages into one JSON array.
    _h4_reviews=$(gh api --paginate \
      "repos/${REPO}/pulls/${_h4_pr}/reviews" 2>/dev/null || echo "[]")
  fi

  [ -n "$_h4_reviews" ] && [ "$_h4_reviews" != "null" ] && [ "$_h4_reviews" != "[]" ] || continue

  # Find first commit_id with ≥3 reviews AND ≥2 distinct verdict states.
  _h4_offender=$(python3 - "$_h4_reviews" <<'PYEOF' 2>/dev/null || echo ""
import sys, json, collections

reviews = json.loads(sys.argv[1])
by_sha = collections.defaultdict(list)
for r in reviews:
    sha = r.get("commit_id", "")
    state = r.get("state", "")
    if sha and state:
        by_sha[sha].append(state)

for sha, states in by_sha.items():
    if len(states) >= 3 and len(set(states)) >= 2:
        print(sha)
        break
PYEOF
)

  [ -n "$_h4_offender" ] || continue

  _h4_short_sha="${_h4_offender:0:7}"
  _h4_hash="H4-PR${_h4_pr}-SHA${_h4_short_sha}"

  _h4_verdict_list=$(python3 - "$_h4_reviews" "$_h4_offender" <<'PYEOF' 2>/dev/null || echo ""
import sys, json

reviews = json.loads(sys.argv[1])
sha = sys.argv[2]
for r in reviews:
    if r.get("commit_id") == sha:
        print("  " + r.get("state", "?"))
PYEOF
)

  _h4_plan_file=$(jq -r '.plan_file' "$STATE_FILE")
  _h4_pr_url="https://github.com/${REPO:-<repo>}/pull/${_h4_pr}"
  _h4_body="**PR:** ${_h4_pr_url}
**Task:** ${_h4_task_num}
**Plan:** ${_h4_plan_file}
**Flaky SHA:** ${_h4_short_sha} (${_h4_offender})
**Reviews on this SHA:**
${_h4_verdict_list:-  <none parsed>}

The same commit has been reviewed ≥3 times with alternating verdicts.
This typically means the reviewer prompt is under-specified, causing the
automated reviewer to oscillate between APPROVE and CHANGES_REQUESTED.

**Fix:** Review the reviewer prompt in \`.claude/prompts/\` for ambiguous
acceptance criteria, then re-trigger the review with \`SKIP_REVIEW=\` unset."

  monitor_finding "$_h4_hash" \
    "PR #${_h4_pr} reviewer flake on SHA ${_h4_short_sha}: ≥3 alternating verdicts" \
    "$_h4_body"
done < <(jq -c \
  '.tasks | to_entries[] | select(.value.status == "in_review" and .value.pr != null)' \
  "$STATE_FILE")
