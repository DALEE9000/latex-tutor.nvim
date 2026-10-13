/* latex-tutor GUI: your compiled PDF with Google-Docs-style comment cards in
 * the margin. State comes from nvim through the local server (SSE); clicks go
 * back as POST /action. */
"use strict";

pdfjsLib.GlobalWorkerOptions.workerSrc = "vendor/pdf.worker.min.js";

const $ = (s, el = document) => el.querySelector(s);
const scroller = $("#scroller");
const pagesEl = $("#pages");
const margin = $("#margin");
const narrowMq = matchMedia("(max-width: 980px)");

let S = {};                 // latest state from nvim
let doc = null;             // pdf.js document
let docVersion = -1;
let pages = [];             // { el, canvas, overlay, wPt, hPt, task, drawn }
let scale = 1;
const drafts = new Map();   // comment id -> unsent reply text
const revealed = new Set(); // "id:hint" / "id:fix" panels the user opened
let lastScrollKey = "";
let tick = null;

const SEV_VAR = { error: "--error", rigor: "--rigor", improve: "--improve", latex: "--latex", praise: "--praise" };
const sevColor = (s) => `var(${SEV_VAR[s] || "--improve"})`;
const pageColor = (s) => `var(--pg-${SEV_VAR[s] ? s : "improve"})`; // on the white page
const VERDICT = { correct: "✓ Correct", minor_issues: "Minor issues", major_issues: "Major issues", incomplete: "Incomplete" };
const STATUS = { open: "Open", edited: "Edited", fixed: "Fixed", praise: "Nice" };

function post(action, extra = {}) {
  return fetch("/action", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, ...extra }),
  }).catch(() => {});
}

/* ---- Markdown + KaTeX ----------------------------------------------------- */

const MATH_RE = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|(?<![\\$])\$(?!\s)((?:\\.|[^$\\\n])+?)\$/g;

function md(text) {
  if (!text) return "";
  const math = [];
  let src = String(text).replace(MATH_RE, (m, d1, d2, i1, i2) => {
    const display = d1 !== undefined || d2 !== undefined;
    math.push({ tex: d1 ?? d2 ?? i1 ?? i2, display });
    return `@@M${math.length - 1}@@`;
  });
  src = src.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  let html = marked.parse(src, { breaks: true, gfm: true });
  html = html.replace(/@@M(\d+)@@/g, (_, i) => {
    const m = math[+i];
    try {
      return katex.renderToString(m.tex, {
        displayMode: m.display, throwOnError: false, strict: false, trust: false,
        macros: Object.assign({}, S.macros || {}),
      });
    } catch {
      return `<code>${m.tex.replace(/</g, "&lt;")}</code>`;
    }
  });
  return html;
}

const esc = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/* ---- PDF ------------------------------------------------------------------ */

function availableWidth() {
  const sheetW = scroller.clientWidth;
  if (narrowMq.matches) return sheetW - 32;
  const marginW = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--margin-w")) || 340;
  return Math.min(920, sheetW - marginW - 28 - 48 - 16);
}

let docKey = "";            // which question the shown PDF is of ("file" = on-save build)

// Loads a new build without flicker: pages are drawn off-screen and swapped
// in only once they're rendered, so the window never shows a blank page.
async function loadPdf(version) {
  if (version === docVersion) return;
  docVersion = version;
  if (!version) return;
  const key = (S.pdf && S.pdf.key) || "";
  let next;
  try {
    next = await pdfjsLib.getDocument({ url: `/pdf?v=${version}`, isEvalSupported: false }).promise;
  } catch (e) {
    console.error("pdf load failed", e && e.message);
    showStatus("PDF could not be loaded", "error");
    render();
    return;
  }
  if (version !== docVersion) { next.destroy(); return; } // a newer build arrived meanwhile
  const sizes = [];
  for (let i = 1; i <= next.numPages; i++) {
    const p = await next.getPage(i);
    const v = p.getViewport({ scale: 1 });
    sizes.push([v.width, v.height]);
  }
  if (version !== docVersion) { next.destroy(); return; }
  const old = doc;
  const sameQuestion = key === docKey;
  const sameLayout = sameQuestion && pages.length === sizes.length &&
    pages.every((p, i) => Math.abs(p.wPt - sizes[i][0]) < 0.5 && Math.abs(p.hPt - sizes[i][1]) < 0.5);
  doc = next;
  docKey = key;
  if (sameLayout) {
    // Same pages: each canvas is replaced only when its new image is ready.
    await Promise.all(pages.filter((p) => p.visible).map((p) => drawPage(p)));
    for (const p of pages) if (!p.visible) p.drawn = 0;
  } else {
    const keep = sameQuestion ? scroller.scrollTop : 0;
    const first = sameQuestion ? Math.max(0, pages.findIndex((p) => p.visible)) : 0;
    const fresh = makePages(sizes);
    const want = scaleFor(fresh);
    scale = want;
    for (const p of fresh) sizePage(p);
    await Promise.all(fresh.slice(first, first + 3).map((p) => drawPage(p)));
    if (version !== docVersion) return;
    for (const p of pages) if (p.task) { try { p.task.cancel(); } catch {} }
    pages.forEach((p) => observer.unobserve(p.el));
    pagesEl.replaceChildren(...fresh.map((p) => p.el));
    pages = fresh;
    pages.forEach((p) => observer.observe(p.el));
    scroller.scrollTop = Math.min(keep, scroller.scrollHeight);
  }
  if (old && old !== doc) old.destroy();
  render();
}

