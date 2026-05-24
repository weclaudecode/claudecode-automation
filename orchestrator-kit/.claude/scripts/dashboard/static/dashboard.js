"use strict";

const POLL_INTERVAL_MS = 5000;
const LOG_MAX_LINES = 200;

const PANELS = {
  alerts:  { endpoint: "/api/alerts",  render: renderAlerts  },
  plan:    { endpoint: "/api/plan",    render: renderPlan    },
  logs:    { endpoint: "/api/logs",    render: renderLogs    },
  github:  { endpoint: "/api/github",  render: renderGithub  },
  workers: { endpoint: "/api/workers", render: renderWorkers },
  config:  { endpoint: "/api/config",  render: renderConfig  },
};

const state = { paused: false, intervalId: null, logsScrollPinned: true, activePopover: null };

function $(name) {
  return document.querySelector('section[data-panel="' + name + '"]');
}

function setUpdated(name, when) {
  const el = $(name).querySelector("[data-updated]");
  if (el) el.textContent = when;
}

function esc(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// All dynamic values rendered into the dashboard are funnelled through
// esc() before insertion. setHTML is a single-call-site wrapper so it's
// obvious which strings are pre-escaped templates.
function setHTML(el, html) { el.innerHTML = html; }

function statusBadge(status) {
  const cls = esc(status || "pending");
  return '<span class="status-badge ' + cls + '">' + cls + "</span>";
}

function shortTime(iso) {
  if (!iso) return "—";
  try {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleTimeString();
  } catch (e) { return iso; }
}

function formatCost(usd) {
  if (typeof usd !== "number" || !isFinite(usd)) return "—";
  if (usd === 0) return "$0";
  if (usd < 0.01) return "$" + usd.toFixed(4);
  return "$" + usd.toFixed(2);
}

function formatTokens(n) {
  if (typeof n !== "number" || !isFinite(n) || n === 0) return "0";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(n);
}

function formatDuration(ms) {
  if (typeof ms !== "number" || !isFinite(ms) || ms <= 0) return "—";
  const s = Math.round(ms / 1000);
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return m + "m" + (rem > 0 ? rem + "s" : "");
}

// Compact "5m ago" / "2h ago" for alert "since" fields.
function relativeTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const diffSec = Math.round((Date.now() - d.getTime()) / 1000);
  if (diffSec < 60) return diffSec + "s ago";
  const min = Math.round(diffSec / 60);
  if (min < 60) return min + "m ago";
  const hr = Math.round(min / 60);
  if (hr < 48) return hr + "h ago";
  const days = Math.round(hr / 24);
  return days + "d ago";
}

// Renders a CI status dot for a PR row. ci_state from /api/github comes
// from statusCheckRollup; null means "no checks configured" so we show
// a dash rather than a misleading green dot.
function renderCiDot(ciState) {
  if (!ciState) return '<span class="ci-dot none" title="no CI checks configured">—</span>';
  const cls = String(ciState).toLowerCase();
  const glyph = cls === "pending" ? "◐" : "●";
  return '<span class="ci-dot ' + cls + '" title="CI: ' + cls + '">' + glyph + "</span>";
}

// Render a help-icon button IF a runbook entry matches the given key.
// Returns "" otherwise so callers can unconditionally concatenate.
function helpIconFor(key, label) {
  if (!key || typeof window.lookupRunbook !== "function") return "";
  if (!window.lookupRunbook(key)) return "";
  return ' <button type="button" class="help-icon" data-runbook="' + esc(key)
    + '" aria-label="' + esc(label || "what does this mean?") + '">❓</button>';
}

