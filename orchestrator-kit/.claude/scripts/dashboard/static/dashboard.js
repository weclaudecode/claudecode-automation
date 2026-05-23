"use strict";

const POLL_INTERVAL_MS = 5000;
const LOG_MAX_LINES = 200;

const PANELS = {
  plan:    { endpoint: "/api/plan",    render: renderPlan    },
  logs:    { endpoint: "/api/logs",    render: renderLogs    },
  github:  { endpoint: "/api/github",  render: renderGithub  },
  workers: { endpoint: "/api/workers", render: renderWorkers },
  config:  { endpoint: "/api/config",  render: renderConfig  },
};

const state = { paused: false, intervalId: null, logsScrollPinned: true };

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

async function fetchPanel(name) {
  const cfg = PANELS[name];
  const content = $(name).querySelector(".content");
  try {
    const res = await fetch(cfg.endpoint, { cache: "no-store" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const envelope = await res.json();
    if (envelope.error) {
      setHTML(content, '<div class="error">endpoint error: ' + esc(envelope.error) + "</div>");
    } else {
      cfg.render(content, envelope.data);
    }
    setUpdated(name, shortTime(envelope.stale_at) || shortTime(new Date().toISOString()));
  } catch (err) {
    // Per-panel isolation: one endpoint failing must not break the others.
    setHTML(content, '<div class="error">fetch failed: ' + esc(err.message || err) + "</div>");
    setUpdated(name, shortTime(new Date().toISOString()));
  }
}

function refreshAll() {
  if (state.paused) return;
  Object.keys(PANELS).forEach(fetchPanel);
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
    const note = t.blocked_reason ? ' <span class="error">' + esc(t.blocked_reason) + "</span>" : "";
    return "<tr>"
      + "<td>" + esc(t.n) + "</td>"
      + "<td>" + esc(t.title || "") + "</td>"
      + "<td>" + statusBadge(t.status) + note + "</td>"
      + "<td>" + esc(deps) + "</td>"
      + "<td>" + esc(issue) + "</td>"
      + "<td>" + esc(pr) + "</td>"
      + "</tr>";
  }).join("");
  const tbody = rows || '<tr><td colspan="6" class="empty">no tasks</td></tr>';
  setHTML(content,
    '<dl class="kv">'
    + "<dt>plan</dt><dd>" + esc(data.plan_file || "") + "</dd>"
    + "<dt>status</dt><dd>" + statusBadge(data.status) + "</dd>"
    + "<dt>tasks</dt><dd>" + esc(tasks.length) + " / " + esc(data.total_tasks || tasks.length) + "</dd>"
    + "<dt>ingested</dt><dd>" + esc(data.ingested_at || "—") + "</dd>"
    + "</dl>"
    + "<table>"
    + "<thead><tr><th>#</th><th>title</th><th>status</th><th>deps</th><th>issue</th><th>pr</th></tr></thead>"
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
    return "<li>#" + esc(p.number) + ' <a href="' + esc(p.url) + '" target="_blank" rel="noopener">'
      + esc(p.title) + "</a> " + stateLabel + "</li>";
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
}

function startPolling() {
  refreshAll();
  state.intervalId = setInterval(refreshAll, POLL_INTERVAL_MS);
}

document.addEventListener("DOMContentLoaded", function () {
  wireControls();
  startPolling();
});