function makePages(sizes) {
  return sizes.map(([w, h], i) => {
    const el = document.createElement("div");
    el.className = "page";
    el.dataset.page = i + 1;
    const canvas = document.createElement("canvas");
    const overlay = document.createElement("div");
    overlay.className = "overlay";
    const num = document.createElement("div");
    num.className = "num";
    num.textContent = `${i + 1} / ${sizes.length}`;
    el.append(canvas, overlay, num);
    el.addEventListener("dblclick", (e) => {
      const r = el.getBoundingClientRect();
      post("pdfclick", { page: i + 1, x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale });
    });
    return { el, canvas, overlay, wPt: w, hPt: h, task: null, drawn: 0 };
  });
}

// zoom = 1 is "fit to width"; the buttons, Ctrl +/−/0 and Ctrl+wheel (or a
// trackpad pinch) change it. Remembered per browser.
let zoom = 1;
try { zoom = Math.min(4, Math.max(0.5, +localStorage.getItem("lt-zoom") || 1)); } catch {}
const ZOOMS = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4];

function scaleFor(list) {
  const s = availableWidth() / Math.max(...list.map((p) => p.wPt));
  return Math.max(0.5, Math.min(s, 2.2)) * zoom;
}

// Keeps the point under (ax, ay) — viewport coordinates in the scroller —
// where it was, so zooming doesn't throw you to another part of the page.
function setZoom(z, ax, ay) {
  z = Math.min(4, Math.max(0.5, Math.round(z * 100) / 100));
  if (z === zoom) return;
  ax = ax ?? scroller.clientWidth / 2;
  ay = ay ?? scroller.clientHeight / 2;
  const fx = (scroller.scrollLeft + ax) / Math.max(1, scroller.scrollWidth);
  const fy = (scroller.scrollTop + ay) / Math.max(1, scroller.scrollHeight);
  zoom = z;
  try { localStorage.setItem("lt-zoom", String(z)); } catch {}
  sizePages();
  render();
  scroller.style.scrollBehavior = "auto";
  scroller.scrollLeft = fx * scroller.scrollWidth - ax;
  scroller.scrollTop = fy * scroller.scrollHeight - ay;
  scroller.style.scrollBehavior = "";
  renderZoom();
}

function stepZoom(dir) {
  const next = dir > 0 ? ZOOMS.find((v) => v > zoom + 0.001) : [...ZOOMS].reverse().find((v) => v < zoom - 0.001);
  if (next) setZoom(next);
}

function renderZoom() {
  $("#zoom-fit").textContent = `${Math.round(zoom * 100)}%`;
  $("#zoom-fit").title = zoom === 1 ? "Fit to width (Ctrl 0)" : "Back to fit width (Ctrl 0)";
  document.body.classList.toggle("zoomed", zoom > 1);
}

function sizePage(p) {
  p.el.style.width = `${p.wPt * scale}px`;
  p.el.style.height = `${p.hPt * scale}px`;
}

function sizePages() {
  if (!pages.length) return;
  scale = scaleFor(pages);
  for (const p of pages) {
    sizePage(p);
    if (p.drawn && p.drawn !== scale && p.visible) drawPage(p);
  }
}

const observer = new IntersectionObserver((entries) => {
  for (const e of entries) {
    const p = pages.find((x) => x.el === e.target);
    if (!p) continue;
    p.visible = e.isIntersecting;
    if (e.isIntersecting && p.drawn !== scale) drawPage(p);
  }
}, { root: scroller, rootMargin: "600px 0px" });

async function drawPage(p) {
  if (!doc) return;
  if (p.task) { try { p.task.cancel(); } catch {} }
  const want = scale;
  const d = doc;
  const page = await d.getPage(+p.el.dataset.page);
  if (d !== doc) return;
  const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
  const vp = page.getViewport({ scale: want * dpr });
  const c = document.createElement("canvas");
  c.width = Math.floor(vp.width);
  c.height = Math.floor(vp.height);
  p.task = page.render({ canvasContext: c.getContext("2d", { alpha: false }), viewport: vp });
  try {
    await p.task.promise;
  } catch {
    return; // cancelled
  }
  p.task = null;
  if (want !== scale) return;
  p.canvas.replaceWith(c);
  p.canvas = c;
  p.drawn = want;
}

/* ---- Rendering the state -------------------------------------------------- */

function visibleComments() {
  return (S.comments || []);
}

function anchorY(c) {
  const b = c && c.boxes && c.boxes[0];
  if (!b || !pages[b.page - 1]) return null;
  return pages[b.page - 1].el.offsetTop + b.y * scale - margin.offsetTop;
}

function drawOverlays() {
  for (const p of pages) p.overlay.innerHTML = "";
  const slots = new Map(); // badges on the same line sit side by side
  for (const c of visibleComments()) {
    (c.boxes || []).forEach((b, k) => {
      const p = pages[b.page - 1];
      if (!p) return;
      const hl = document.createElement("div");
      hl.className = "hl" + (c.id === S.active ? " active" : "") + (c.status === "fixed" ? " fixed" : "");
      hl.style.setProperty("--c", pageColor(c.severity));
      hl.style.left = `${b.x * scale - 3}px`;
      hl.style.top = `${b.y * scale - 2}px`;
      hl.style.width = `${b.w * scale + 6}px`;
      hl.style.height = `${b.h * scale + 4}px`;
      hl.title = c.title;
      hl.addEventListener("click", () => activate(c.id, true));
      p.overlay.append(hl);
      if (k === 0) {
        const badge = document.createElement("div");
        badge.className = "badge";
        badge.textContent = c.n;
        badge.style.setProperty("--c", c.status === "fixed" ? "var(--pg-praise)" : pageColor(c.severity));
        const key = `${b.page}:${Math.round(b.y)}`;
        const slot = slots.get(key) || 0;
        slots.set(key, slot + 1);
        badge.style.left = `${Math.min(p.wPt * scale - 16, (b.x + b.w) * scale + 16) + slot * 24}px`;
        if (c.id === S.active) badge.style.zIndex = 2;
        badge.style.top = `${(b.y + b.h / 2) * scale}px`;
        badge.addEventListener("click", () => activate(c.id, true));
        p.overlay.append(badge);
      }
    });
  }
}

