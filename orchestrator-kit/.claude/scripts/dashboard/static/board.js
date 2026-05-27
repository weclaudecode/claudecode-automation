"use strict";

/* Mission Centre — polls /api/board every 5 s and renders the unified
   board + workers + plan status + cost + log + activity + GitHub view.
   Plain JS, no framework — matches the existing dashboard codebase style.

   XSS posture: every dynamic string that lands in innerHTML is funnelled
   through esc() (HTML-entity escape). This matches dashboard.js's
   existing approach (see esc() and setHTML() in dashboard.js). Pre-built
   HTML fragments are static template literals; URLs that come from
   the backend are escaped before insertion into href/src attributes.

   Scroll preservation: re-rendering wipes child DOM, which resets every
   scrollable panel's scrollTop. We snapshot scrollTop for each panel
   before re-render and restore it after, so the operator's scroll
   position survives the 5 s poll cycle. */

const POLL_INTERVAL_MS = 5000;
const ENDPOINT = "/api/board";
const DICEBEAR_BASE = "https://api.dicebear.com/8.x/bottts/svg";

const COLUMN_DEFS = [
  { key: "backlog",          label: "Backlog" },
  { key: "todo",             label: "Todo", scroll: true },
  { key: "in_progress",      label: "In Progress" },
  { key: "ready_for_review", label: "Ready" },
  { key: "in_review",        label: "In Review" },
  { key: "blocked",          label: "Blocked" },
  { key: "done",             label: "Done" },
];

/* IDs of scrollable elements whose scrollTop we want to preserve across
   re-renders. The Todo column is the headline scroller; the log and
   activity panels also scroll independently. The Todo col is found
   dynamically because its DOM node is rebuilt per render. */
const SCROLL_PANEL_IDS = ["log-tail", "activity"];

/* Has the dashboard rendered live data at least once this session?
   When true, transient fetch errors (network blips, 5xx) surface as a
   stale-dot indicator + an alerts banner WITHOUT wiping the panels.
   This preserves the operator's last-known-good view across short
   outages. Reset by renderLoadingState (cold start, 404). */
let hasRenderedSuccessfully = false;

/* DiceBear avatar palette — used by initials-on-color SVG fallback when
   DiceBear is unreachable. Hash(name) % palette picks a stable color
   per agent so Pip is always pink, Bento is always teal, etc. */
const FALLBACK_PALETTE = [
  "#db61a2", "#58a6ff", "#d29922", "#a371f7", "#3fb950",
  "#f85149", "#5ec9b8", "#fbbf24", "#b392f0", "#f472b6",
];

/* ── Utilities ─────────────────────────────────────────────────────────── */

