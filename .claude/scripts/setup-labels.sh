#!/usr/bin/env bash
# Seed the GitHub labels the orchestrator queries for task scheduling.
# Idempotent — `gh label create --force` upserts, so re-runs are safe.
#
# Usage: setup-labels.sh [<owner>/<repo>]
#   Default: current repo per `gh repo view`.
#
# Labels created:
#   orch:task           — marks any orchestrator-managed issue
#   orch:deps-met       — all depends_on issues closed; ready to schedule
#   orch:in-progress    — picked up by a worker tick
#   orch:review-blocked — reviewer agent posted change-requests; iterating
#   orch:safety-block   — reviewer found IAM/schema/secrets class issue
#   orch:needs-robbie   — sensitive-flagged at ingest; auto-merge disabled
#   agent-followup      — out-of-scope finding filed by a worker
#
# Per-plan labels (orch:plan-NN) are created by the ingest script at
# plan-ingestion time, not seeded here.

set -uo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"

if [ -z "$REPO" ]; then
  echo "FAIL: no repo specified and 'gh repo view' returned nothing" >&2
  echo "  run from inside a gh-tracked repo or pass <owner>/<repo>" >&2
  exit 1
fi

# Format: name|hex-color|description
LABELS=(
  "orch:task|0e8a16|Orchestrator-managed task issue"
  "orch:deps-met|c5def5|All depends_on issues closed; ready to schedule"
  "orch:in-progress|fbca04|Picked up by a worker tick"
  "orch:review-blocked|d73a4a|Reviewer posted change-requests; awaiting worker iteration"
  "orch:safety-block|b60205|Reviewer flagged IAM/schema/secrets/CORS class issue; needs human review"
  "orch:needs-robbie|f9d0c4|Sensitive-flagged at ingest; auto-merge disabled"
  "agent-followup|ededed|Out-of-scope finding filed by a worker; humans triage later"
)

echo "Seeding labels on $REPO..."
EXIT_CODE=0

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$entry"
  if gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" --force >/dev/null 2>&1; then
    echo "  ok: $name"
  else
    echo "  FAIL: $name" >&2
    EXIT_CODE=1
  fi
done

echo "Done."
exit "$EXIT_CODE"