function cardHTML(c) {
  const active = c.id === S.active;
  const status = c.severity === "praise" && c.status !== "fixed" ? "praise" : c.status;
  let h = `<div class="head">
      <span class="num-pill">${c.n}</span>
      <span class="title">${esc(c.title)}</span>
      <span class="status ${status}">${STATUS[status] || status}</span>
    </div>`;
  if (!active) return h;
  h += `<div class="meta"><span class="sev">${esc(c.sevlabel)}</span><span>·</span><span>line ${c.row + 1}</span>${
    c.confidence ? `<span>·</span><span>${esc(c.confidence)} confidence</span>` : ""}${
    c.moved ? `<span>·</span><span>text changed since review</span>` : ""}</div>`;
  h += `<div class="body">${md(c.body)}</div>`;
  const hasHint = c.hint && c.hint.trim(), hasFix = c.fix && c.fix.trim();
  if (hasHint || hasFix) {
    h += `<div class="reveal">`;
    if (hasHint) h += `<button class="btn small" data-reveal="hint">${revealed.has(c.id + ":hint") ? "Hide hint" : "Show hint"}</button>`;
    if (hasFix) h += `<button class="btn small" data-reveal="fix">${revealed.has(c.id + ":fix") ? "Hide fix" : "Show suggested fix"}</button>`;
    h += `</div>`;
    if (hasHint && revealed.has(c.id + ":hint")) h += `<div class="panel"><div class="label">Hint</div>${md(c.hint)}</div>`;
    if (hasFix && revealed.has(c.id + ":fix")) h += `<div class="panel"><div class="label">Suggested fix</div><pre>${esc(c.fix)}</pre></div>`;
  }
  if ((c.thread || []).length || c.pending) {
    h += `<div class="thread">`;
    for (const t of c.thread || []) {
      const you = t.role === "you";
      h += `<div class="msg ${you ? "you" : ""}"><div class="avatar">${you ? "Y" : "T"}</div><div>
        <div class="who">${you ? "You" : "Tutor"}</div><div class="text body">${md(t.text)}</div></div></div>`;
    }
    if (c.pending) h += `<div class="thinking"><span class="spin"></span>Tutor is thinking…</div>`;
    h += `</div>`;
  }
  if (c.status === "edited") {
    h += `<div class="row"><span class="hint-keys">You edited this line. <b>Check my fixes</b> asks the tutor.</span></div>`;
  }
  h += `<div class="reply"><textarea rows="1" placeholder="Reply, or explain your fix…">${esc(drafts.get(c.id) || "")}</textarea></div>
    <div class="row">
      <button class="btn small primary" data-act="send">Reply</button>
      <button class="btn small" data-act="resolve">${c.status === "fixed" ? "Reopen" : "Resolve"}</button>
      <span class="grow"></span>
      <button class="btn small ghost" data-act="jump" title="Move the nvim cursor here">Go to line ${c.row + 1}</button>
    </div>
    <div class="row"><span class="hint-keys"><kbd>Ctrl</kbd>+<kbd>Enter</kbd> sends · <kbd>J</kbd>/<kbd>K</kbd> next/previous · <kbd>R</kbd> resolve</span></div>`;
  return h;
}

function renderMargin() {
  // Keep the textarea draft and focus across re-renders.
  const focused = document.activeElement && document.activeElement.closest && document.activeElement.closest(".card");
  const focusedId = focused && focused.dataset.id;
  const sheetScroll = margin.scrollTop; // emptying the sheet would reset it
  margin.innerHTML = "";
  const items = [];
  const groups = S.show_all ? (S.groups || []) : null;

  const addSummary = (u, sum, anchorFrom) => {
    if (!sum) return;
    const el = document.createElement("div");
    el.className = "summary-card";
    el.innerHTML = `<div class="label${u && u.section ? " sec" : ""}">${esc(titleOf(u))} · ${esc(VERDICT[sum.verdict] || sum.verdict || "")}</div>
      <div class="text body">${md(sum.summary)}</div><div class="when">Reviewed ${esc(sum.ago || "")}</div>`;
    margin.append(el);
    items.push({ el, anchor: anchorFrom });
  };

  const addCard = (c) => {
    const el = document.createElement("div");
    el.className = "card" + (c.id === S.active ? " active" : "") + (c.status === "fixed" ? " fixed" : "");
    el.dataset.id = c.id;
    el.style.setProperty("--c", sevColor(c.severity));
    el.innerHTML = cardHTML(c);
    el.addEventListener("click", (e) => {
      if (e.target.closest("button, textarea, a")) return;
      if (c.id !== S.active) activate(c.id, true);
    });
    wireCard(el, c);
    margin.append(el);
    items.push({ el, anchor: anchorY(c), id: c.id });
  };

  if (groups) {
    for (const g of groups) {
      const lab = document.createElement("div");
      lab.className = "group-label" + (g.section ? " sec" : "");
      lab.textContent = titleOf(g);
      margin.append(lab);
      const first = (S.comments || []).find((c) => c.group === g.label);
      items.push({ el: lab, anchor: first ? anchorY(first) : null });
      addSummary(g, g.summary, first ? anchorY(first) : null);
      for (const c of S.comments || []) if (c.group === g.label) addCard(c);
    }
  } else {
    const fb = S.focus && S.focus.box;
    const fy = fb && pages[fb.page - 1] ? pages[fb.page - 1].el.offsetTop + fb.y * scale - margin.offsetTop : null;
    addSummary(S.focus, S.summary, fy);
    for (const c of visibleComments()) addCard(c);
    if (!S.summary && !(S.comments || []).length && S.focus) {
      const el = document.createElement("div");
      el.className = "summary-card";
      el.innerHTML = `<div class="label${S.focus.section ? " sec" : ""}">${esc(titleOf(S.focus))}</div>
        <div class="text">Not reviewed yet. Press <b>Review</b> (or <kbd>Space</kbd> <kbd>c</kbd> <kbd>c</kbd> in nvim).</div>`;
      margin.append(el);
      items.push({ el, anchor: fy });
    }
  }
  layout(items);
  margin.scrollTop = sheetScroll;
  if (narrowMq.matches) {
    // Bottom sheet: bring the active card to the top of the sheet.
    const act = margin.querySelector(".card.active");
    if (act && act.dataset.id !== margin.dataset.shown) {
      margin.dataset.shown = act.dataset.id;
      margin.scrollTo({ top: act.offsetTop - 12 });
    }
  }
  $("#sheet-toggle").hidden = !narrowMq.matches;
  $("#sheet-toggle").textContent = margin.classList.contains("closed")
    ? `Comments (${(S.comments || []).filter((c) => c.status !== "fixed").length})` : "Hide";
  if (focusedId) {
    const ta = margin.querySelector(`.card[data-id="${CSS.escape(focusedId)}"] textarea`);
    if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }
  }
}

