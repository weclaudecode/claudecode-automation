"""Usage endpoint + helpers — per-task token + cost rollup and today's spend.

Subscription-aware: on Claude Code Max plans the dollar number is
**notional** (what the tokens would cost on the metered pay-per-token API).
Tokens are the canonical unit a Max subscriber actually cares about
(rate-limit headroom, relative task complexity). This module exposes both:

  cost_for_task(plan, task)    → USD float (notional on Max)
  cost_today()                  → {today_usd, by_role, ...}
  tokens_for_task(plan, task)   → {input, output, cache_read, cache_write, total}
  tokens_today()                → {total, input, output, cache_read, cache_write, by_role}

The frontend (T5) decides which to feature; the data is here either way.
File name stays `api_costs.py` for spec/route stability; "cost" here
covers both tokens and the notional dollar view.

Source-of-truth note
--------------------
The spec (`orchestrator-kit/docs/SPEC-mission-centre.md`) asked for cost to
be computed by walking `.claude/state/run-<task>-r<retry>.json` files and
multiplying tokens by a hardcoded pricing table. After implementation
review, we deviate: the orchestrator's existing `update_task_usage` in
`_dispatcher_lib.sh` already persists per-run cost + token data into the
state file under `tasks[N].usage.runs[]` with `kind` (worker / iterator /
reviewer), `cost_usd`, ISO `run_at`, and full token breakdowns. Reading
the state file is strictly better:

  - Reviewer usage is captured here. `review-pr.sh` writes its
    `claude -p` output to a tmpfile that gets cleaned up via trap; the
    only persistent record of reviewer spend is the state file.
  - Worker, iterator, and reviewer usage are pre-aggregated and tagged
    with their role — no filename-pattern guessing.
  - `total_cost_usd` is taken from `claude -p`'s own output, which is
    canonical. Our pricing table is only needed as a fallback when an
    individual run is missing `cost_usd` (rare).

The pricing table below remains in-file as the documented fallback,
satisfying the PLAN-06 T2 acceptance criterion "pricing table is
hardcoded in-file with a snapshot date comment naming the source URL".

In-memory cache is keyed by `(state_file_path, mtime)` so a state file
write invalidates exactly that file's cache entry. Concurrency is
single-tick (Flask dev server is single-process); we do not lock.

Load-failure contract
---------------------
Per-file load failures (missing, unreadable, malformed JSON) do **not**
raise — `cost_today` / `tokens_today` aggregate across N state files and
one bad file must not abort the panel. But the failure is no longer
silent: `_load_state` emits a `log.warning` naming the path + exception
type AND appends the same message to a module-level error list. The
aggregation entry points (`cost_today`, `tokens_today`, the `/api/costs`
route) clear the list at the start of each call; `load_errors()` returns
the messages accumulated during the most recent call. `api_board.py`
folds these into `errors[]` on `/api/board` so the operator sees a
banner instead of silently-zeroed cost/token panels.
"""

from __future__ import annotations

import datetime as _dt
import glob
import json
import logging
import os
import threading
from pathlib import Path
from typing import Any

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("costs", __name__)
log = logging.getLogger("dashboard.costs")


# ── Pricing table ──────────────────────────────────────────────────────────
#
# Source: https://www.anthropic.com/pricing (snapshot 2026-05-26).
# Per-million-token rates in USD.
#
# Used ONLY as a fallback when an individual run object is missing
# `cost_usd`. The primary path reads `cost_usd` directly from the state
# file, which `update_task_usage` (in `_dispatcher_lib.sh`) populates
# from `claude -p`'s own `total_cost_usd` field.
#
# When Anthropic publishes a new price, update the values below and bump
# the snapshot date in this comment. Old runs already have their
# `cost_usd` frozen at the price they were charged at — only the
# fallback computation moves.

_PRICING_TABLE: dict[str, dict[str, float]] = {
    # Opus tier — premium reasoning model.
    "claude-opus-4-7":          {"input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_write": 18.75},
    "claude-opus-4-6":          {"input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_write": 18.75},
    # Sonnet tier — balanced.
    "claude-sonnet-4-6":        {"input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_write":  3.75},
    "claude-sonnet-4-5":        {"input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_write":  3.75},
    # Haiku tier — fast / cheap.
    "claude-haiku-4-5":         {"input":  1.00, "output":  5.00, "cache_read": 0.10, "cache_write":  1.25},
    "claude-haiku-4-5-20251001":{"input":  1.00, "output":  5.00, "cache_read": 0.10, "cache_write":  1.25},
}