async function fetchPanel(name) {
  const cfg = PANELS[name];
  const content = $(name).querySelector(".content");
  try {
    const res = await fetch(cfg.endpoint, { cache: "no-store" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const envelope = await res.json();
    // Soft envelope errors don't always wipe the panel — for alerts and any
    // future "partial result" endpoint, we still want to render whatever
    // data DID arrive. The error gets surfaced as a per-panel banner above
    // the rendered content with a runbook icon if one matches.
    if (envelope.error && envelope.data) {
      cfg.render(content, envelope.data);
      const banner = document.createElement("div");
      banner.className = "error soft";
      setHTML(banner,
        "endpoint warning: " + esc(envelope.error)
        + helpIconFor(envelope.error, "fix this error"));
      content.insertBefore(banner, content.firstChild);
    } else if (envelope.error) {
      setHTML(content, '<div class="error">endpoint error: ' + esc(envelope.error) + "</div>"
        + helpIconFor(envelope.error, "fix this error"));
    } else {
      cfg.render(content, envelope.data);
    }
    setUpdated(name, shortTime(envelope.stale_at) || shortTime(new Date().toISOString()));
  } catch (err) {
    // Per-panel isolation: one endpoint failing must not break the others.
    const msg = err.message || String(err);
    setHTML(content, '<div class="error">fetch failed: ' + esc(msg) + "</div>"
      + helpIconFor("fetch failed", "the dashboard backend is unreachable"));
    setUpdated(name, shortTime(new Date().toISOString()));
  }
}

function refreshAll() {
  if (state.paused) return;
  Object.keys(PANELS).forEach(fetchPanel);
}

function renderAlerts(content, data) {
  const alerts = (data && Array.isArray(data.alerts)) ? data.alerts : [];
  const strip = document.getElementById("alerts-strip");
  if (!strip) return;  // Defensive: index.html should always include it.
  if (!alerts.length) {
    strip.classList.add("empty");
    setHTML(content, "");
    return;
  }
  strip.classList.remove("empty");
  // Default-expanded if any alert is severity=error; otherwise collapsed.
  const hasError = alerts.some(function (a) { return a.severity === "error"; });
  strip.classList.toggle("collapsed", !hasError);

  const counts = alerts.reduce(function (acc, a) {
    acc[a.severity] = (acc[a.severity] || 0) + 1; return acc;
  }, {});
  const summaryBits = ["error", "warn", "info"]
    .filter(function (k) { return counts[k]; })
    .map(function (k) { return counts[k] + " " + k; })
    .join(" · ");
  const headerHTML =
    '<div class="alerts-header">'
    + '<span class="alerts-title">⚠ ALERTS (' + esc(alerts.length) + ')</span>'
    + '<span class="alerts-counts">' + esc(summaryBits) + "</span>"
    + '<button type="button" class="alerts-toggle" aria-expanded="' + (!strip.classList.contains("collapsed")) + '">'
    + (strip.classList.contains("collapsed") ? "expand" : "collapse")
    + "</button>"
    + "</div>";

  const cards = alerts.map(renderAlertCard).join("");
  setHTML(content, headerHTML + '<div class="alerts-body">' + cards + "</div>");

  const toggle = content.querySelector(".alerts-toggle");
  toggle.addEventListener("click", function () {
    const isCollapsed = strip.classList.toggle("collapsed");
    toggle.setAttribute("aria-expanded", String(!isCollapsed));
    toggle.textContent = isCollapsed ? "expand" : "collapse";
  });
}

function renderAlertCard(a) {
  const sev = (a.severity || "info").toLowerCase();
  const icon = sev === "error" ? "❗" : (sev === "warn" ? "⚠" : "ⓘ");
  const since = a.since
    ? ' <span class="alert-since" title="' + esc(a.since) + '">' + esc(relativeTime(a.since)) + "</span>"
    : "";
  const link = a.link
    ? ' <a href="' + esc(a.link) + '" target="_blank" rel="noopener" class="alert-link">open ↗</a>'
    : "";
  const detail = a.detail
    ? '<div class="alert-detail">' + esc(a.detail) + "</div>"
    : "";
  // The suggested_action travels inside data-snippet so the popover can show
  // (and copy) it without an extra fetch. esc() handles attribute quoting.
  const help = a.suggested_action
    ? ' <button type="button" class="alert-help" data-snippet="' + esc(a.suggested_action)
      + '" aria-label="show suggested action">❓</button>'
    : "";
  return '<div class="alert-card ' + esc(sev) + '" data-kind="' + esc(a.kind || "") + '">'
    + '<span class="alert-icon" aria-hidden="true">' + icon + "</span>"
    + '<div class="alert-body">'
    + '<div class="alert-summary">' + esc(a.summary || "") + since + link + help + "</div>"
    + detail
    + "</div>"
    + "</div>";
}

function renderPlan(content, data) {
  if (!data) {
    setHTML(content, '<p class="empty">no active plan</p>');
    document.getElementById("header-slug").textContent = "no active plan";
    return;
  }
  document.getElementById("header-slug").textContent = data.slug || data.plan_file || "—";
  const tasks = Array.isArray(data.tasks) ? data.tasks : [];
  const rows = tasks.map(function (t) {
    const deps = (t.depends_on || []).join(",") || "—";
    const issue = t.issue ? "#" + t.issue : "—";
    const pr = t.pr ? "#" + t.pr : "—";
    const note = t.blocked_reason
      ? ' <span class="error">' + esc(t.blocked_reason) + "</span>"
        + helpIconFor(t.blocked_reason, "why is this blocked and how to unblock it")
      : "";
    const usage = t.usage || null;
    // Compact per-task usage: "$X.XX · Nt · Xs" if usage exists, else "—".
    // Tokens deliberately omitted from row to keep the table scannable;
    // plan-level totals show the full token breakdown.
    let usageCell = "—";
    if (usage && typeof usage.total_cost_usd === "number") {
      usageCell = formatCost(usage.total_cost_usd)
        + " · " + esc(usage.total_turns || 0) + "t"
        + " · " + esc(formatDuration(usage.total_duration_ms));
    }
    return "<tr>"
      + "<td>" + esc(t.n) + "</td>"
      + "<td>" + esc(t.title || "") + "</td>"
      + "<td>" + statusBadge(t.status) + note + "</td>"
      + "<td>" + esc(deps) + "</td>"
      + "<td>" + esc(issue) + "</td>"
      + "<td>" + esc(pr) + "</td>"
      + "<td>" + usageCell + "</td>"
      + "</tr>";
  }).join("");
  const tbody = rows || '<tr><td colspan="7" class="empty">no tasks</td></tr>';

  // Plan-level usage rollup (only rendered when at least one task has usage).
  const ut = data.usage_total || null;
  let usageKv = "";
  if (ut) {
    const tokens = formatTokens(ut.total_input_tokens || 0)
      + " in · " + formatTokens(ut.total_output_tokens || 0) + " out · "
      + formatTokens(ut.total_cache_read_tokens || 0) + " cache_r";
    const models = (ut.models || []).map(function (m) { return m.replace(/^claude-/, ""); }).join(", ") || "—";
    usageKv = "<dt>cost</dt><dd>" + formatCost(ut.total_cost_usd) + " · " + esc(ut.total_runs || 0) + " runs · " + esc(models) + "</dd>"
      + "<dt>tokens</dt><dd>" + tokens + "</dd>";
  }

  setHTML(content,
    '<dl class="kv">'
    + "<dt>plan</dt><dd>" + esc(data.plan_file || "") + "</dd>"
    + "<dt>status</dt><dd>" + statusBadge(data.status) + "</dd>"
    + "<dt>tasks</dt><dd>" + esc(tasks.length) + " / " + esc(data.total_tasks || tasks.length) + "</dd>"
    + "<dt>ingested</dt><dd>" + esc(data.ingested_at || "—") + "</dd>"
    + usageKv
    + "</dl>"
    + "<table>"
    + "<thead><tr><th>#</th><th>title</th><th>status</th><th>deps</th><th>issue</th><th>pr</th><th>usage</th></tr></thead>"
    + "<tbody>" + tbody + "</tbody>"
    + "</table>"
  );
}

function renderLogs(content, data) {
  const all = (data && Array.isArray(data.lines)) ? data.lines : [];
  const lines = all.slice(-LOG_MAX_LINES);
  let pre = content.querySelector("pre.logs");
  if (!pre) {
    setHTML(content, '<pre class="logs"></pre>');
    pre = content.querySelector("pre.logs");
    // Track whether the user has scrolled up; if so we stop auto-pinning.
    pre.addEventListener("scroll", function () {
      const atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 8;
      state.logsScrollPinned = atBottom;
    });
  }
  const body = lines.map(function (l) {
    const lvl = (l.level || "info").toLowerCase();
    const allowed = ["tick", "phase", "warn", "error", "info"];
    const cls = allowed.indexOf(lvl) >= 0 ? lvl : "info";
    const ts = l.ts ? "[" + esc(l.ts) + "] " : "";
    return '<span class="line ' + cls + '">' + ts + esc(l.msg || "") + "</span>";
  }).join("\n");
  setHTML(pre, body || '<span class="empty">no log lines</span>');
  if (state.logsScrollPinned) pre.scrollTop = pre.scrollHeight;
  if (data && data.total_lines != null) {
    setUpdated("logs", shortTime(new Date().toISOString()) + " (" + esc(data.total_lines) + " total)");
  }
}

function renderGithub(content, data) {
  if (!data) { setHTML(content, '<p class="empty">no data</p>'); return; }
  const issues = (data.open_issues || []).map(function (i) {
    const labels = (i.labels || []).map(function (l) {
      return '<span class="label-pill">' + esc(l && l.name ? l.name : l) + "</span>";
    }).join("");
    return "<li>#" + esc(i.number) + ' <a href="' + esc(i.url) + '" target="_blank" rel="noopener">'
      + esc(i.title) + "</a> " + labels + "</li>";
  }).join("");
  const prs = (data.recent_prs || []).map(function (p) {
    const stateLabel = p.merged_at
      ? '<span class="status-badge merged">merged</span>'
      : '<span class="status-badge ' + esc((p.state || "open").toLowerCase()) + '">' + esc(p.state || "open") + "</span>";
    // CI dot precedes the PR number so the green/red signal is the first
    // thing the operator's eye lands on. Merged PRs still get a dot since
    // post-merge checks (release CI, deploy) are useful to see.
    return "<li>" + renderCiDot(p.ci_state) + " #" + esc(p.number)
      + ' <a href="' + esc(p.url) + '" target="_blank" rel="noopener">' + esc(p.title) + "</a> "
      + stateLabel + "</li>";
  }).join("");
  const h = 'style="margin:4px 0 4px;font-size:11px;color:var(--fg-dim);text-transform:uppercase;letter-spacing:0.08em;"';
  const h2 = 'style="margin:10px 0 4px;font-size:11px;color:var(--fg-dim);text-transform:uppercase;letter-spacing:0.08em;"';
  setHTML(content,
    "<h3 " + h + ">open issues</h3>"
    + '<ul class="bare">' + (issues || '<li class="empty">none</li>') + "</ul>"
    + "<h3 " + h2 + ">recent PRs</h3>"
    + '<ul class="bare">' + (prs || '<li class="empty">none</li>') + "</ul>"
  );
}

function renderWorkers(content, data) {
  if (!data) { setHTML(content, '<p class="empty">no data</p>'); return; }
  const procs = (data.processes || []).map(function (p) {
    return "<tr><td>" + esc(p.pid) + "</td><td>" + esc(p.started_at || "")
      + "</td><td>" + esc(p.cmdline || "") + "</td></tr>";
  }).join("");
  const wts = (data.active_worktrees || []).map(function (w) {
    return "<tr><td>" + esc(w.task_n != null ? w.task_n : "—") + "</td><td>"
      + esc(w.branch || "") + "</td><td>" + esc(w.path || "") + "</td></tr>";
  }).join("");
  const h = 'style="margin:4px 0 4px;font-size:11px;color:var(--fg-dim);text-transform:uppercase;letter-spacing:0.08em;"';
  const h2 = 'style="margin:10px 0 4px;font-size:11px;color:var(--fg-dim);text-transform:uppercase;letter-spacing:0.08em;"';
  setHTML(content,
    "<h3 " + h + ">processes</h3>"
    + "<table><thead><tr><th>pid</th><th>started</th><th>cmd</th></tr></thead>"
    + "<tbody>" + (procs || '<tr><td colspan="3" class="empty">no workers</td></tr>') + "</tbody></table>"
    + "<h3 " + h2 + ">active worktrees</h3>"
    + "<table><thead><tr><th>task</th><th>branch</th><th>path</th></tr></thead>"
    + "<tbody>" + (wts || '<tr><td colspan="3" class="empty">none</td></tr>') + "</tbody></table>"
  );
}

function renderConfig(content, data) {
  if (!data) { setHTML(content, '<p class="empty">no data</p>'); return; }
  const rows = (data.tunables || []).map(function (t) {
    return "<tr>"
      + "<td>" + esc(t.name) + "</td>"
      + "<td>" + esc(t.current) + "</td>"
      + "<td>" + esc(t.default) + "</td>"
      + "<td>" + esc(t.source) + "</td>"
      + "<td>" + esc(t.description || "") + "</td>"
      + "</tr>";
  }).join("");
  setHTML(content,
    "<table><thead><tr><th>name</th><th>current</th><th>default</th><th>source</th><th>description</th></tr></thead>"
    + "<tbody>" + (rows || '<tr><td colspan="5" class="empty">no tunables</td></tr>') + "</tbody></table>"
  );
}

function closePopover() {
  if (state.activePopover) {
    state.activePopover.remove();
    state.activePopover = null;
  }
}

function openPopover(anchor, titleHTML, bodyHTML, snippetForCopy) {
  closePopover();
  const popover = document.createElement("div");
  popover.className = "runbook-popover";
  popover.setAttribute("role", "dialog");
  popover.setAttribute("aria-modal", "false");
  // Pre-escape everything in caller; bodyHTML is a <pre>-wrapped snippet.
  setHTML(popover,
    '<button type="button" class="popover-close" aria-label="close">×</button>'
    + (titleHTML ? '<div class="popover-title">' + titleHTML + "</div>" : "")
    + '<pre class="popover-snippet">' + bodyHTML + "</pre>"
    + (snippetForCopy != null ? '<button type="button" class="popover-copy">copy</button>' : ""));
  document.body.appendChild(popover);
  // Position below the anchor, clipped to viewport.
  const rect = anchor.getBoundingClientRect();
  const pRect = popover.getBoundingClientRect();
  let left = rect.left + window.scrollX;
  if (left + pRect.width > window.scrollX + window.innerWidth - 12) {
    left = Math.max(window.scrollX + 12, window.scrollX + window.innerWidth - pRect.width - 12);
  }
  popover.style.position = "absolute";
  popover.style.top = (rect.bottom + window.scrollY + 6) + "px";
  popover.style.left = left + "px";
  state.activePopover = popover;

  popover.querySelector(".popover-close").addEventListener("click", closePopover);
  const copyBtn = popover.querySelector(".popover-copy");
  if (copyBtn && snippetForCopy != null) {
    copyBtn.addEventListener("click", function () {
      if (navigator.clipboard) {
        navigator.clipboard.writeText(snippetForCopy).then(function () {
          copyBtn.textContent = "copied ✓";
          setTimeout(function () { copyBtn.textContent = "copy"; }, 1200);
        });
      }
    });
  }
}

// Build the popover content from a runbook entry. Returns
// {titleHTML, bodyHTML, snippet} suitable for openPopover().
function popoverFromRunbook(entry) {
  const title = esc(entry.title || "");
  const body = (entry.body || []).map(esc).join("\n");
  const snippet = (entry.body || []).join("\n");
  return { titleHTML: title, bodyHTML: body, snippet: snippet };
}

function wireControls() {
  document.querySelectorAll("section[data-panel] [data-refresh]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      const name = btn.closest("section[data-panel]").dataset.panel;
      fetchPanel(name);
    });
  });
  const pauseBtn = document.getElementById("pause-toggle");
  const pollStatus = document.getElementById("poll-status");
  pauseBtn.addEventListener("click", function () {
    state.paused = !state.paused;
    pauseBtn.setAttribute("aria-pressed", String(state.paused));
    pauseBtn.textContent = state.paused ? "resume polling" : "pause polling";
    pollStatus.textContent = state.paused ? "paused" : "polling every 5s";
  });

  // ---------------------------------------------------------------------
  // Popover delegation: one document-level click handler for every
  // help-icon / alert-help button. Keeps the listener count bounded as
  // panels re-render.
  // ---------------------------------------------------------------------
  document.addEventListener("click", function (e) {
    const tgt = e.target;
    if (!tgt || tgt.nodeType !== 1) return;
    if (tgt.matches(".alert-help")) {
      const snippet = tgt.dataset.snippet || "";
      openPopover(tgt, esc("suggested action"), esc(snippet), snippet);
      e.stopPropagation();
      return;
    }
    if (tgt.matches(".help-icon")) {
      const key = tgt.dataset.runbook || "";
      const entry = (window.lookupRunbook || function () { return null; })(key);
      if (entry) {
        const p = popoverFromRunbook(entry);
        openPopover(tgt, p.titleHTML, p.bodyHTML, p.snippet);
      }
      e.stopPropagation();
      return;
    }
    // Outside-click closes any open popover.
    if (state.activePopover && !state.activePopover.contains(tgt)) {
      closePopover();
    }
  });

  // ---------------------------------------------------------------------
  // Help overlay + keyboard shortcuts
  // ---------------------------------------------------------------------
  const helpToggle = document.getElementById("help-toggle");
  const helpOverlay = document.getElementById("help-overlay");
  const helpClose = document.getElementById("help-close");
  function showHelp() { if (helpOverlay) helpOverlay.hidden = false; }
  function hideHelp() { if (helpOverlay) helpOverlay.hidden = true; }
  if (helpToggle) helpToggle.addEventListener("click", function () {
    helpOverlay.hidden ? showHelp() : hideHelp();
  });
  if (helpClose) helpClose.addEventListener("click", hideHelp);
  if (helpOverlay) helpOverlay.addEventListener("click", function (e) {
    // Close on backdrop click but not when the dialog body itself is clicked.
    if (e.target === helpOverlay) hideHelp();
  });

  document.addEventListener("keydown", function (e) {
    // Don't hijack keys when the user is typing into an input (none today,
    // but cheap insurance against the log-filter input in Tier 2).
    if (e.target && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA")) return;
    if (e.key === "Escape") {
      if (state.activePopover) { closePopover(); return; }
      if (helpOverlay && !helpOverlay.hidden) { hideHelp(); return; }
      return;
    }
    if (e.key === "r") { refreshAll(); return; }
    if (e.key === "p") { pauseBtn.click(); return; }
    if (e.key === "?") { helpOverlay.hidden ? showHelp() : hideHelp(); return; }
  });
}

function startPolling() {
  refreshAll();
  state.intervalId = setInterval(refreshAll, POLL_INTERVAL_MS);
}

document.addEventListener("DOMContentLoaded", function () {
  wireControls();
  startPolling();
});