// Google-Docs placement: every item sits at its anchor; the active card wins
// and the others are pushed up/down so nothing overlaps.
function layout(items) {
  if (narrowMq.matches) { margin.style.height = ""; return; }
  const GAP = 10;
  let prevBottom = 0;
  const tops = items.map((it) => {
    const a = it.anchor == null ? prevBottom : it.anchor;
    const t = Math.max(a, prevBottom);
    prevBottom = t + it.el.offsetHeight + GAP;
    return t;
  });
  const ai = items.findIndex((it) => it.id && it.id === S.active);
  if (ai >= 0 && items[ai].anchor != null) {
    tops[ai] = Math.max(0, items[ai].anchor);
    for (let i = ai + 1; i < items.length; i++) {
      tops[i] = Math.max(tops[i], tops[i - 1] + items[i - 1].el.offsetHeight + GAP);
    }
    for (let i = ai - 1; i >= 0; i--) {
      tops[i] = Math.min(tops[i], tops[i + 1] - items[i].el.offsetHeight - GAP);
    }
    if (tops[0] < 0) {
      const d = -tops[0];
      for (let i = 0; i < tops.length; i++) tops[i] += d;
    }
  }
  items.forEach((it, i) => { it.el.style.top = `${tops[i]}px`; });
  const bottom = items.length ? tops[items.length - 1] + items[items.length - 1].el.offsetHeight : 0;
  margin.style.height = `${Math.max(bottom + 40, pagesEl.offsetHeight)}px`;
}

function wireCard(el, c) {
  el.querySelectorAll("[data-reveal]").forEach((b) => b.addEventListener("click", () => {
    const k = c.id + ":" + b.dataset.reveal;
    revealed.has(k) ? revealed.delete(k) : revealed.add(k);
    renderMargin();
  }));
  const ta = el.querySelector("textarea");
  if (ta) {
    const grow = () => { ta.style.height = "auto"; ta.style.height = `${Math.min(160, ta.scrollHeight + 2)}px`; };
    ta.addEventListener("input", () => { drafts.set(c.id, ta.value); grow(); });
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); send(c, ta); }
      if (e.key === "Escape") ta.blur();
    });
    requestAnimationFrame(grow);
  }
  el.querySelectorAll("[data-act]").forEach((b) => b.addEventListener("click", () => {
    const act = b.dataset.act;
    if (act === "send") send(c, ta);
    else if (act === "resolve") post("resolve", { id: c.id });
    else if (act === "jump") post("jump", { id: c.id });
  }));
}

function send(c, ta) {
  const text = (ta && ta.value || "").trim();
  if (!text) return;
  drafts.delete(c.id);
  ta.value = "";
  post("reply", { id: c.id, text });
}

function activate(id, tellNvim) {
  S.active = id;
  drawOverlays();
  renderMargin();
  scrollToActive(true);
  if (tellNvim) post("jump", { id });
}

function scrollToActive(force) {
  const c = (S.comments || []).find((x) => x.id === S.active);
  let y = c ? anchorY(c) : null;
  const fb = S.focus && S.focus.box;
  if (y == null && fb && pages[fb.page - 1]) y = pages[fb.page - 1].el.offsetTop + fb.y * scale - margin.offsetTop;
  if (y == null) return;
  // Only when you switch comment or question, not on every rebuild while you
  // type (that's what kept throwing the view back up).
  const key = `${S.focus && S.focus.label}|${S.active}`;
  if (!force && key === lastScrollKey) return;
  lastScrollKey = key;
  const top = y + margin.offsetTop;
  const view = scroller.scrollTop, h = scroller.clientHeight;
  if (force || top < view + 40 || top > view + h * 0.7) {
    scroller.scrollTo({ top: Math.max(0, top - h * 0.28) });
  }
}

// What to show for a question/section: its clean heading if it has one.
const titleOf = (u) => (u ? u.title || u.label || "" : "");

