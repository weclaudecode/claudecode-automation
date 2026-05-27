"""Flask app factory for the orchestrator dashboard.

Read-only, localhost-only observability tool. Binds to 127.0.0.1 only —
the create_app() factory refuses any other host, and dashboard.sh refuses
to pass anything else.

Blueprint auto-discovery: every `api_*.py` sibling that exports a
top-level `bp = Blueprint(...)` is registered automatically. Tasks that
add new endpoints just drop a file; no central router edit required.
"""

from __future__ import annotations

import datetime as _dt
import glob
import importlib
import logging
import os
import sys
from pathlib import Path

from flask import Flask, jsonify, send_from_directory

DASHBOARD_DIR = Path(__file__).resolve().parent
STATIC_DIR = DASHBOARD_DIR / "static"
TEMPLATES_DIR = DASHBOARD_DIR / "templates"

log = logging.getLogger("dashboard")


def json_envelope(data=None, error: str | None = None) -> dict:
    """Standard response shape for every endpoint.

    Tasks 3-7 must use this so the frontend can render uniformly.
    """
    return {
        "data": data,
        "stale_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "error": error,
    }


def _discover_blueprints(app: Flask) -> None:
    """Import every api_*.py sibling and register its `bp` blueprint.

    A broken endpoint module logs and is skipped — the rest of the app
    still serves. This matches the kit's "best-effort phase" convention
    in orchestrator.sh.
    """
    pattern = str(DASHBOARD_DIR / "api_*.py")
    for path in sorted(glob.glob(pattern)):
        mod_name = Path(path).stem
        try:
            mod = importlib.import_module(f"dashboard.{mod_name}")
        except ImportError as e:
            log.warning("dashboard: skipping %s (import failed: %s)", mod_name, e)
            continue
        bp = getattr(mod, "bp", None)
        if bp is None:
            log.warning("dashboard: skipping %s (no `bp` blueprint exported)", mod_name)
            continue
        app.register_blueprint(bp)
        log.info("dashboard: registered blueprint from %s", mod_name)


def create_app(host: str = "127.0.0.1") -> Flask:
    if host != "127.0.0.1":
        raise RuntimeError(
            f"dashboard refuses to bind to {host!r} — localhost-only by design"
        )

    app = Flask(__name__, static_folder=str(STATIC_DIR), static_url_path="/static")

    @app.route("/api/healthz")
    def healthz():
        return jsonify(json_envelope(data={"ok": True}))

    @app.route("/")
    def mission_centre():
        # PLAN-06 T6: Mission Centre is the new default landing page.
        # T5 (board.html/css/js) drives the unified view via /api/board.
        board_path = TEMPLATES_DIR / "board.html"
        if not board_path.exists():
            return (
                "<h1>dashboard up — Mission Centre frontend not installed</h1>"
                "<p>see /dashboard for the legacy 6-panel view, /api/healthz for status</p>",
                200,
            )
        return send_from_directory(str(TEMPLATES_DIR), "board.html")

    @app.route("/dashboard")
    def legacy_dashboard():
        # Legacy 6-panel view, served at /dashboard since T6. Operators
        # who prefer the older layout (and the routine workflows that
        # bookmarked /) reach it here.
        index_path = STATIC_DIR / "index.html"
        if not index_path.exists():
            return (
                "<h1>dashboard up — legacy frontend not installed</h1>"
                "<p>see / for Mission Centre, /api/healthz for status</p>",
                200,
            )
        return send_from_directory(str(STATIC_DIR), "index.html")

    _discover_blueprints(app)
    return app


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    port_str = os.environ.get("ORCH_DASHBOARD_PORT", "5174")
    try:
        port = int(port_str)
    except ValueError:
        print(f"ORCH_DASHBOARD_PORT must be an integer, got {port_str!r}", file=sys.stderr)
        return 2

    app = create_app(host="127.0.0.1")
    log.info("dashboard listening on http://127.0.0.1:%d", port)
    app.run(host="127.0.0.1", port=port, debug=False, use_reloader=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
