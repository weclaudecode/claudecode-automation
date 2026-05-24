"""GET /api/bedrock — Bedrock InvokeModel spend tile.

Returns month-to-date Bedrock spend (USD), a 14-day daily series for the
sparkline, an optional projected month-end figure, and a status field that
the frontend uses to render "n/a" gracefully when AWS isn't available.

Data source: ``aws ce get-cost-and-usage`` filtered by service
"Amazon Bedrock". Cache: ``.claude/state/dashboard-bedrock-cache.json``
with a configurable TTL (default 10 minutes).

Degradation contract:

- aws CLI absent  → status="aws_missing"
- No credentials  → status="no_credentials"
- CE access denied → status="ce_denied"
- No plan has aws_env → status="no_aws_env"
- Any other error   → status="error", detail carries the reason

In every n/a case ``data.month_to_date_usd`` is None and the tile renders
"n/a" with a one-line explanation.  The route never raises — a broad
exception is caught, logged, and collapsed to an error-status tile.
"""

from __future__ import annotations

import datetime as _dt
import glob
import json
import logging
import os
import subprocess
import threading
import time
from pathlib import Path

from flask import Blueprint, jsonify

from dashboard.app import json_envelope

bp = Blueprint("bedrock", __name__)
log = logging.getLogger("dashboard.bedrock")

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

_CACHE_TTL_SECONDS = int(os.environ.get("ORCH_BEDROCK_CACHE_TTL_S", "600"))
_AWS_TIMEOUT_SECONDS = 20
_DAYS_HISTORY = 14

_CACHE_FILE = Path(".claude/state/dashboard-bedrock-cache.json")
_PLANS_GLOB = ".claude/plans/*.state.json"

# ---------------------------------------------------------------------------
# Cache (one lock; the AWS call can take several seconds)
# ---------------------------------------------------------------------------

_cache_lock = threading.Lock()
_cache: tuple[float, dict] | None = None  # (monotonic, payload)


# ---------------------------------------------------------------------------
# Helpers: plan state lookup
# ---------------------------------------------------------------------------

def _find_aws_account() -> tuple[str | None, str | None]:
    """Return (account_id, error_message).

    Scans all in_progress state files for the first one with aws_env.account.
    Returns (None, reason) when none is found.
    """
    plans = glob.glob(_PLANS_GLOB)
    if not plans:
        return None, "no plans found"

    in_progress: list[tuple[float, Path]] = []
    for p in plans:
        path = Path(p)
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if doc.get("status") == "in_progress":
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            in_progress.append((mtime, path))

    in_progress.sort(key=lambda t: t[0], reverse=True)

    for _mtime, path in in_progress:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        account = (doc.get("aws_env") or {}).get("account")
        if account:
            return str(account), None

    if in_progress:
        return None, "no active plan has aws_env.account"
    return None, "no active plan with aws_env"


# ---------------------------------------------------------------------------
# Date helpers (portable: works on macOS BSD date + python3 fallback)
# ---------------------------------------------------------------------------

def _date_range() -> tuple[str, str]:
    """Return (start, end) where start is 14 days ago and end is tomorrow.

    AWS CE end-date is exclusive, so we pass tomorrow to include today.
    """
    today = _dt.date.today()
    start = today - _dt.timedelta(days=_DAYS_HISTORY)
    end = today + _dt.timedelta(days=1)
    return start.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d")


def _month_start() -> str:
    today = _dt.date.today()
    return today.strftime("%Y-%m-01")


def _days_in_month() -> int:
    import calendar
    today = _dt.date.today()
    return calendar.monthrange(today.year, today.month)[1]


def _day_of_month() -> int:
    return _dt.date.today().day


# ---------------------------------------------------------------------------
# AWS Cost Explorer fetch
# ---------------------------------------------------------------------------

def _run_aws(args: list[str]) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            ["aws", *args],
            capture_output=True,
            text=True,
            timeout=_AWS_TIMEOUT_SECONDS,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return -1, "", "aws CLI not found"
    except subprocess.TimeoutExpired:
        return -2, "", f"aws timed out after {_AWS_TIMEOUT_SECONDS}s"


def _classify_error(stderr: str) -> str:
    """Map a CE stderr to a status code."""
    s = stderr.lower()
    if "accessdenied" in s or "unauthorized" in s or "is not authorized" in s:
        return "ce_denied"
    if (
        "unable to locate credentials" in s
        or "no credentials" in s
        or "credentialsnotfound" in s
        or "invalidclienttokenid" in s
        or "expiredtoken" in s
        or "tokenrefresherror" in s
    ):
        return "no_credentials"
    return "error"