function renderBar() {
  $("#file").textContent = S.name || "—";
  $("#file").title = S.file || "";
  $("#model").textContent = S.model || "";
  const picker = $("#picker");
  const qs = S.questions || [];
  picker.innerHTML = qs.map((q) => {
    const mark = q.total ? ` · ${q.fixed}/${q.total}` : (q.verdict ? " · ✓" : "");
    return `<option value="${q.line}"${q.section ? ' class="sec"' : ""} ${S.focus && q.label === S.focus.label ? "selected" : ""}>${esc(titleOf(q))}${mark}</option>`;
  }).join("");
  picker.hidden = !qs.length;
  const v = $("#verdict");
  if (S.summary && !S.show_all) {
    v.hidden = false;
    v.dataset.v = S.summary.verdict;
    v.textContent = VERDICT[S.summary.verdict] || S.summary.verdict;
  } else v.hidden = true;
  const list = (S.comments || []).filter((c) => c.severity !== "praise");
  const fixed = list.filter((c) => c.status === "fixed").length;
  const prog = $("#progress");
  prog.hidden = !list.length;
  $("#progress-fill").style.width = list.length ? `${(fixed / list.length) * 100}%` : "0";
  const edited = list.filter((c) => c.status === "edited").length;
  $("#progress-text").textContent = `${fixed}/${list.length} fixed${edited ? ` · ${edited} edited` : ""}`;
  $("#btn-all").setAttribute("aria-pressed", S.show_all ? "true" : "false");
  const busy = (S.running || []).length > 0;
  $("#btn-review").disabled = busy;
  $("#btn-check").disabled = busy || !list.some((c) => c.status !== "fixed");
  renderStatus();
}

function showStatus(text, kind) {
  const el = $("#status");
  el.hidden = !text;
  el.className = "chip" + (kind === "error" ? " error" : "");
  el.innerHTML = kind === "busy" ? `<span class="spin"></span>${esc(text)}` : esc(text);
  el.title = text || "";
}

function renderStatus() {
  const run = (S.running || [])[0];
  if (run) {
    const secs = Math.max(0, Math.round(Date.now() / 1000 - run.since));
    showStatus(`${run.text} · ${secs}s`, "busy");
  } else if (S.pdf && S.pdf.building) showStatus("Building PDF…", "busy");
  else if (S.pdf && S.pdf.error && S.pdf.live) showStatus(`Showing last good version · ${S.pdf.error}`, "error");
  else if (S.pdf && S.pdf.error) showStatus(`PDF: ${S.pdf.error}`, "error");
  else showStatus("");
  clearInterval(tick);
  if (run) tick = setInterval(renderStatus, 1000);
}

function render() {
  $("#empty") && ($("#empty").style.display = pages.length ? "none" : "");
  drawOverlays();
  renderMargin();
  scrollToActive(false);
  followCursor();
}

// Keeps the line you're typing on in view. It scrolls only when that line is
// off-screen, and only after you move or type, so it never fights your own
// scrolling of the window.
let lastCursorKey = "";
function followCursor() {
  const b = S.cursor_box;
  if (!b || !pages[b.page - 1] || !$("#report").hidden) return;
  const key = `${S.cursor}|${docVersion}`;
  if (key === lastCursorKey) return;
  lastCursorKey = key;
  const p = pages[b.page - 1].el;
  const top = p.offsetTop + b.y * scale, bottom = top + b.h * scale;
  const view = scroller.scrollTop, h = scroller.clientHeight;
  const narrowSheet = narrowMq.matches && !margin.classList.contains("closed");
  const usable = narrowSheet ? h * 0.5 : h;   // the bottom sheet covers the rest
  if (top < view + 24 || bottom > view + usable - 24) {
    scroller.scrollTo({ top: Math.max(0, top - usable * 0.35) });
  }
  // Zoomed in: bring it into view sideways too.
  const left = p.offsetLeft + b.x * scale, right = left + b.w * scale;
  if (left < scroller.scrollLeft || right > scroller.scrollLeft + scroller.clientWidth) {
    scroller.scrollTo({ left: Math.max(0, left - 40) });
  }
}

function apply(next) {
  const prevVersion = docVersion;
  S = next;
  renderBar();
  // A new PDF draws its overlays once its pages are in (no flash of stale marks).
  if (S.pdf && S.pdf.version && S.pdf.version !== prevVersion) loadPdf(S.pdf.version);
  else render();
}

/* ---- events --------------------------------------------------------------- */

function connect() {
  const es = new EventSource("/events");
  es.addEventListener("state", (e) => apply(JSON.parse(e.data)));
  es.addEventListener("progress", (e) => openReport(JSON.parse(e.data).md));
  es.addEventListener("math", (e) => openMath(JSON.parse(e.data)));
  es.addEventListener("draw", (e) => drawEvent(JSON.parse(e.data)));
  es.addEventListener("build", () => { if (S.pdf) { S.pdf.building = true; renderStatus(); } });
  es.onerror = () => showStatus("Disconnected — is nvim still running?", "error");
  // nvim quit: close this window. A browser may refuse for a tab it didn't
  // open by script, so say what happened instead.
  es.addEventListener("bye", () => {
    es.close();
    window.close();
    setTimeout(() => {
      showStatus("nvim closed — you can close this window", "error");
      document.body.classList.add("closed");
    }, 300);
  });
  es.onopen = () => renderStatus();
}

$("#btn-review").addEventListener("click", () => post("review"));
$("#btn-check").addEventListener("click", () => post("check"));
$("#btn-all").addEventListener("click", () => post("show_all"));
$("#btn-progress").addEventListener("click", () => post("progress"));
$("#btn-draw").addEventListener("click", () => openDraw());
$("#draw-close").addEventListener("click", () => closeDraw());
$("#drawview").addEventListener("click", (e) => { if (e.target.id === "drawview") closeDraw(); });
$("#zoom-in").addEventListener("click", () => stepZoom(1));
$("#zoom-out").addEventListener("click", () => stepZoom(-1));
$("#zoom-fit").addEventListener("click", () => setZoom(1));
// Ctrl+wheel and trackpad pinch zoom the PDF, not the whole window.
let wheelZoom = null;
scroller.addEventListener("wheel", (e) => {
  if (!e.ctrlKey && !e.metaKey) return;
  e.preventDefault();
  const r = scroller.getBoundingClientRect();
  wheelZoom = { z: (wheelZoom ? wheelZoom.z : zoom) * Math.exp(-e.deltaY * 0.0025), x: e.clientX - r.left, y: e.clientY - r.top };
  if (!wheelZoom.raf) wheelZoom.raf = requestAnimationFrame(() => {
    const w = wheelZoom; wheelZoom = null;
    setZoom(w.z, w.x, w.y);
  });
}, { passive: false });
$("#report-close").addEventListener("click", () => closeReport());
$("#math-close").addEventListener("click", () => closeMath());
$("#mathview").addEventListener("click", (e) => { if (e.target.id === "mathview") closeMath(); });
$("#report").addEventListener("click", (e) => { if (e.target.id === "report") closeReport(); });
$("#picker").addEventListener("change", (e) => post("jump_line", { line: +e.target.value }));
$("#sheet-toggle").addEventListener("click", () => { margin.classList.toggle("closed"); renderMargin(); });

