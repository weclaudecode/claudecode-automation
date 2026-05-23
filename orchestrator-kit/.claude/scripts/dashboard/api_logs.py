"""/api/logs — tails .claude/state/orchestrator.log with range + filter params.

Parses tick/phase/level markers emitted by orchestrator.sh and the dispatcher
scripts so the frontend can render color-coded, timestamp-anchored log views.
"""

from __future__ import annotations

import glob
import re
from pathlib import Path

from flask import Blueprint, jsonify, request

from dashboard.app import json_envelope

bp = Blueprint("logs", __name__)

LOG_PATH = Path(".claude/state/orchestrator.log")
ROTATED_GLOB = ".claude/state/orchestrator.log.*"
# Hard cap on returned lines — protects browser + Flask process from a
# pathological `?lines=999999` request against a 10 MiB rotated log.
MAX_LINES = 2000
DEFAULT_LINES = 200

_TICK_RE = re.compile(r"^=== tick (\S+)")
# Matches rotation suffix: orchestrator.log.YYYYMMDDTHHMMSSZ
_ROTATED_SUFFIX_RE = re.compile(r"\.(\d{8}T\d{6}Z)$")


def _rotated_files() -> list[Path]:
    # Sort oldest-first by the timestamp suffix so concatenation preserves
    # chronological order; current log appended last by the caller.
    paths = []
    for p in glob.glob(ROTATED_GLOB):
        m = _ROTATED_SUFFIX_RE.search(p)
        if m:
            paths.append((m.group(1), Path(p)))
    paths.sort(key=lambda t: t[0])
    return [p for _, p in paths]


def _read_lines(include_rotated: bool) -> list[str]:
    files: list[Path] = []
    if include_rotated:
        files.extend(_rotated_files())
    if LOG_PATH.exists():
        files.append(LOG_PATH)
    out: list[str] = []
    for f in files:
        try:
            with f.open("r", encoding="utf-8", errors="replace") as fh:
                out.extend(line.rstrip("\n") for line in fh)
        except OSError:
            continue
    return out


def _classify(line: str) -> str:
    # Substring match matches the parse heuristic in the task spec; tick/phase
    # markers stay at "info" because the ts/boundary signal is what matters,
    # not a separate level.
    if "error:" in line:
        return "error"
    if "warning:" in line:
        return "warn"
    return "info"


def _parse(raw_lines: list[str]) -> list[dict]:
    current_ts: str | None = None
    parsed: list[dict] = []
    for line in raw_lines:
        m = _TICK_RE.match(line)
        if m:
            current_ts = m.group(1)
        parsed.append({"ts": current_ts, "level": _classify(line), "msg": line})
    return parsed


@bp.route("/api/logs")
def get_logs():
    try:
        lines_n = int(request.args.get("lines", DEFAULT_LINES))
    except ValueError:
        return jsonify(json_envelope(error="lines must be an integer"))

    if lines_n > MAX_LINES:
        return jsonify(
            json_envelope(error=f"too many lines requested (max {MAX_LINES})")
        )
    if lines_n < 0:
        lines_n = 0

    since = request.args.get("since")
    include_rotated = request.args.get("include_rotated") == "1"

    raw = _read_lines(include_rotated)
    parsed = _parse(raw)

    if since:
        # Only emit lines whose owning tick timestamp is >= since. ISO-8601
        # lexical compare works because tick markers are zulu (`...Z`).
        parsed = [p for p in parsed if p["ts"] is not None and p["ts"] >= since]

    tail = parsed[-lines_n:] if lines_n else []

    return jsonify(
        json_envelope(
            data={
                "lines": tail,
                "total_lines": len(tail),
                "since": since,
            }
        )
    )
