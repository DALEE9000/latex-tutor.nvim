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

function scaleFor(list) {
  const s = availableWidth() / Math.max(...list.map((p) => p.wPt));
  return Math.max(0.5, Math.min(s, 2.2));
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

  const addSummary = (label, sum, anchorFrom) => {
    if (!sum) return;
    const el = document.createElement("div");
    el.className = "summary-card";
    el.innerHTML = `<div class="label">${esc(label)} · ${esc(VERDICT[sum.verdict] || sum.verdict || "")}</div>
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
      lab.className = "group-label";
      lab.textContent = g.label;
      margin.append(lab);
      const first = (S.comments || []).find((c) => c.group === g.label);
      items.push({ el: lab, anchor: first ? anchorY(first) : null });
      addSummary(g.label, g.summary, first ? anchorY(first) : null);
      for (const c of S.comments || []) if (c.group === g.label) addCard(c);
    }
  } else {
    const fb = S.focus && S.focus.box;
    const fy = fb && pages[fb.page - 1] ? pages[fb.page - 1].el.offsetTop + fb.y * scale - margin.offsetTop : null;
    addSummary(S.focus ? S.focus.label : "", S.summary, fy);
    for (const c of visibleComments()) addCard(c);
    if (!S.summary && !(S.comments || []).length && S.focus) {
      const el = document.createElement("div");
      el.className = "summary-card";
      el.innerHTML = `<div class="label">${esc(S.focus.label)}</div>
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
  const key = `${S.focus && S.focus.label}|${S.active}|${docVersion}`;
  if (!force && key === lastScrollKey) return;
  lastScrollKey = key;
  const top = y + margin.offsetTop;
  const view = scroller.scrollTop, h = scroller.clientHeight;
  if (force || top < view + 40 || top > view + h * 0.7) {
    scroller.scrollTo({ top: Math.max(0, top - h * 0.28) });
  }
}

function renderBar() {
  $("#file").textContent = S.name || "—";
  $("#file").title = S.file || "";
  const picker = $("#picker");
  const qs = S.questions || [];
  picker.innerHTML = qs.map((q) => {
    const mark = q.total ? ` · ${q.fixed}/${q.total}` : (q.verdict ? " · ✓" : "");
    return `<option value="${q.line}" ${S.focus && q.label === S.focus.label ? "selected" : ""}>${esc(q.label)}${mark}</option>`;
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
$("#picker").addEventListener("change", (e) => post("jump_line", { line: +e.target.value }));
$("#sheet-toggle").addEventListener("click", () => { margin.classList.toggle("closed"); renderMargin(); });

document.addEventListener("keydown", (e) => {
  if (e.target.closest("textarea, input, select")) return;
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

let resizeT;
new ResizeObserver(() => {
  clearTimeout(resizeT);
  resizeT = setTimeout(() => { sizePages(); render(); }, 120);
}).observe(scroller);
narrowMq.addEventListener("change", () => render());

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
} else {
  connect();
}