/* ---- progress report ------------------------------------------------------ */

function openReport(text) {
  const body = $("#report-body");
  body.innerHTML = md(text);
  // Wide tables scroll sideways inside the card instead of widening the page.
  body.querySelectorAll("table").forEach((t) => {
    const wrap = document.createElement("div");
    wrap.className = "table-wrap";
    t.replaceWith(wrap);
    wrap.append(t);
  });
  $("#report").hidden = false;
  document.body.classList.add("report-open");
  body.scrollTop = 0;
  $("#report-close").focus();
}

/* ---- Σ evaluate / derive answers ----------------------------------------- */

function tex(s, display) {
  try {
    return katex.renderToString(s || "", { displayMode: display, throwOnError: false, strict: false,
      macros: Object.assign({}, S.macros || {}, mathMacros) });
  } catch { return `<code>${esc(s || "")}</code>`; }
}
let mathMacros = {};

function openMath(m) {
  const o = m.out || {};
  mathMacros = m.macros || {};
  const steps = (o.steps || []).map((s) =>
    `<li><div class="m-step">${tex(s.math, true)}</div>${s.note ? `<div class="m-note">${md(s.note)}</div>` : ""}</li>`).join("");
  $("#math-body").innerHTML = `
    <h1>Σ ${esc(m.ask || "Evaluate")}</h1>
    <div class="m-src">${tex(m.text, true)}</div>
    <div class="m-result"><span class="m-eq">=</span>${tex(o.result, true)}</div>
    ${steps ? `<h2>Steps</h2><ol class="m-steps">${steps}</ol>` : ""}
    <h2>Check</h2><div class="m-check">${md(o.check || "")} <span class="chip m-conf">${esc(o.confidence || "")} confidence</span></div>
    ${o.caveat ? `<div class="m-caveat">${md(o.caveat)}</div>` : ""}
    <h2>LaTeX to insert</h2>
    <pre class="m-latex">${esc(o.latex || "")}</pre>
    <div class="m-actions">
      <button class="btn primary" id="math-insert">Insert below line ${m.line}</button>
      <button class="btn" id="math-copy">Copy LaTeX</button>
    </div>`;
  $("#math-insert").addEventListener("click", () => { post("math_insert"); closeMath(); });
  $("#math-copy").addEventListener("click", async (ev) => {
    try { await navigator.clipboard.writeText(o.latex || ""); ev.target.textContent = "Copied"; }
    catch { ev.target.textContent = "Copy failed: select the text above"; }
  });
  $("#mathview").hidden = false;
  document.body.classList.add("report-open");
  $("#math-body").scrollTop = 0;
}

function closeMath() {
  $("#mathview").hidden = true;
  if ($("#report").hidden) document.body.classList.remove("report-open");
}

/* ---- ✎ Draw: TikZ from words or a sketch -------------------------------- */
// nvim runs the tutor and the compile (draw.lua); this panel collects the
// request (words, a webcam photo, a file, a paste) and shows the result.

let DS = { status: "idle" };      // last state from nvim
let draft = { text: "", image: null, busy: false, err: "" }; // the request being written
let view = "form";                // "form" or "result"
let camStream = null;

const fileUrl = (n) => `/draw-file?n=${encodeURIComponent(n)}`;

function drawEvent(d) {
  DS = d || { status: "idle" };
  if (DS.image && DS.status === "idle") draft.image = DS.image;   // :Tutor draw path
  view = DS.status === "idle" ? "form" : "result";
  if (d.open || !$("#drawview").hidden) openDraw(true);
}

function openDraw(keep) {
  if (!keep) view = DS.status === "idle" || !DS.status ? "form" : "result";
  $("#drawview").hidden = false;
  document.body.classList.add("report-open");
  renderDraw();
}

function closeDraw() {
  stopCamera();
  $("#drawview").hidden = true;
  if ($("#report").hidden && $("#mathview").hidden) document.body.classList.remove("report-open");
}

function imgTag(name, alt, cls) {
  if (!name) return "";
  return /\.pdf$/i.test(name)
    ? `<div class="d-pdf ${cls || ""}">📄 ${esc(name)} (PDF scan)</div>`
    : `<img class="${cls || ""}" src="${fileUrl(name)}" alt="${esc(alt)}">`;
}

