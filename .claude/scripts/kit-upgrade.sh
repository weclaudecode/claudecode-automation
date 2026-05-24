#!/usr/bin/env bash
# kit-upgrade.sh — manifest+hash drift detector for an installed orchestrator
# kit, with atomic --apply.
#
# Background
# ----------
# The orchestrator kit gets copied into a target git repo (see the "Install
# into a repo" section of orchestrator-kit/README.md). Operators who later
# `cp` only the one file they think changed end up in partial-upgrade state —
# e.g. a new orchestrator.sh calling a helper that didn't get propagated into
# _dispatcher_lib.sh.
#
# This script compares a "kit-owned" file manifest between a source kit
# directory and the current git-root (the installed target). It reports
# drift; with --apply it atomically overwrites the drifted files in the
# target, then runs `shellcheck` + `bash -n` over the .sh surface and
# reverts if either fails.
#
# Usage
# -----
#   kit-upgrade.sh <kit-source-path>           # show drift, no changes
#   kit-upgrade.sh <kit-source-path> --apply   # apply changes atomically
#   kit-upgrade.sh --help
#
# Manifest scope (kit-owned)
#   - root: orchestrator.sh
#   - everything under .claude/{scripts,hooks,prompts,commands,docs}/
#
# Excluded (operator-owned or runtime)
#   - .claude/defaults.md, .claude/settings.json, CLAUDE.md
#   - .claude/plans/, .claude/state/, .claude/skills/ (recursive)
#
# Exit codes
#   0  no drift (or --apply succeeded)
#   1  drift detected (default mode) or --apply failed and was reverted
#   2  bad usage / missing source / not in a git repo

set -uo pipefail

# ---------------------------------------------------------------------------
# Help / usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
kit-upgrade.sh — detect and apply orchestrator-kit drift in an installed repo

Usage:
  kit-upgrade.sh <kit-source-path>             show drift, no changes
  kit-upgrade.sh <kit-source-path> --apply     apply changes atomically
  kit-upgrade.sh --help

The target is always the current git-root (`git rev-parse --show-toplevel`).
Run from inside the installed repo.

Exit codes:
  0  no drift / apply succeeded
  1  drift detected / apply failed and reverted
  2  bad usage / missing source / not in a git repo
USAGE
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

SOURCE_RAW="$1"
APPLY=0
if [ "$#" -ge 2 ]; then
  case "$2" in
    --apply) APPLY=1 ;;
    *)
      echo "kit-upgrade: unknown flag: $2" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Validate kit source
# ---------------------------------------------------------------------------

if [ ! -d "$SOURCE_RAW" ]; then
  echo "kit-upgrade: source not a directory: $SOURCE_RAW" >&2
  exit 2
fi

# Canonicalise to absolute path. `cd && pwd -P` works portably; we deliberately
# avoid `realpath` (not on stock macOS).
SOURCE="$(cd "$SOURCE_RAW" && pwd -P)"

if [ ! -f "$SOURCE/orchestrator.sh" ]; then
  echo "kit-upgrade: $SOURCE does not look like a kit source (no orchestrator.sh)" >&2
  exit 2
fi
if [ ! -d "$SOURCE/.claude/scripts" ]; then
  echo "kit-upgrade: $SOURCE does not look like a kit source (no .claude/scripts/)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Determine target (installed kit) = git root of cwd
# ---------------------------------------------------------------------------

TARGET="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$TARGET" ]; then
  echo "kit-upgrade: cwd is not inside a git repo — cannot determine target" >&2
  exit 2
fi

if [ "$SOURCE" = "$TARGET" ]; then
  echo "kit-upgrade: source and target are the same directory ($SOURCE)" >&2
  echo "  run from inside the installed repo, not from the kit source itself." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "kit-upgrade: required command not found: $1" >&2
    exit 2
  fi
}
need_cmd shasum

# ---------------------------------------------------------------------------
# Tempdir for atomic-apply snapshots; cleaned on EXIT
# ---------------------------------------------------------------------------

TMPDIR_BASE="$(mktemp -d -t kit-upgrade.XXXXXX)"
SNAPSHOT_DIR="$TMPDIR_BASE/snapshot"
mkdir -p "$SNAPSHOT_DIR"

cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Build manifest: walk kit-source for kit-owned files. Emit POSIX-relative
# paths (one per line) into $MANIFEST_FILE.
#
# Why dynamic walking rather than a static list: the kit gains files over
# time. A static list would silently miss new ones; walking the source
# guarantees the manifest tracks the kit's current shape.
# ---------------------------------------------------------------------------

MANIFEST_FILE="$TMPDIR_BASE/manifest.txt"
: > "$MANIFEST_FILE"