def _fetch_bedrock_spend() -> dict:
    """Fetch from AWS CE and return a payload dict.

    Always returns a dict; never raises. On any failure the dict has
    ``status != "ok"`` and ``month_to_date_usd == None``.
    """
    # 1. Locate account from plan state.
    account, why = _find_aws_account()
    if account is None:
        return {
            "status": "no_aws_env",
            "detail": why or "no plan with aws_env",
            "month_to_date_usd": None,
            "projected_usd": None,
            "daily_series": [],
            "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }

    # 2. Check aws CLI.
    rc, _out, _err = _run_aws(["--version"])
    if rc == -1:
        return {
            "status": "aws_missing",
            "detail": "aws CLI not installed",
            "month_to_date_usd": None,
            "projected_usd": None,
            "daily_series": [],
            "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }

    # 3. Fetch 14-day daily Bedrock spend.
    start, end = _date_range()
    ce_filter = json.dumps({
        "Dimensions": {
            "Key": "SERVICE",
            "Values": ["Amazon Bedrock"],
        }
    })

    rc, out, err = _run_aws([
        "ce", "get-cost-and-usage",
        "--time-period", f"Start={start},End={end}",
        "--granularity", "DAILY",
        "--metrics", "UnblendedCost",
        "--filter", ce_filter,
    ])

    if rc != 0:
        status = _classify_error(err)
        detail = (err or out).strip()[:400]
        log.warning("bedrock: aws ce failed (status=%s): %s", status, detail)
        return {
            "status": status,
            "detail": detail,
            "month_to_date_usd": None,
            "projected_usd": None,
            "daily_series": [],
            "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }

    # 4. Parse the daily series.
    try:
        ce_data = json.loads(out)
    except json.JSONDecodeError as e:
        log.warning("bedrock: ce output JSON parse failed: %s", e)
        return {
            "status": "error",
            "detail": f"CE JSON parse failed: {e}",
            "month_to_date_usd": None,
            "projected_usd": None,
            "daily_series": [],
            "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }

    daily_series: list[dict] = []
    month_start = _month_start()
    mtd_usd = 0.0

    for result in ce_data.get("ResultsByTime", []):
        period_start = (result.get("TimePeriod") or {}).get("Start", "")
        try:
            amount = float(
                (result.get("Total") or {})
                .get("UnblendedCost", {})
                .get("Amount", "0") or "0"
            )
        except (ValueError, TypeError):
            amount = 0.0
        daily_series.append({"date": period_start, "usd": amount})
        # Accumulate MTD: only days in the current calendar month.
        if period_start >= month_start:
            mtd_usd += amount

    # 5. Project month-end spend (linear extrapolation).
    days_elapsed = max(_day_of_month(), 1)
    days_total = _days_in_month()
    projected = (mtd_usd / days_elapsed) * days_total if days_elapsed > 0 else mtd_usd

    return {
        "status": "ok",
        "detail": None,
        "month_to_date_usd": round(mtd_usd, 4),
        "projected_usd": round(projected, 2),
        "daily_series": daily_series,
        "account": account,
        "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
    }


# ---------------------------------------------------------------------------
# Disk cache (survives Flask restarts; separate from cost-check.sh's cache)
# ---------------------------------------------------------------------------

def _write_disk_cache(payload: dict) -> None:
    try:
        _CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        _CACHE_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    except OSError as e:
        log.warning("bedrock: could not write disk cache: %s", e)


def _read_disk_cache() -> dict | None:
    try:
        doc = json.loads(_CACHE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    fetched_at = doc.get("fetched_at")
    if not fetched_at:
        return None
    try:
        ts = _dt.datetime.fromisoformat(fetched_at.replace("Z", "+00:00"))
    except ValueError:
        return None
    age = (_dt.datetime.now(_dt.timezone.utc) - ts).total_seconds()
    if age < _CACHE_TTL_SECONDS:
        return doc
    return None


# ---------------------------------------------------------------------------
# Cached fetch (memory cache first, disk cache second, live fetch last)
# ---------------------------------------------------------------------------

def _cached_bedrock() -> dict:
    global _cache
    now = time.monotonic()
    with _cache_lock:
        if _cache is not None and (now - _cache[0]) < _CACHE_TTL_SECONDS:
            return _cache[1]

        # Try disk cache before hitting AWS.
        disk = _read_disk_cache()
        if disk is not None:
            _cache = (now, disk)
            return disk

        # Live fetch.
        try:
            payload = _fetch_bedrock_spend()
        except Exception as e:  # noqa: BLE001
            log.exception("bedrock: unhandled exception in fetch")
            payload = {
                "status": "error",
                "detail": f"{type(e).__name__}: {e}",
                "month_to_date_usd": None,
                "projected_usd": None,
                "daily_series": [],
                "fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }

        if payload.get("status") == "ok":
            _write_disk_cache(payload)

        _cache = (now, payload)
        return payload


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------

_STATUS_DETAIL = {
    "aws_missing":    "aws CLI not installed",
    "no_credentials": "no AWS credentials configured",
    "ce_denied":      "ce access denied",
    "no_aws_env":     "no plan with aws_env configured",
    "error":          "AWS CE call failed",
}


@bp.route("/api/bedrock")
def bedrock():
    try:
        payload = _cached_bedrock()
    except Exception as e:  # noqa: BLE001
        log.exception("bedrock: route-level exception")
        return jsonify(json_envelope(data={
            "status": "error",
            "detail": f"{type(e).__name__}: {e}",
            "month_to_date_usd": None,
            "projected_usd": None,
            "daily_series": [],
        }))

    status = payload.get("status", "error")
    envelope_error: str | None = None
    if status != "ok":
        fallback = _STATUS_DETAIL.get(status, "unknown error")
        envelope_error = payload.get("detail") or fallback

    return jsonify(json_envelope(data=payload, error=envelope_error))
