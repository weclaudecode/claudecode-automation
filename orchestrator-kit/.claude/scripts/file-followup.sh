#!/usr/bin/env bash
# File a deduplicated `agent-followup` GitHub issue.
#
# Workers spawned by the orchestrator (see worker-superpower.md) call this
# instead of raw `gh issue create` so that retries of the same task don't
# spam the issue tracker with functional duplicates. The propscan-au PLAN-01
# task 9 retries that filed propscan-au#19 and #21 for the same edge case
# are the motivating example — see issue #7 on weclaudecode/claudecode-automation.
#
# Usage:
#   file-followup.sh [--dry-run] [--repo <owner/repo>] <title> <body>
#
# Behaviour:
#   - Computes a stable hash from the normalised title (lowercased, all
#     whitespace runs collapsed to a single space, leading/trailing trim);
#     first 16 hex chars of sha256.
#   - Searches existing open issues labelled `agent-followup` for a body
#     containing `<!-- followup-hash: <hash> -->`.
#   - If a match is found: posts a timestamp comment on the existing issue,
#     echoes that issue's URL, exits 0.
#   - If no match: files a new issue with the hash embedded as an HTML
#     comment in the footer, echoes the new URL, exits 0.
#   - Failures (gh non-zero, network, missing label, etc.): logs to stderr
#     prefixed with `file-followup:` and exits 1. The caller (worker) should
#     treat this as "couldn't file follow-up; continue with primary task"
#     and surface the failure in its summary JSON `followup_issues_filed`.
#
# Flags:
#   --dry-run        Print what would happen; never invoke `gh` for writes.
#                    (Reads — repo detection, dedup search — are skipped too;
#                    we just echo intent so this is safe in CI/tests.)
#   --repo <slug>    Override auto-detected repo. Useful for testing against
#                    a fixture repo from outside its working tree.
#
# Conventions: matches the kit style (set -uo pipefail, not -e), takes its
# concurrency cues from notify.sh, and treats gh failures as soft like the
# orchestrator hooks do.

set -uo pipefail

DRY_RUN=0
REPO_OVERRIDE=""

# Parse leading flags before the positional title/body.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --repo)
      if [ "$#" -lt 2 ]; then
        echo "file-followup: --repo requires an argument" >&2
        exit 1
      fi
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --repo=*)
      REPO_OVERRIDE="${1#--repo=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "file-followup: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -lt 2 ]; then
  echo "file-followup: usage: $0 [--dry-run] [--repo <owner/repo>] <title> <body>" >&2
  exit 1
fi

TITLE="$1"
BODY="$2"

if [ -z "$TITLE" ]; then
  echo "file-followup: title must not be empty" >&2
  exit 1
fi

# --- Normalise + hash the title ---------------------------------------------
# Lowercase, collapse any whitespace run (spaces, tabs, newlines) into a single
# space, then trim leading/trailing. Designed so cosmetic re-wordings ("Fix
# bug" vs "  fix   bug ") collide on the same hash.
normalize_title() {
  # tr-based pipeline keeps this portable across BSD/GNU.
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '\t\n\r' '   ' \
    | tr -s ' ' \
    | sed -e 's/^ //' -e 's/ $//'
}

NORMALIZED_TITLE=$(normalize_title "$TITLE")
HASH=$(printf '%s' "$NORMALIZED_TITLE" | shasum -a 256 | head -c 16)

if [ -z "$HASH" ]; then
  echo "file-followup: failed to compute hash (shasum not available?)" >&2
  exit 1
fi

# --- Resolve repo -----------------------------------------------------------
# Cached for the life of this script — `gh repo view` is the one call we want
# to make exactly once even if we end up doing both a search and a create.
resolve_repo() {
  if [ -n "$REPO_OVERRIDE" ]; then
    echo "$REPO_OVERRIDE"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "file-followup: gh CLI not found on PATH" >&2
    return 1
  fi
  local slug
  if ! slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
    echo "file-followup: gh repo view failed (not in a gh-aware repo?)" >&2
    return 1
  fi
  if [ -z "$slug" ]; then
    echo "file-followup: gh repo view returned empty slug" >&2
    return 1
  fi
  echo "$slug"
}