def _compute_from_tokens(run: dict[str, Any]) -> float:
    """Fallback: derive USD from per-token counts + the pricing table.

    Used only when a run object's `cost_usd` is missing or zero AND the
    model is in the pricing table. Returns 0.0 if the model isn't
    recognised (rather than failing) so the caller can still report a
    partial total instead of erroring the whole panel.
    """
    model = run.get("model") or ""
    rates = _PRICING_TABLE.get(model)
    if not rates:
        return 0.0
    inp   = run.get("input_tokens", 0) or 0
    out   = run.get("output_tokens", 0) or 0
    cr    = run.get("cache_read_input_tokens", 0) or 0
    cw    = run.get("cache_creation_input_tokens", 0) or 0
    # Rates are per-million-tokens; convert by dividing by 1e6.
    return (
        inp * rates["input"]      / 1_000_000
        + out * rates["output"]     / 1_000_000
        + cr  * rates["cache_read"] / 1_000_000
        + cw  * rates["cache_write"]/ 1_000_000
    )


def _run_cost(run: dict[str, Any]) -> float:
    """Per-run USD: trust `cost_usd` first, fall back to pricing table."""
    c = run.get("cost_usd")
    if isinstance(c, (int, float)) and c > 0:
        return float(c)
    return _compute_from_tokens(run)


# ── State file loader with mtime cache ─────────────────────────────────────

# Cache entry: { mtime_ns: state_dict }
# A change in mtime invalidates the entry; we never bound the cache size
# because there are at most a few state files (active + archive). If
# that assumption ever changes, swap to functools.lru_cache.
_state_cache: dict[str, tuple[int, dict[str, Any]]] = {}

# Module-level error channel for the dashboard's /api/board composer.
# `_load_state` appends here on any failure; aggregation entry points
# (`cost_today`, `tokens_today`, `/api/costs`) call `_reset_load_errors`
# at the start of their work, then `load_errors()` returns the messages
# accumulated during that single aggregation pass.
#
# Guarded by a threading.Lock because Flask's dev server can serve
# concurrent requests on different threads (waitress / gunicorn in prod
# definitely will); without the lock, a poll mid-aggregation could see
# a partially-cleared or partially-appended list.
_load_errors_lock = threading.Lock()
_recent_load_errors: list[str] = []


def _record_load_error(msg: str) -> None:
    with _load_errors_lock:
        _recent_load_errors.append(msg)


def _reset_load_errors() -> None:
    with _load_errors_lock:
        _recent_load_errors.clear()


def load_errors() -> list[str]:
    """Return a copy of error messages from the most recent aggregation pass.

    Called by `api_board.py` after the board is built; each message is
    folded into the `errors[]` payload with `source: "api_costs"` so the
    operator sees a banner instead of a silently-zeroed cost panel.
    Returns a copy so callers can't mutate the live buffer.
    """
    with _load_errors_lock:
        return list(_recent_load_errors)