function renderDraw() {
  const body = $("#draw-body");
  const sel = document.activeElement && document.activeElement.id;
  if (view === "form") {
    body.innerHTML = `
      <h1>✎ Draw with TikZ</h1>
      <p class="d-lead">Describe the diagram, or add a photo or scan of your sketch (or both). The tutor writes TikZ in your document's style and compiles it with your header.</p>
      <textarea id="draw-text" rows="3" placeholder="e.g. a block on a 30° incline with gravity, normal force and friction arrows">${esc(draft.text)}</textarea>
      <div class="d-row">
        <button class="btn" id="draw-cam">📷 Camera</button>
        <label class="btn" id="draw-file-btn">🖼 Add image<input type="file" id="draw-file" accept="image/*,application/pdf" capture="environment" hidden></label>
        <span class="d-hint">or paste / drop a picture here</span>
      </div>
      <div id="draw-camview" class="d-cam" hidden>
        <video id="draw-video" autoplay playsinline muted></video>
        <div class="d-row"><button class="btn primary" id="draw-snap">Take photo</button><button class="btn" id="draw-camstop">Cancel</button></div>
      </div>
      ${draft.image ? `<div class="d-chosen">${imgTag(draft.image, "your sketch", "d-thumb")}<button class="btn" id="draw-noimg">Remove</button></div>` : ""}
      ${draft.err ? `<div class="m-caveat">${esc(draft.err)}</div>` : ""}
      <div class="m-actions">
        <button class="btn primary" id="draw-go" ${draft.busy ? "disabled" : ""}>${draft.busy ? "Uploading…" : "Draw it"}</button>
        ${DS.tikz ? `<button class="btn" id="draw-back">Back to the last drawing</button>` : ""}
        <span class="d-hint">Ctrl+Enter</span>
      </div>`;
    const ta = $("#draw-text");
    ta.addEventListener("input", () => { draft.text = ta.value; });
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); goDraw(); } });
    $("#draw-go").addEventListener("click", goDraw);
    $("#draw-cam").addEventListener("click", startCamera);
    $("#draw-file").addEventListener("change", (e) => { const f = e.target.files[0]; if (f) addImage(f); });
    if ($("#draw-noimg")) $("#draw-noimg").addEventListener("click", () => { draft.image = null; renderDraw(); });
    if ($("#draw-back")) $("#draw-back").addEventListener("click", () => { view = "result"; renderDraw(); });
    if (sel !== "draw-text") setTimeout(() => ta.focus(), 0);
    return;
  }
  const d = DS;
  const working = d.status === "working";
  const both = d.image && d.preview;
  body.innerHTML = `
    <h1>✎ ${esc(d.summary || (working ? "Drawing…" : "Drawing"))}</h1>
    ${d.desc ? `<div class="d-ask">“${esc(d.desc)}”</div>` : ""}
    ${working ? `<div class="d-status"><span class="spin"></span>${esc(d.step || "Working")}…<button class="btn" id="draw-cancel">Cancel</button></div>` : ""}
    ${d.status === "error" ? `<div class="m-caveat">${esc(d.error || "Something went wrong")}</div>` : ""}
    <div class="d-compare ${both ? "two" : ""}">
      ${d.image ? `<figure><figcaption>Your sketch</figcaption>${imgTag(d.image, "your sketch")}</figure>` : ""}
      ${d.preview ? `<figure><figcaption>${working ? "Current version" : "Compiled with your header"}</figcaption><img class="d-out" src="${fileUrl(d.preview)}" alt="the TikZ drawing"></figure>`
        : (working ? `<figure class="d-wait"><figcaption>Result</figcaption><div class="d-placeholder">The drawing appears here once it compiles</div></figure>` : "")}
    </div>
    ${d.notes ? `<div class="m-caveat">${md(d.notes)}</div>` : ""}
    ${d.missing ? `<div class="d-note">Uses <code>\\usetikzlibrary{${esc(d.missing.join(","))}}</code>, which your header doesn't load. Insert adds that line right above the drawing.</div>` : ""}
    ${d.tikz ? `<h2>TikZ</h2><pre class="m-latex">${esc(d.tikz)}</pre>` : ""}
    ${d.tikz && !working ? `
      <div class="d-refine">
        <input id="draw-refine" type="text" placeholder="Change something: “make the friction arrow dashed”, “label the angle θ”">
        <button class="btn" id="draw-refine-go">Refine</button>
      </div>
      <div class="m-actions">
        <button class="btn primary" id="draw-insert">Insert below line ${d.line || "?"}</button>
        <button class="btn" id="draw-copy">Copy TikZ</button>
        <button class="btn" id="draw-new">New drawing</button>
      </div>` : (!working ? `<div class="m-actions"><button class="btn" id="draw-new">New drawing</button></div>` : "")}`;
  const on = (id, f) => { const el = $("#" + id); if (el) el.addEventListener("click", f); };
  on("draw-cancel", () => post("draw_cancel"));
  on("draw-insert", () => { post("draw_insert"); closeDraw(); });
  on("draw-copy", async (ev) => {
    try { await navigator.clipboard.writeText(d.tikz || ""); ev.target.textContent = "Copied"; }
    catch { ev.target.textContent = "Copy failed: select the code above"; }
  });
  on("draw-new", () => { draft = { text: "", image: null, busy: false, err: "" }; view = "form"; renderDraw(); });
  const rf = $("#draw-refine");
  const refine = () => { const t = rf.value.trim(); if (t) post("draw_refine", { text: t }); };
  if (rf) {
    on("draw-refine-go", refine);
    rf.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); refine(); } });
  }
}

function goDraw() {
  if (draft.busy) return;
  const text = (draft.text || "").trim();
  if (!text && !draft.image) { draft.err = "Describe the diagram or add a picture of it."; renderDraw(); return; }
  draft.err = "";
  stopCamera();
  post("draw", { text, image: draft.image });
  DS = { status: "working", step: draft.image ? "Reading your sketch" : "Drawing", desc: text, image: draft.image };
  view = "result";
  renderDraw();
}

// Photos are shrunk to 1600 px before upload: plenty for a sketch, and fast.
async function shrink(blob) {
  const bmp = await createImageBitmap(blob, { imageOrientation: "from-image" });
  const k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
  const c = document.createElement("canvas");
  c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
  c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((res) => c.toBlob(res, "image/jpeg", 0.9));
}

async function addImage(file) {
  draft.busy = true; draft.err = ""; renderDraw();
  try {
    let blob = file;
    if (/^image\//.test(file.type) && file.type !== "image/gif") blob = await shrink(file);
    else if (file.type !== "application/pdf" && file.type !== "image/gif") throw new Error("type");
    const r = await fetch("/upload", { method: "POST", headers: { "Content-Type": blob.type }, body: blob });
    if (!r.ok) throw new Error(await r.text());
    draft.image = (await r.json()).name;
  } catch (e) {
    draft.err = e.message === "type" || /decode|source image/i.test(e.message || "")
      ? "Can't read that file. Use a JPEG, PNG, WebP or PDF (iPhone HEIC photos: export as JPEG)."
      : `Upload failed: ${e.message || e}`;
  }
  draft.busy = false;
  renderDraw();
}

async function startCamera() {
  try {
    camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1920 }, height: { ideal: 1080 } } });
  } catch (e) {
    draft.err = "No camera available (or permission was denied). You can add an image file instead.";
    return renderDraw();
  }
  $("#draw-camview").hidden = false;
  const v = $("#draw-video");
  v.srcObject = camStream;
  $("#draw-snap").addEventListener("click", async () => {
    const c = document.createElement("canvas");
    c.width = v.videoWidth; c.height = v.videoHeight;
    c.getContext("2d").drawImage(v, 0, 0);
    const blob = await new Promise((res) => c.toBlob(res, "image/jpeg", 0.92));
    stopCamera();
    addImage(blob);
  });
  $("#draw-camstop").addEventListener("click", () => { stopCamera(); $("#draw-camview").hidden = true; });
}

function stopCamera() {
  if (camStream) camStream.getTracks().forEach((t) => t.stop());
  camStream = null;
}

document.addEventListener("paste", (e) => {
  if ($("#drawview").hidden || view !== "form") return;
  const item = [...(e.clipboardData || {}).items || []].find((i) => i.kind === "file");
  if (item) { e.preventDefault(); addImage(item.getAsFile()); }
});
$("#drawview").addEventListener("dragover", (e) => { if (view === "form") e.preventDefault(); });
$("#drawview").addEventListener("drop", (e) => {
  if (view !== "form") return;
  e.preventDefault();
  const f = e.dataTransfer.files[0];
  if (f) addImage(f);
});

function closeReport() {
  $("#report").hidden = true;
  document.body.classList.remove("report-open");
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#drawview").hidden) { closeDraw(); e.preventDefault(); return; }
  if (e.key === "Escape" && !$("#mathview").hidden) { closeMath(); e.preventDefault(); return; }
  if (e.key === "Escape" && !$("#report").hidden) { closeReport(); e.preventDefault(); return; }
  if (e.ctrlKey || e.metaKey) {
    if (e.key === "=" || e.key === "+") { stepZoom(1); e.preventDefault(); }
    else if (e.key === "-" || e.key === "_") { stepZoom(-1); e.preventDefault(); }
    else if (e.key === "0") { setZoom(1); e.preventDefault(); }
    return;
  }
  if (e.target.closest("textarea, input, select")) return;
  if (e.key === "p" || e.key === "P") { post("progress"); e.preventDefault(); return; }
  if (!$("#report").hidden || !$("#mathview").hidden || !$("#drawview").hidden) return;
  if (e.key === "t" || e.key === "T") { openDraw(); e.preventDefault(); return; }
  const list = S.comments || [];
  const i = list.findIndex((c) => c.id === S.active);
  if (e.key === "j" || e.key === "J") { const c = list[Math.min(list.length - 1, i + 1)]; if (c) activate(c.id, true); }
  else if (e.key === "k" || e.key === "K") { const c = list[Math.max(0, i - 1)]; if (c) activate(c.id, true); }
  else if ((e.key === "r" || e.key === "R") && i >= 0) post("resolve", { id: list[i].id });
  else if (e.key === "v" || e.key === "V") post("check");
  else if (e.key === "a" || e.key === "A") post("show_all");
  else return;
  e.preventDefault();
});

// The top bar wraps onto more rows in narrow windows; everything below it is
// placed with --bar-h, so keep that equal to its real height.
let barH = 0;
new ResizeObserver(() => {
  const h = Math.ceil($(".bar").getBoundingClientRect().height);
  if (h && h !== barH) {
    barH = h;
    document.documentElement.style.setProperty("--bar-h", `${h}px`);
  }
}).observe($(".bar"));

let resizeT;
new ResizeObserver(() => {
  clearTimeout(resizeT);
  resizeT = setTimeout(() => { sizePages(); render(); }, 120);
}).observe(scroller);
narrowMq.addEventListener("change", () => render());

const qZoom = +new URLSearchParams(location.search).get("zoom");
if (qZoom) zoom = Math.min(4, Math.max(0.5, qZoom));
renderZoom();

const qTheme = new URLSearchParams(location.search).get("theme");
if (qTheme) document.documentElement.dataset.theme = qTheme;

// ?snapshot: fetch the state once instead of streaming (for screenshots).
// A slow image holds the load event open so headless screenshots wait for
// the PDF to render.
if (new URLSearchParams(location.search).has("snapshot")) {
  const hold = new Image();
  hold.src = "/delay?ms=" + (new URLSearchParams(location.search).get("snapshot") || "6000");
  document.body.append(hold);
  fetch("/state").then((r) => r.json()).then(apply);
  if (new URLSearchParams(location.search).has("math")) {
    fetch("/math").then((r) => r.json()).then((m) => m.out && openMath(m));
  }
  if (new URLSearchParams(location.search).has("draw")) {
    fetch("/draw").then((r) => r.json()).then((d) => d.status && drawEvent({ ...d, open: true }));
  }
  if (new URLSearchParams(location.search).has("report")) {
    fetch("/progress").then((r) => r.json()).then((d) => d.md && openReport(d.md));
  }
} else {
  connect();
}