# --- Dry-run short-circuit --------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  REPO_DISPLAY="${REPO_OVERRIDE:-<auto-detect>}"
  echo "file-followup: DRY RUN"
  echo "  repo=$REPO_DISPLAY"
  echo "  title=$TITLE"
  echo "  normalized_title=$NORMALIZED_TITLE"
  echo "  hash=$HASH"
  echo "  would search: gh issue list --repo $REPO_DISPLAY --label agent-followup --state open --search 'in:body followup-hash:$HASH' --json number,url,title --limit 5"
  echo "  on match: gh issue comment <N> --repo $REPO_DISPLAY --body '<timestamp re-encountered note>'"
  echo "  on miss:  gh issue create --repo $REPO_DISPLAY --label agent-followup --title <title> --body <body + hash marker>"
  exit 0
fi

REPO=$(resolve_repo) || exit 1

# --- Search for existing match ----------------------------------------------
# `--search "in:body followup-hash:<hash>"` matches the HTML comment we
# embed on creation. We grep the JSON output for the marker to defend against
# search-index lag (newly-filed issues sometimes take a beat to index).
SEARCH_JSON=""
if ! SEARCH_JSON=$(gh issue list \
      --repo "$REPO" \
      --label agent-followup \
      --state open \
      --search "in:body followup-hash:$HASH" \
      --json number,url,title,body \
      --limit 5 \
      2>/dev/null); then
  echo "file-followup: gh issue list failed (network/auth/label-missing?)" >&2
  exit 1
fi

EXISTING_URL=""
EXISTING_NUM=""
if [ -n "$SEARCH_JSON" ] && [ "$SEARCH_JSON" != "[]" ]; then
  # jq filters to the first hit whose body actually contains the marker.
  # The --search clause is fuzzy; the marker check is exact.
  EXISTING_URL=$(printf '%s' "$SEARCH_JSON" \
    | jq -r --arg h "$HASH" \
        '[.[] | select(.body | contains("followup-hash: " + $h))] | .[0].url // ""' \
    2>/dev/null || echo "")
  EXISTING_NUM=$(printf '%s' "$SEARCH_JSON" \
    | jq -r --arg h "$HASH" \
        '[.[] | select(.body | contains("followup-hash: " + $h))] | .[0].number // ""' \
    2>/dev/null || echo "")
fi

# --- Match: comment on existing issue ---------------------------------------
if [ -n "$EXISTING_URL" ] && [ -n "$EXISTING_NUM" ]; then
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! gh issue comment "$EXISTING_NUM" \
        --repo "$REPO" \
        --body "Re-encountered at $TS — worker may need to be re-run." \
        >/dev/null 2>&1; then
    echo "file-followup: failed to comment on existing issue #$EXISTING_NUM" >&2
    exit 1
  fi
  echo "$EXISTING_URL"
  exit 0
fi

# --- No match: file new issue -----------------------------------------------
# The hash marker goes in an HTML comment so it doesn't render in the issue
# body but is still found by the `in:body` GitHub search.
FULL_BODY="$BODY

<!-- followup-hash: $HASH -->"

NEW_URL=""
if ! NEW_URL=$(gh issue create \
      --repo "$REPO" \
      --label agent-followup \
      --title "$TITLE" \
      --body "$FULL_BODY" \
      2>/dev/null); then
  echo "file-followup: gh issue create failed" >&2
  exit 1
fi

if [ -z "$NEW_URL" ]; then
  echo "file-followup: gh issue create returned empty URL" >&2
  exit 1
fi

echo "$NEW_URL"
exit 0