def _load_state(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Return parsed state.json, cached by mtime.

    Returns `{}` on any error (missing file, unreadable, malformed JSON)
    because callers aggregate across many files and one bad file must
    not abort the panel. Failures are logged via `log.warning` AND
    recorded in `_recent_load_errors` so `/api/board` can surface them.
    """
    p = str(path)
    try:
        mtime_ns = os.stat(p).st_mtime_ns
    except OSError as e:
        msg = f"{p}: {type(e).__name__}: {e}"
        log.warning("api_costs: state file stat failed: %s", msg)
        _record_load_error(msg)
        return {}

    hit = _state_cache.get(p)
    if hit is not None and hit[0] == mtime_ns:
        return hit[1]

    try:
        with open(p, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        msg = f"{p}: {type(e).__name__}: {e}"
        log.warning("api_costs: state file load failed: %s", msg)
        _record_load_error(msg)
        return {}

    _state_cache[p] = (mtime_ns, data)
    return data


def _state_file_paths() -> list[str]:
    """All state files: active under `.claude/plans/`, archived under `.claude/plans/archive/`."""
    return sorted(
        glob.glob(".claude/plans/*.state.json")
        + glob.glob(".claude/plans/archive/*.state.json")
    )


# ── Token accounting helpers ───────────────────────────────────────────────

_TOKEN_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
_TOKEN_OUT_KEYS = ("input", "output", "cache_read", "cache_write")  # display-friendly aliases
_TOKEN_RUN_TO_OUT = dict(zip(_TOKEN_KEYS, _TOKEN_OUT_KEYS))


def _run_tokens(run: dict[str, Any]) -> dict[str, int]:
    """Per-run token breakdown using display-friendly keys."""
    return {out_k: int(run.get(in_k, 0) or 0) for in_k, out_k in _TOKEN_RUN_TO_OUT.items()}


def _zero_tokens() -> dict[str, int]:
    return {k: 0 for k in _TOKEN_OUT_KEYS} | {"total": 0}


# ── Public helpers (also used by api_board.py in T4) ───────────────────────

def cost_for_task(plan: str, task: int) -> float:
    """Total USD spent on (plan, task) summing worker + iterator + reviewer runs.

    `plan` is the plan slug (e.g. "PLAN-06" or
    "PLAN-06-mission-centre"). Matching is by filename prefix so the
    short form is accepted. Returns 0.0 if no usage data exists.
    """
    matches = [
        p for p in _state_file_paths()
        if Path(p).stem.startswith(plan + "-") or Path(p).stem.startswith(plan + ".")
        or Path(p).stem == f"{plan}.state"
    ]
    total = 0.0
    for path in matches:
        runs = (
            _load_state(path)
            .get("tasks", {})
            .get(str(task), {})
            .get("usage", {})
            .get("runs", [])
        )
        total += sum(_run_cost(r) for r in runs if isinstance(r, dict))
    return round(total, 4)


def cost_today() -> dict[str, Any]:
    """Today's spend across all active + archived plans, broken down by role.

    Returns a dict with `today_usd`, `by_role`, `yesterday_usd`, and
    `this_week_usd`. Days are UTC. Returns `{}` if no state files exist
    or none contain any usage data.
    """
    _reset_load_errors()
    now = _dt.datetime.now(_dt.timezone.utc).date()
    yesterday = now - _dt.timedelta(days=1)
    week_start = now - _dt.timedelta(days=6)  # last 7 days including today

    today_usd = 0.0
    by_role: dict[str, float] = {"worker": 0.0, "iterator": 0.0, "reviewer": 0.0}
    yesterday_usd = 0.0
    week_usd = 0.0

    any_data = False

    for path in _state_file_paths():
        state = _load_state(path)
        for task in (state.get("tasks") or {}).values():
            for run in (task.get("usage") or {}).get("runs") or []:
                if not isinstance(run, dict):
                    continue
                any_data = True
                run_at = run.get("run_at") or ""
                try:
                    ts = _dt.datetime.fromisoformat(run_at.replace("Z", "+00:00")).date()
                except (TypeError, ValueError):
                    continue
                usd = _run_cost(run)
                if ts == now:
                    today_usd += usd
                    role = run.get("kind") or "worker"
                    if role in by_role:
                        by_role[role] += usd
                if ts == yesterday:
                    yesterday_usd += usd
                if ts >= week_start:
                    week_usd += usd

    if not any_data:
        return {}

    return {
        "today_usd": round(today_usd, 4),
        "by_role": {k: round(v, 4) for k, v in by_role.items()},
        "yesterday_usd": round(yesterday_usd, 4),
        "this_week_usd": round(week_usd, 4),
    }


def tokens_for_task(plan: str, task: int) -> dict[str, int]:
    """Total tokens consumed by (plan, task) across all runs.

    Returns `{input, output, cache_read, cache_write, total}`. Total is
    the sum of all four (the meaningful "this task burned N tokens"
    headline number, since each category is a distinct meter). Returns
    all-zero dict if no usage data.
    """
    matches = [
        p for p in _state_file_paths()
        if Path(p).stem.startswith(plan + "-") or Path(p).stem.startswith(plan + ".")
        or Path(p).stem == f"{plan}.state"
    ]
    tot = _zero_tokens()
    for path in matches:
        runs = (
            _load_state(path)
            .get("tasks", {})
            .get(str(task), {})
            .get("usage", {})
            .get("runs", [])
        )
        for r in runs:
            if not isinstance(r, dict):
                continue
            t = _run_tokens(r)
            for k in _TOKEN_OUT_KEYS:
                tot[k] += t[k]
    tot["total"] = sum(tot[k] for k in _TOKEN_OUT_KEYS)
    return tot


def tokens_today() -> dict[str, Any]:
    """Today's token consumption across all active + archived plans.

    Returns `{total, input, output, cache_read, cache_write, by_role,
    yesterday_total, this_week_total}` or `{}` if no usage data exists.
    Days are UTC. The Max-subscription-friendly headline number is
    `total` (sum of all four categories).
    """
    _reset_load_errors()
    now = _dt.datetime.now(_dt.timezone.utc).date()
    yesterday = now - _dt.timedelta(days=1)
    week_start = now - _dt.timedelta(days=6)

    today = _zero_tokens()
    by_role: dict[str, dict[str, int]] = {
        "worker":   _zero_tokens(),
        "iterator": _zero_tokens(),
        "reviewer": _zero_tokens(),
    }
    yesterday_total = 0
    week_total = 0
    any_data = False

    for path in _state_file_paths():
        state = _load_state(path)
        for task in (state.get("tasks") or {}).values():
            for run in (task.get("usage") or {}).get("runs") or []:
                if not isinstance(run, dict):
                    continue
                any_data = True
                run_at = run.get("run_at") or ""
                try:
                    ts = _dt.datetime.fromisoformat(run_at.replace("Z", "+00:00")).date()
                except (TypeError, ValueError):
                    continue
                t = _run_tokens(run)
                run_total = sum(t.values())
                if ts == now:
                    for k in _TOKEN_OUT_KEYS:
                        today[k] += t[k]
                    role = run.get("kind") or "worker"
                    if role in by_role:
                        for k in _TOKEN_OUT_KEYS:
                            by_role[role][k] += t[k]
                if ts == yesterday:
                    yesterday_total += run_total
                if ts >= week_start:
                    week_total += run_total

    if not any_data:
        return {}

    today["total"] = sum(today[k] for k in _TOKEN_OUT_KEYS)
    for role_dict in by_role.values():
        role_dict["total"] = sum(role_dict[k] for k in _TOKEN_OUT_KEYS)

    return {
        **today,
        "by_role": by_role,
        "yesterday_total": yesterday_total,
        "this_week_total": week_total,
    }


# ── Flask route ────────────────────────────────────────────────────────────

@bp.route("/api/costs")
def api_costs():
    """Today's usage (tokens + notional $) plus per-active-plan task breakdown.

    Single fetch powers:
      - Right-rail headline panel (tokens.total today, by_role)
      - Notional API-equivalent $ as secondary signal
      - Done-card token / $ badges

    Schema:
      {
        today_tokens: {input, output, cache_read, cache_write, total, by_role, ...}
        today_cost:   {today_usd, by_role, yesterday_usd, this_week_usd}
        per_task:     {<plan>: {<task>: {tokens: {...}, cost_usd: float}}}
      }
    """
    try:
        # Both helpers reset _recent_load_errors internally; calling
        # _reset_load_errors here too keeps the contract explicit at the
        # route level even if the helpers' reset behavior ever changes.
        _reset_load_errors()
        today_tokens = tokens_today()
        today_cost = cost_today()
        per_task: dict[str, dict[str, dict[str, Any]]] = {}
        for path in glob.glob(".claude/plans/*.state.json"):
            state = _load_state(path)
            plan = (state.get("plan_file") or Path(path).stem).split("/")[-1].removesuffix(".md").removesuffix(".state")
            try:
                plan_short = plan.split("-")[0] + "-" + plan.split("-")[1]
            except IndexError:
                continue
            tasks = state.get("tasks") or {}
            per_task[plan] = {}
            for task_id in tasks:
                try:
                    per_task[plan][task_id] = {
                        "tokens": tokens_for_task(plan_short, int(task_id)),
                        "cost_usd": cost_for_task(plan_short, int(task_id)),
                    }
                except (ValueError, IndexError):
                    continue
        return jsonify(json_envelope(data={
            "today_tokens": today_tokens,
            "today_cost": today_cost,
            "per_task": per_task,
        }))
    except Exception as e:  # noqa: BLE001 — best-effort endpoint
        return jsonify(json_envelope(error=f"api_costs: {type(e).__name__}: {e}"))