function esc(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function $(id) { return document.getElementById(id); }

function hashStr(s) {
  /* djb2 — deterministic, browser-safe. Not crypto; same input → same
     color so Pip's fallback avatar is the same color every render. */
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

function pillClassForPlan(plan) {
  if (!plan) return "p-default";
  const m = String(plan).match(/PLAN-(\d+)/);
  if (!m) return "p-default";
  return "p" + parseInt(m[1], 10);
}

function planPillText(plan) {
  if (!plan) return "";
  const m = String(plan).match(/PLAN-0?(\d+)/);
  return m ? "P-" + m[1].padStart(2, "0") : String(plan);
}

function shortTime(iso) {
  if (!iso) return "—";
  try {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleTimeString([], { hour12: false });
  } catch (e) {
    return iso;
  }
}

function formatTokens(n) {
  if (typeof n !== "number" || !isFinite(n) || n === 0) return "0";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(n);
}

function formatCost(usd) {
  if (typeof usd !== "number" || !isFinite(usd)) return "—";
  if (usd === 0) return "$0";
  if (usd < 0.01) return "$" + usd.toFixed(4);
  return "$" + usd.toFixed(2);
}

/* ── Avatar rendering (DiceBear + initials fallback) ──────────────────── */

function dicebearUrl(seed, isReviewer) {
  const params = new URLSearchParams({ seed: seed });
  if (isReviewer) {
    /* Argus gets a fixed pink background so the operator can spot the
       reviewer at a glance. */
    params.set("backgroundColor", "db61a2");
  } else {
    params.set("backgroundType", "gradientLinear");
  }
  return DICEBEAR_BASE + "?" + params.toString();
}

function fallbackInitialsSvg(name) {
  const initial = (name || "?").trim().charAt(0).toUpperCase() || "?";
  const color = FALLBACK_PALETTE[hashStr(name || "?") % FALLBACK_PALETTE.length];
  /* Data URI keeps the fallback inline — no extra request. */
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">' +
      '<rect width="40" height="40" rx="20" fill="' + color + '"/>' +
      '<text x="20" y="26" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="20" font-weight="700" fill="#0d1117">' +
        esc(initial) +
      '</text>' +
    '</svg>';
  return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
}

function renderAvatar(agent) {
  if (!agent || !agent.avatar_seed) {
    return '<span class="avatar" aria-hidden="true"></span>';
  }
  const seed = agent.avatar_seed;
  const isReviewer = agent.role === "reviewer";
  const fallback = fallbackInitialsSvg(agent.name || seed);
  /* `onerror` covers HTTP-level failures (DNS down, 4xx/5xx, network).
     `onload` with `naturalWidth === 0` catches the soft-failure case
     where the CDN responds 200 OK with an HTML error page instead of
     SVG — without this, the operator sees a broken-image icon and the
     fallback never fires. Both handlers null themselves out to avoid
     ping-pong if the fallback data-URI itself fails. */
  const altText = agent.name ? agent.name + " avatar" : "agent avatar";
  return '<img class="avatar" loading="lazy"'
    + ' alt="' + esc(altText) + '"'
    + ' src="' + esc(dicebearUrl(seed, isReviewer)) + '"'
    + ' onerror="this.onerror=null;this.src=&quot;' + esc(fallback) + '&quot;;"'
    + ' onload="if(this.naturalWidth===0){this.onerror=null;this.src=&quot;' + esc(fallback) + '&quot;;}">';
}

/* ── Card rendering ────────────────────────────────────────────────────── */

function badgesFor(card) {
  const bits = [];
  const pr = card.pr;
  const col = card._column;

  if (Array.isArray(card.badges)) {
    for (const b of card.badges) {
      bits.push('<span class="badge">' + esc(b) + '</span>');
    }
  }

  if (col === "ready_for_review" || col === "in_review" || col === "done") {
    if (pr != null) bits.push('<span class="pr">#' + esc(pr) + '</span>');
  }

  if (col === "in_review" && card.agent && card.agent.role !== "reviewer") {
    /* Iterator badge — iterator inherits worker's per-task agent so
       this is how the operator distinguishes "Argus is reviewing"
       from "Echo r2/5 is iterating". */
    const r = card.retries;
    if (typeof r === "number" && r > 0) {
      bits.push('<span class="badge iter">iter r' + esc(r) + "/5</span>");
    }
  }

  if (col === "blocked" && card.blocked_reason) {
    bits.push('<span class="badge block">' + esc(card.blocked_reason) + "</span>");
  }

  if (col === "done" && card.cost_usd != null) {
    bits.push('<span class="cost">' + esc(formatCost(card.cost_usd)) + "</span>");
  }

  if (col === "todo" && Array.isArray(card.depends_on) && card.depends_on.length) {
    const deps = card.depends_on.map((d) => "T" + d).join(",");
    bits.push("<span>· deps " + esc(deps) + "</span>");
  }

  return bits.join("");
}

function cardLeading(card) {
  /* Backlog cards use a glyph (📌 / ⏸) — no per-task agent. Todo cards
     have no avatar (just title + deps). Otherwise an avatar based on
     the assigned agent. */
  const col = card._column;
  if (col === "backlog") {
    const glyph = card.status === "monitor" ? "📌" : "⏸";
    return '<span class="glyph" aria-hidden="true">' + glyph + "</span>";
  }
  if (col === "todo") {
    return "";
  }
  if (card.agent) {
    return renderAvatar(card.agent);
  }
  return "";
}

function renderCard(card) {
  const planText = planPillText(card.plan);
  const planClass = pillClassForPlan(card.plan);
  const planPillHtml = planText
    ? '<span class="plan-pill ' + planClass + '">' + esc(planText) + "</span>"
    : "";
  const taskHtml = (card.task != null) ? '<span>T' + esc(card.task) + "</span>" : "";
  const sensitiveHtml = card.sensitive ? '<span class="sens" title="sensitive — needs operator">🛡</span>' : "";
  const doneClass = card._column === "done" ? " done" : "";
  const titleAttr = card.status ? ' title="status: ' + esc(card.status) + '"' : "";
  const url = card.click_url || "";

  /* Screen-reader label: intent + identity + state, in that order.
     Operators using a screen reader hear what activation does BEFORE
     the raw button text (which contains decorative emoji and status
     glyphs that read as noise). */
  const ariaBits = [];
  if (card.task != null) ariaBits.push("T" + card.task);
  if (card.title) ariaBits.push(card.title);
  if (card.agent && card.agent.name) ariaBits.push("agent " + card.agent.name);
  if (card.status) ariaBits.push("status " + card.status);
  if (card.plan) ariaBits.push(card.plan);
  const ariaLabel = url
    ? "Open " + ariaBits.join(", ") + " in new tab"
    : ariaBits.join(", ");

  const jokeHtml = (card._column === "blocked" && card.joke)
    ? '<div class="card-joke">' + esc(card.joke) + "</div>"
    : "";

  return ''
    + '<button type="button" class="card' + doneClass + '" data-url="' + esc(url) + '"'
    +   ' aria-label="' + esc(ariaLabel) + '"' + titleAttr + ">"
    +   '<div class="card-row">'
    +     cardLeading(card)
    +     '<span class="title">' + esc(card.title || "—") + "</span>"
    +     sensitiveHtml
    +   "</div>"
    +   '<div class="card-meta">'
    +     planPillHtml
    +     taskHtml
    +     badgesFor(card)
    +   "</div>"
    +   jokeHtml
    + "</button>";
}

/* ── Column rendering ──────────────────────────────────────────────────── */

function renderColumn(def, cards) {
  const items = (cards || []).map((c) => {
    c._column = def.key;
    return renderCard(c);
  });
  const body = items.length
    ? items.join("")
    : '<div class="col-empty" aria-label="empty column">(none)</div>';
  return ''
    + '<div class="col col-' + esc(def.key) + (def.scroll ? " scroll" : "") + '">'
    +   '<div class="col-header">'
    +     '<span class="accent"></span>'
    +     '<span class="name">' + esc(def.label) + "</span>"
    +     '<span class="count">' + esc((cards || []).length) + "</span>"
    +   "</div>"
    +   '<div class="col-body">' + body + "</div>"
    + "</div>";
}

/* ── Side panels ───────────────────────────────────────────────────────── */

function renderWorkers(workers) {
  if (!workers || !workers.length) {
    return '<div class="worker-empty">No active workers</div>';
  }
  return workers.map((w) => {
    const agent = { name: w.name, avatar_seed: w.avatar_seed, role: w.role || "worker" };
    const elapsed = (typeof w.elapsed_sec === "number")
      ? Math.max(0, Math.floor(w.elapsed_sec / 60)) + "m elapsed"
      : "";
    const metaBits = [
      w.role || "worker",
      (w.pid != null) ? "pid " + w.pid : "",
      elapsed,
      w.worktree || "",
    ].filter(Boolean).join(" · ");
    const lastLog = w.last_log
      ? '<div class="last-log">' + esc(w.last_log) + "</div>"
      : "";
    return ''
      + '<div class="worker">'
      +   renderAvatar(agent)
      +   '<div class="info">'
      +     '<div class="name">' + esc(w.name || "—") + "</div>"
      +     '<div class="task">T' + esc(w.task) + " · " + esc(w.plan || "") + " · " + esc(w.title || "") + "</div>"
      +     '<div class="meta">' + esc(metaBits) + "</div>"
      +     lastLog
      +   "</div>"
      + "</div>";
  }).join("");
}

function renderPlanStatus(plans) {
  if (!plans || !plans.length) {
    return '<div class="plan-status-empty">No active plan</div>';
  }
  return plans.map((p) => {
    const total = Math.max(1, p.total || 0);
    const merged = p.merged || 0;
    const pct = Math.round((merged / total) * 100);
    return ''
      + '<div class="plan-status">'
      +   '<div class="slug">' + esc(p.slug || p.plan || "") + "</div>"
      +   '<div class="bar"><span style="width:' + pct + '%"></span></div>'
      +   '<div class="summary">' + esc(merged) + " of " + esc(total) + " merged · " + pct + "% complete</div>"
      +   '<div class="stats">'
      +     '<div class="stat"><span class="label">✓ merged</span><span class="num merged">' + esc(merged) + "</span></div>"
      +     '<div class="stat"><span class="label">▶ in progress</span><span class="num running">' + esc(p.in_progress || 0) + "</span></div>"
      +     '<div class="stat"><span class="label">⟲ in review</span><span class="num review">' + esc(p.in_review || 0) + "</span></div>"
      +     '<div class="stat"><span class="label">◯ pending</span><span class="num">' + esc(p.pending || 0) + "</span></div>"
      +     '<div class="stat"><span class="label">⚠ blocked</span><span class="num blocked">' + esc(p.blocked || 0) + "</span></div>"
      +   "</div>"
      + "</div>";
  }).join("");
}

function renderCost(cost) {
  if (!cost || (cost.today_usd == null && cost.today_tokens == null)) {
    return '<div class="cost-empty">No usage data yet today</div>';
  }
  /* Token-first headline because the operator is on a Max subscription
     where $ is notional. cost_today() may return either shape depending
     on whether T2's tokens_today extension is wired through; render
     defensively. */
  const tokensTotal = (cost.today_tokens && typeof cost.today_tokens.total === "number")
    ? cost.today_tokens.total
    : null;
  const usd = (typeof cost.today_usd === "number") ? cost.today_usd : null;

  let headlineHtml;
  let headlineSubHtml = "";
  if (tokensTotal != null) {
    headlineHtml = '<div class="big">' + esc(formatTokens(tokensTotal)) + ' tok</div>';
    if (usd != null) {
      headlineSubHtml = '<div class="big-sub">≈ ' + esc(formatCost(usd)) + ' API-equivalent</div>';
    }
  } else {
    headlineHtml = '<div class="big">' + esc(formatCost(usd)) + "</div>";
  }

  const roleRows = [];
  const byRole = cost.by_role || {};
  for (const role of ["worker", "reviewer", "iterator"]) {
    const v = byRole[role];
    if (v == null) continue;
    const label = (role === "reviewer") ? "reviewer (Argus)" : role + "s";
    roleRows.push(''
      + '<div class="row"><span>' + esc(label) + '</span><span class="v">' + esc(formatCost(v)) + "</span></div>");
  }

  let trendHtml = "";
  if (typeof cost.yesterday_usd === "number" && cost.yesterday_usd > 0 && usd != null) {
    const delta = ((usd - cost.yesterday_usd) / cost.yesterday_usd) * 100;
    const sign = delta >= 0 ? "↑" : "↓";
    const dirClass = delta >= 0 ? "up" : "down";
    trendHtml += '<span class="' + dirClass + '">' + sign + " " + Math.abs(Math.round(delta)) + "%</span> vs yesterday";
  }
  if (typeof cost.this_week_usd === "number") {
    trendHtml += (trendHtml ? " · " : "") + esc(formatCost(cost.this_week_usd)) + " this week";
  }

  return ''
    + headlineHtml
    + headlineSubHtml
    + (roleRows.length ? '<div class="breakdown">' + roleRows.join("") + "</div>" : "")
    + (trendHtml ? '<div class="trend">' + trendHtml + "</div>" : "");
}

function renderLog(lines) {
  if (!lines || !lines.length) {
    return '<div class="log-empty">log empty</div>';
  }
  return lines.map((l) => {
    const kind = l.kind || "line";
    const text = l.text || "";
    const tsHtml = l.ts ? '<span class="ts">' + esc(l.ts) + "</span>" : "";
    const kindClass = (kind === "line") ? "" : " " + kind;
    return '<div class="line' + esc(kindClass) + '">' + tsHtml + esc(text) + "</div>";
  }).join("");
}

function renderActivity(events) {
  if (!events || !events.length) {
    return '<div class="activity-empty">No recent activity</div>';
  }
  return events.map((ev) => {
    const kind = (ev.kind || "").toLowerCase();
    let kindClass = "";
    if (kind.indexOf("merged") !== -1) kindClass = " merged";
    else if (kind.indexOf("review") !== -1) kindClass = " review";
    else if (kind.indexOf("blocked") !== -1) kindClass = " blocked";
    return ''
      + '<div class="ev">'
      +   '<span class="ts">' + esc(ev.ts || "") + "</span>"
      +   '<div class="body">'
      +     '<div class="kind' + esc(kindClass) + '">' + esc(ev.kind || "unknown") + "</div>"
      +     (ev.detail ? '<div class="detail">' + esc(ev.detail) + "</div>" : "")
      +   "</div>"
      + "</div>";
  }).join("");
}

function ciClass(state) {
  if (!state) return "unknown";
  const s = String(state).toLowerCase();
  if (s === "success") return "success";
  if (s === "failure") return "failure";
  if (s === "pending") return "pending";
  return "unknown";
}

function ciGlyph(state) {
  const c = ciClass(state);
  if (c === "pending") return "◐";
  if (c === "unknown") return "—";
  return "●";
}

function renderGithub(github) {
  if (!github || (!github.issues && !github.prs)) {
    return '<div class="gh-empty">GitHub data unavailable</div>';
  }
  const issues = github.issues || [];
  const prs = github.prs || [];

  let html = "";
  html += '<div class="gh-section"><div class="title">Issues (' + esc(issues.length) + ")</div></div>";
  if (issues.length) {
    html += issues.map((i) => ''
      + '<div class="row" data-url="' + esc(i.url || "") + '">'
      +   '<span class="num">#' + esc(i.num) + "</span>"
      +   '<span class="t">' + esc(i.title || "") + "</span>"
      + "</div>").join("");
  }

  html += '<div class="gh-section" style="margin-top:8px;"><div class="title">PRs (' + esc(prs.length) + ")</div></div>";
  if (prs.length) {
    html += prs.map((p) => {
      const cls = ciClass(p.ci_state);
      const glyph = ciGlyph(p.ci_state);
      return ''
        + '<div class="row" data-url="' + esc(p.url || "") + '">'
        +   '<span class="num">#' + esc(p.num) + "</span>"
        +   '<span class="t">' + esc(p.title || "") + "</span>"
        +   '<span class="ci ' + esc(cls) + '" title="CI: ' + esc(cls) + '">' + glyph + "</span>"
        + "</div>";
    }).join("");
  }
  return html;
}

function renderAlerts(errors) {
  const strip = $("alerts-strip");
  if (!strip) return;
  if (!errors || !errors.length) {
    strip.hidden = true;
    strip.innerHTML = "";
    return;
  }
  strip.hidden = false;
  strip.innerHTML = errors.map((e) => ''
    + '<div class="a err">❗ ' + esc(e.source || "error") + ": " + esc(e.message || "") + "</div>"
  ).join("");
}

/* ── Scroll preservation ───────────────────────────────────────────────── */

function snapshotScroll() {
  const snap = {};
  for (const id of SCROLL_PANEL_IDS) {
    const el = $(id);
    if (el) snap[id] = el.scrollTop;
  }
  /* Per-board-column scroll snapshot — the Todo column has its own
     overflow:auto. Key by full class string so a column re-rendered
     in the same slot keys identically. */
  const boardEl = $("board");
  if (boardEl) {
    snap.__cols = {};
    boardEl.querySelectorAll(".col").forEach((col) => {
      const body = col.querySelector(".col-body");
      const key = col.className;
      if (body) snap.__cols[key] = body.scrollTop;
    });
  }
  return snap;
}

function restoreScroll(snap) {
  if (!snap) return;
  for (const id of SCROLL_PANEL_IDS) {
    const el = $(id);
    if (el && typeof snap[id] === "number") {
      el.scrollTop = snap[id];
    }
  }
  const boardEl = $("board");
  if (boardEl && snap.__cols) {
    boardEl.querySelectorAll(".col").forEach((col) => {
      const body = col.querySelector(".col-body");
      const key = col.className;
      if (body && typeof snap.__cols[key] === "number") {
        body.scrollTop = snap.__cols[key];
      }
    });
  }
}

function logShouldStickToBottom(el) {
  if (!el) return true;
  const remaining = el.scrollHeight - (el.scrollTop + el.clientHeight);
  return remaining < 8;
}

/* ── Focus preservation ────────────────────────────────────────────────── */

function snapshotFocus() {
  /* Cards and GH rows are the only focusable interactive elements that
     get wiped per render — they all carry data-url. We key by data-url
     so the post-render lookup re-focuses the SAME logical card even if
     its DOM node changed. activeElement.tagName === "BODY" means no
     interactive focus to preserve. */
  const a = document.activeElement;
  if (!a || a === document.body || !a.getAttribute) return null;
  const url = a.getAttribute("data-url");
  return url ? { dataUrl: url } : null;
}

function restoreFocus(snap) {
  if (!snap || !snap.dataUrl) return;
  /* CSS.escape isn't bulletproof for attribute selectors with special
     chars — fall back to a manual scan if the lookup throws. */
  let target = null;
  try {
    const sel = '[data-url="' + (window.CSS && CSS.escape ? CSS.escape(snap.dataUrl) : snap.dataUrl) + '"]';
    target = document.querySelector(sel);
  } catch (e) {
    target = null;
  }
  if (!target) {
    const all = document.querySelectorAll("[data-url]");
    for (const el of all) {
      if (el.getAttribute("data-url") === snap.dataUrl) { target = el; break; }
    }
  }
  if (target && typeof target.focus === "function") {
    /* preventScroll keeps the snapshot/restore scroll dance authoritative. */
    target.focus({ preventScroll: true });
  }
}

/* ── Click delegation ──────────────────────────────────────────────────── */

function onClickDelegate(ev) {
  /* Single delegated handler — cards and GH rows expose data-url.
     window.open(_blank) opens in a new tab regardless of which inner
     element fired. */
  const t = ev.target.closest("[data-url]");
  if (!t) return;
  const url = t.getAttribute("data-url");
  if (!url) return;
  /* Defense-in-depth — backend SHOULD sanitize click_url, but the
     dashboard is reachable on localhost where any compromise of the
     state file or gh data could plant a `javascript:` URL. Restrict
     to http(s) absolute URLs and same-origin relative paths. */
  if (!/^(https?:\/\/|\/)/i.test(url)) return;
  window.open(url, "_blank", "noopener,noreferrer");
}

/* ── Top-level render ──────────────────────────────────────────────────── */

function renderAll(payload) {
  const snap = snapshotScroll();
  const focusSnap = snapshotFocus();
  const logEl = $("log-tail");
  const stickLog = logShouldStickToBottom(logEl);

  const meta = payload || {};
  const asOf = meta.as_of ? shortTime(meta.as_of) : "—";
  $("nav-as-of").textContent = "updated " + asOf;
  const planSummary = (meta.plan_status || []).map((p) => p.plan).filter(Boolean);
  $("nav-plan").textContent = planSummary.length
    ? "plan: " + planSummary.join(", ")
    : "plan: —";

  renderAlerts(meta.errors);

  const board = meta.board || {};
  let total = 0;
  const colHtml = COLUMN_DEFS.map((def) => {
    const cards = board[def.key] || [];
    total += cards.length;
    return renderColumn(def, cards);
  }).join("");
  $("board").innerHTML = colHtml;
  $("board-total").textContent = total;

  const planLines = (meta.plan_status || [])
    .map((p) => p.slug + " · " + (p.total || 0) + " tasks");
  $("board-plans-summary").textContent = planLines.join(" · ");

  $("workers").innerHTML = renderWorkers(meta.workers || []);
  $("workers-count").textContent = (meta.workers || []).length;
  $("plan-status").innerHTML = renderPlanStatus(meta.plan_status || []);
  $("plan-status-header").textContent = planSummary.join(", ");
  $("cost").innerHTML = renderCost(meta.cost || {});

  $("log-tail").innerHTML = renderLog(meta.log_tail || []);
  $("activity").innerHTML = renderActivity(meta.activity || []);
  $("github").innerHTML = renderGithub(meta.github || {});

  restoreScroll(snap);
  if (stickLog && logEl) {
    logEl.scrollTop = logEl.scrollHeight;
  }
  restoreFocus(focusSnap);
  hasRenderedSuccessfully = true;
}

function renderLoadingState(message) {
  /* Used on first paint and on /api/board 404 (T6 hasn't wired the
     blueprint yet). Keeps the panel chrome visible so the operator
     sees the dashboard is up and just needs the endpoint live.
     Resets the rendered-once flag so the next fetch failure can't be
     treated as "transient" — the panels are already empty. */
  const boardEl = $("board");
  if (boardEl) {
    while (boardEl.firstChild) boardEl.removeChild(boardEl.firstChild);
    const loadingDiv = document.createElement("div");
    loadingDiv.className = "global-loading";
    loadingDiv.textContent = String(message || "");
    boardEl.appendChild(loadingDiv);
  }
  for (const id of ["workers", "plan-status", "cost", "log-tail", "activity", "github"]) {
    const el = $(id);
    if (el) while (el.firstChild) el.removeChild(el.firstChild);
  }
  hasRenderedSuccessfully = false;
}

function renderTransientError(message) {
  /* Transient failure path — keep the last-known-good DOM intact, just
     flag the live-dot stale and surface the failure in the alerts strip.
     One 5xx or a network blip mustn't blank the operator's entire view. */
  setLiveDotStale(true);
  const strip = $("alerts-strip");
  if (!strip) return;
  strip.hidden = false;
  while (strip.firstChild) strip.removeChild(strip.firstChild);
  const row = document.createElement("div");
  row.className = "a err";
  row.textContent = "❗ fetch failed (showing stale data): " + String(message || "");
  strip.appendChild(row);
}

function setLiveDotStale(stale) {
  const meta = document.querySelector(".nav .meta");
  if (!meta) return;
  meta.classList.toggle("stale", !!stale);
}

/* ── Poll loop ─────────────────────────────────────────────────────────── */

async function pollOnce() {
  try {
    const res = await fetch(ENDPOINT, { cache: "no-store" });
    if (res.status === 404) {
      /* T6 hasn't wired the blueprint yet — operator sees the chrome +
         a pending message. Wipe panels because the endpoint is genuinely
         not available, not just transiently failing. */
      setLiveDotStale(true);
      renderLoadingState("Mission Centre endpoint /api/board not yet wired (T6 pending).");
      return;
    }
    if (!res.ok) {
      throw new Error("HTTP " + res.status);
    }
    const envelope = await res.json();
    if (envelope && envelope.data) {
      setLiveDotStale(false);
      renderAll(envelope.data);
    } else if (envelope && envelope.error) {
      /* Backend explicitly returned an error envelope. Treat as transient
         if we've shown data before — operator keeps last-known-good. */
      if (hasRenderedSuccessfully) {
        renderTransientError("endpoint error: " + envelope.error);
      } else {
        renderLoadingState("endpoint error: " + envelope.error);
      }
    } else {
      if (hasRenderedSuccessfully) {
        renderTransientError("unexpected response shape");
      } else {
        renderLoadingState("unexpected response shape");
      }
    }
  } catch (err) {
    const msg = (err && err.message) ? err.message : String(err);
    if (hasRenderedSuccessfully) {
      renderTransientError(msg);
    } else {
      renderLoadingState("fetch failed: " + msg);
    }
  }
}

function start() {
  document.addEventListener("click", onClickDelegate);
  renderLoadingState("loading…");
  pollOnce();
  setInterval(pollOnce, POLL_INTERVAL_MS);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