# Root file: orchestrator.sh (only).
if [ -f "$SOURCE/orchestrator.sh" ]; then
  echo "orchestrator.sh" >> "$MANIFEST_FILE"
fi

# Recursive walks under the kit-owned .claude/* subtrees.
KIT_DIRS=(
  ".claude/scripts"
  ".claude/hooks"
  ".claude/prompts"
  ".claude/commands"
  ".claude/docs"
)

# Exclude Python bytecode (__pycache__ trees, *.pyc) — runtime artefacts,
# not kit-owned. The same exclusion applies to the target-side EXTRA walk
# below; both sides must agree on what counts as kit-owned.
KIT_FIND_EXCLUDE=(
  -type d -name __pycache__ -prune -o
  -type f -not -name '*.pyc' -print0
)

for d in "${KIT_DIRS[@]}"; do
  if [ -d "$SOURCE/$d" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$SOURCE/"}"
      echo "$rel" >> "$MANIFEST_FILE"
    done < <(find "$SOURCE/$d" "${KIT_FIND_EXCLUDE[@]}")
  fi
done

# Stable order makes the output reproducible.
sort -u -o "$MANIFEST_FILE" "$MANIFEST_FILE"

MANIFEST_COUNT="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Hash + classify each manifest entry
#   IDENTICAL — same hash on both sides
#   DRIFT     — present on both sides, different hash
#   MISSING   — present in source, absent in target
#   ERROR     — hash failed for src or target (perms, vanished, segfault)
#
# Without an explicit ERROR row, an empty src_hash and empty tgt_hash
# would compare equal and silently report IDENTICAL — turning a real
# failure into a false-clean exit 0.
#
# Emits TSV: <classification>\t<relpath>
# ---------------------------------------------------------------------------

CLASSIFY_FILE="$TMPDIR_BASE/classify.tsv"
: > "$CLASSIFY_FILE"

hash_of() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src_path="$SOURCE/$rel"
  tgt_path="$TARGET/$rel"

  if [ ! -f "$tgt_path" ]; then
    printf 'MISSING\t%s\n' "$rel" >> "$CLASSIFY_FILE"
    continue
  fi

  src_hash="$(hash_of "$src_path")"
  tgt_hash="$(hash_of "$tgt_path")"

  if [ -z "$src_hash" ] || [ -z "$tgt_hash" ]; then
    printf 'ERROR\t%s\n' "$rel" >> "$CLASSIFY_FILE"
    continue
  fi

  if [ "$src_hash" = "$tgt_hash" ]; then
    printf 'IDENTICAL\t%s\n' "$rel" >> "$CLASSIFY_FILE"
  else
    printf 'DRIFT\t%s\n' "$rel" >> "$CLASSIFY_FILE"
  fi
done < "$MANIFEST_FILE"

# ---------------------------------------------------------------------------
# Detect EXTRA files: present in the target under one of the kit-owned dirs
# (or as root orchestrator.sh) but NOT in the source manifest. These are
# operator additions; we report them as "kept" and never delete.
# ---------------------------------------------------------------------------

EXTRA_FILE="$TMPDIR_BASE/extra.txt"
: > "$EXTRA_FILE"

# Build a set of "in-manifest" rels for quick lookup via grep -F -x.
# An empty manifest would make grep match everything, so guard.
manifest_contains() {
  if [ -s "$MANIFEST_FILE" ]; then
    grep -F -x -q -- "$1" "$MANIFEST_FILE"
  else
    return 1
  fi
}

# Root orchestrator.sh — only count it as EXTRA if it exists in target and
# *isn't* already in the manifest (in practice it always is, but stay correct).
if [ -f "$TARGET/orchestrator.sh" ] && ! manifest_contains "orchestrator.sh"; then
  echo "orchestrator.sh" >> "$EXTRA_FILE"
fi

for d in "${KIT_DIRS[@]}"; do
  if [ -d "$TARGET/$d" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$TARGET/"}"
      if ! manifest_contains "$rel"; then
        echo "$rel" >> "$EXTRA_FILE"
      fi
    done < <(find "$TARGET/$d" "${KIT_FIND_EXCLUDE[@]}")
  fi
done

sort -u -o "$EXTRA_FILE" "$EXTRA_FILE"

# ---------------------------------------------------------------------------
# Counts
# ---------------------------------------------------------------------------

count_class() {
  awk -v c="$1" -F '\t' '$1==c{n++} END{print n+0}' "$CLASSIFY_FILE"
}

N_IDENTICAL="$(count_class IDENTICAL)"
N_DRIFT="$(count_class DRIFT)"
N_MISSING="$(count_class MISSING)"
N_ERROR="$(count_class ERROR)"
N_EXTRA="$(wc -l < "$EXTRA_FILE" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

print_summary() {
  echo "kit-upgrade: source=$SOURCE  target=$TARGET"
  echo "manifest: $MANIFEST_COUNT kit-owned files"
  echo
  printf '   IDENTICAL: %d\n' "$N_IDENTICAL"
  printf '   DRIFT:     %d\n' "$N_DRIFT"
  printf '   MISSING:   %d\n' "$N_MISSING"
  printf '   ERROR:     %d\n' "$N_ERROR"
  printf '   EXTRA (kept in target): %d\n' "$N_EXTRA"
  echo
}

print_summary

# ERROR rows mean hashing failed for at least one entry; we cannot safely
# claim "no drift" because the comparison was inconclusive. Always abort
# loudly (even when DRIFT+MISSING is 0) and never proceed to --apply.
if [ "$N_ERROR" -gt 0 ]; then
  echo "kit-upgrade: hash failures (likely perms / file vanished mid-walk):" >&2
  awk -F '\t' '$1=="ERROR"{print "  "$2}' "$CLASSIFY_FILE" >&2
  exit 1
fi

NEED_UPGRADE=$((N_DRIFT + N_MISSING))

if [ "$NEED_UPGRADE" -eq 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    echo "kit-upgrade: nothing to do — target is already up to date."
  else
    echo "kit-upgrade: target is up to date."
  fi
  exit 0
fi

# List of drift+missing relpaths (for both default and --apply).
NEEDS_FILE="$TMPDIR_BASE/needs.txt"
awk -F '\t' '$1=="DRIFT" || $1=="MISSING" {print $0}' "$CLASSIFY_FILE" > "$NEEDS_FILE"

echo "files needing upgrade:"
while IFS=$'\t' read -r cls rel; do
  printf '  [%-7s] %s\n' "$cls" "$rel"
done < "$NEEDS_FILE"
echo

# ---------------------------------------------------------------------------
# Default mode: report-only, exit 1 to signal "upgrade needed".
# ---------------------------------------------------------------------------

if [ "$APPLY" -eq 0 ]; then
  echo "run with --apply to upgrade"
  exit 1
fi

# ---------------------------------------------------------------------------
# --apply mode
#
# Strategy (atomic-or-nothing):
#   1. Snapshot every target file we are about to write (if it exists).
#      For MISSING entries, record the relpath in a "deletions" list so
#      we can `rm` on revert.
#   2. Copy source -> target for every DRIFT / MISSING entry.
#   3. Run verifications:
#        bash -n  on every .sh file under target's .claude/scripts/ + hooks/
#        and the shellcheck linter (with CI exclusions) on the same set.
#      If either fails, revert from the snapshot and exit 1.
#   4. On success: print "applied N files; X identical; Y extra (kept)".
# ---------------------------------------------------------------------------

# Re-classify just before applying, in case of a race with another writer.
# Cheap (we already have everything in tempdir) but the manifest snapshot
# stays the same — we only need to re-hash.
RECHECK="$TMPDIR_BASE/classify-recheck.tsv"
: > "$RECHECK"
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src_path="$SOURCE/$rel"
  tgt_path="$TARGET/$rel"
  if [ ! -f "$tgt_path" ]; then
    printf 'MISSING\t%s\n' "$rel" >> "$RECHECK"
    continue
  fi
  recheck_src="$(hash_of "$src_path")"
  recheck_tgt="$(hash_of "$tgt_path")"
  # Same empty-hash guard as the primary classify loop — an empty == empty
  # comparison would silently dismiss a real DRIFT here too.
  if [ -z "$recheck_src" ] || [ -z "$recheck_tgt" ]; then
    printf 'ERROR\t%s\n' "$rel" >> "$RECHECK"
    continue
  fi
  if [ "$recheck_src" != "$recheck_tgt" ]; then
    printf 'DRIFT\t%s\n' "$rel" >> "$RECHECK"
  fi
done < "$MANIFEST_FILE"

if awk -F '\t' '$1=="ERROR"' "$RECHECK" | grep -q .; then
  echo "kit-upgrade: hash failures during re-check; refusing to --apply:" >&2
  awk -F '\t' '$1=="ERROR"{print "  "$2}' "$RECHECK" >&2
  exit 1
fi

NEEDS_RECHECK="$TMPDIR_BASE/needs-recheck.txt"
awk -F '\t' '$1=="DRIFT" || $1=="MISSING" {print $0}' "$RECHECK" > "$NEEDS_RECHECK"

if [ ! -s "$NEEDS_RECHECK" ]; then
  echo "kit-upgrade: re-check found nothing to upgrade (race with another writer?)."
  exit 0
fi

# Snapshot + collect to-apply list and to-delete-on-revert list.
DELETIONS_FILE="$TMPDIR_BASE/deletions.txt"
: > "$DELETIONS_FILE"
TO_APPLY="$TMPDIR_BASE/to-apply.txt"
: > "$TO_APPLY"

while IFS=$'\t' read -r cls rel; do
  [ -z "$rel" ] && continue
  src_path="$SOURCE/$rel"
  tgt_path="$TARGET/$rel"
  snap_path="$SNAPSHOT_DIR/$rel"

  mkdir -p "$(dirname "$snap_path")"
  if [ -f "$tgt_path" ]; then
    cp -p "$tgt_path" "$snap_path"
  else
    # MISSING — record so we can rm on revert.
    echo "$rel" >> "$DELETIONS_FILE"
  fi

  echo "$rel" >> "$TO_APPLY"
done < "$NEEDS_RECHECK"

# Revert helper. Restores all snapshotted files and removes any file we
# created (MISSING -> present).
revert_apply() {
  echo "kit-upgrade: reverting changes..." >&2
  # Restore snapshotted files
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    snap_path="$SNAPSHOT_DIR/$rel"
    tgt_path="$TARGET/$rel"
    if [ -f "$snap_path" ]; then
      cp -p "$snap_path" "$tgt_path"
    fi
  done < "$TO_APPLY"
  # Delete files we newly created
  if [ -s "$DELETIONS_FILE" ]; then
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      rm -f "$TARGET/$rel"
    done < "$DELETIONS_FILE"
  fi
}

# Perform the copies.
APPLIED=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src_path="$SOURCE/$rel"
  tgt_path="$TARGET/$rel"
  parent_dir="$(dirname "$tgt_path")"
  if ! mkdir -p "$parent_dir"; then
    echo "kit-upgrade: mkdir failed for $parent_dir (parent of $rel)" >&2
    revert_apply
    exit 1
  fi
  if ! cp -p "$src_path" "$tgt_path"; then
    echo "kit-upgrade: copy failed for $rel" >&2
    revert_apply
    exit 1
  fi
  APPLIED=$((APPLIED + 1))
done < "$TO_APPLY"

# ---------------------------------------------------------------------------
# Post-apply verification
#
# `bash -n` over every .sh under target/.claude/scripts/ and .claude/hooks/.
# The shellcheck linter runs on the same set with the CI exclusions defined
# in .github/workflows/ci.yml. Match CI's invocation as closely as possible
# so a green --apply implies a green CI run.
# ---------------------------------------------------------------------------

# Collect every .sh under the kit-shell surface.
SH_FILES_LIST="$TMPDIR_BASE/sh-files.txt"
: > "$SH_FILES_LIST"
for d in ".claude/scripts" ".claude/hooks"; do
  if [ -d "$TARGET/$d" ]; then
    find "$TARGET/$d" -type f -name "*.sh" -print >> "$SH_FILES_LIST"
  fi
done
# orchestrator.sh lives at the repo root; include it too.
if [ -f "$TARGET/orchestrator.sh" ]; then
  echo "$TARGET/orchestrator.sh" >> "$SH_FILES_LIST"
fi

verification_failed=0
verification_log="$TMPDIR_BASE/verification.log"
: > "$verification_log"

# bash -n on every script.
if [ -s "$SH_FILES_LIST" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! bash -n "$f" 2>>"$verification_log"; then
      echo "  bash -n FAILED on $f" >> "$verification_log"
      verification_failed=1
    fi
  done < "$SH_FILES_LIST"
fi

# Run the shellcheck linter, only if it's available (match CI semantics).
if command -v shellcheck >/dev/null 2>&1; then
  if [ -s "$SH_FILES_LIST" ]; then
    # CI invokes: shellcheck -S warning -e SC2164 -e SC2011 <files>
    # We feed filenames via xargs to avoid arg-list blowups.
    if ! xargs shellcheck -S warning -e SC2164 -e SC2011 \
        < "$SH_FILES_LIST" >>"$verification_log" 2>&1; then
      verification_failed=1
    fi
  fi
else
  echo "kit-upgrade: shellcheck not installed; skipping linter step." >&2
  echo "  install with: brew install shellcheck   (or apt-get install shellcheck)" >&2
fi

if [ "$verification_failed" -ne 0 ]; then
  echo "kit-upgrade: post-apply verification FAILED:" >&2
  sed 's/^/  /' "$verification_log" >&2
  revert_apply
  echo "kit-upgrade: target was reverted to pre-apply state." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Success
# ---------------------------------------------------------------------------

echo "kit-upgrade: applied $APPLIED files; $N_IDENTICAL identical; $N_EXTRA extra (kept)"
exit 0
