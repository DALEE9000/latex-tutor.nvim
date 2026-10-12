-- Private progress log. Every review and every resolved comment appends one
-- JSON line to stdpath("data")/latex-tutor/progress.jsonl, which sits outside
-- every git repo, so it can't be committed by accident. `:Tutor progress`
-- turns the log into a Markdown report.

local api = vim.api
local config = require("latex-tutor.config")
local M = {}

M.dir = vim.fn.stdpath("data") .. "/latex-tutor"
M.log_path = M.dir .. "/progress.jsonl"
M.report_path = M.dir .. "/progress.md"

-- Same scale as the self-study record: correct 1, minor 0.8, incomplete 0.5,
-- major issues 0.
M.score = { correct = 1, minor_issues = 0.8, incomplete = 0.5, major_issues = 0 }
local verdict_order = { "correct", "minor_issues", "incomplete", "major_issues" }
local verdict_short = { correct = "correct", minor_issues = "minor", incomplete = "incomplete", major_issues = "major" }

-- Manual = the directory holding header<slug>.tex; chapter = the file name.
function M.where(file)
  local root = require("latex-tutor.prompt").project_root(file)
  return vim.fn.fnamemodify(root, ":t"), vim.fn.fnamemodify(file, ":t:r")
end

local function append(rec)
  vim.fn.mkdir(M.dir, "p")
  local f = io.open(M.log_path, "a")
  if not f then return end
  f:write(vim.json.encode(rec), "\n")
  f:close()
end

function M.record_review(file, unit, out)
  local manual, chapter = M.where(file)
  local counts = {}
  for _, c in ipairs(out.comments or {}) do
    if type(c) == "table" and c.severity then counts[c.severity] = (counts[c.severity] or 0) + 1 end
  end
  append({
    event = "review", at = os.time(), manual = manual, chapter = chapter,
    unit = unit.label, kind = unit.kind, verdict = out.verdict, counts = counts,
  })
end

function M.record_resolve(file, c, by)
  local manual, chapter = M.where(file)
  append({
    event = "resolve", at = os.time(), manual = manual, chapter = chapter,
    unit = c.unit, severity = c.severity, title = c.title, by = by,
  })
end

function M.read()
  local recs = {}
  local f = io.open(M.log_path, "r")
  if not f then return recs end
  for line in f:lines() do
    local ok, r = pcall(vim.json.decode, line)
    if ok and type(r) == "table" then recs[#recs + 1] = r end
  end
  f:close()
  return recs
end

local function is_exercise(r)
  return r.kind == "exercise" or (type(r.unit) == "string" and r.unit:match("^Q ") ~= nil)
end

-- Section labels are raw LaTeX (\textsf{I.9 - ...}); show them as plain text.
local function show(u)
  if type(u) ~= "string" or not u:find("\\", 1, true) then return u or "" end
  return require("latex-tutor.scope").plain(u)
end

local function pct(x) return x and string.format("%d%%", math.floor(x * 100 + 0.5)) or "–" end

-- Latest verdict per exercise -> { n, score, by_verdict }
local function grade(latest)
  local n, sum, by = 0, 0, {}
  for _, r in pairs(latest) do
    if M.score[r.verdict] then
      n, sum = n + 1, sum + M.score[r.verdict]
      by[r.verdict] = (by[r.verdict] or 0) + 1
    end
  end
  return n, n > 0 and sum / n or nil, by
end

local function verdict_mix(by)
  local parts = {}
  for _, v in ipairs(verdict_order) do
    if by[v] then parts[#parts + 1] = by[v] .. " " .. verdict_short[v] end
  end
  return #parts > 0 and table.concat(parts, ", ") or "–"
end

local function sev_cell(counts, sev) return tostring(counts[sev] or 0) end

function M.report()
  local recs = M.read()
  local L = {}
  local function add(s) L[#L + 1] = s or "" end
  add("# Tutor progress")
  add("")
  add(string.format("_Generated %s from `%s`. This file stays on this machine; it is not in any git repo._",
    os.date("%Y-%m-%d %H:%M"), vim.fn.fnamemodify(M.log_path, ":~")))
  add("")
  if #recs == 0 then
    add("No reviews yet. Press Space c c inside an exercise to start.")
    return L
  end

  local reviews, resolves = {}, {}
  for _, r in ipairs(recs) do
    if r.event == "review" then reviews[#reviews + 1] = r elseif r.event == "resolve" then resolves[#resolves + 1] = r end
  end

  -- Per-exercise first and latest review.
  local first, latest = {}, {}
  local manuals = {}
  local sev_total = {}
  for _, r in ipairs(reviews) do
    for s, k in pairs(r.counts or {}) do sev_total[s] = (sev_total[s] or 0) + k end
    local m = manuals[r.manual] or { chapters = {}, reviews = 0, counts = {}, latest = {} }
    manuals[r.manual] = m
    m.reviews = m.reviews + 1
    for s, k in pairs(r.counts or {}) do m.counts[s] = (m.counts[s] or 0) + k end
    local ch = m.chapters[r.chapter] or { reviews = 0, counts = {}, latest = {} }
    m.chapters[r.chapter] = ch
    ch.reviews = ch.reviews + 1
    for s, k in pairs(r.counts or {}) do ch.counts[s] = (ch.counts[s] or 0) + k end
    if is_exercise(r) then
      local key = r.manual .. "/" .. r.chapter .. "/" .. r.unit
      first[key] = first[key] or r
      latest[key] = r
      m.latest[key] = r
      ch.latest[key] = r
    end
  end

  local n, score, by = grade(latest)
  local by_you, by_tutor = 0, 0
  for _, r in ipairs(resolves) do
    if r.by == "tutor" then by_tutor = by_tutor + 1 else by_you = by_you + 1 end
  end

  add("## Overall")
  add("")
  add(string.format("- **%d** review%s of **%d** exercise%s. Score on each exercise's latest review: **%s** (%s).",
    #reviews, #reviews == 1 and "" or "s", n, n == 1 and "" or "s", pct(score), verdict_mix(by)))
  local sev_parts = {}
  for _, s in ipairs(config.severity_order) do
    if sev_total[s] then sev_parts[#sev_parts + 1] = sev_total[s] .. " " .. config.sev(s).label:lower() end
  end
  add("- Comments received: " .. (#sev_parts > 0 and table.concat(sev_parts, ", ") or "none") .. ".")
  add(string.format("- Comments resolved: %d (%d by you, %d closed by the tutor after a reply).",
    by_you + by_tutor, by_you, by_tutor))
  add("- Score scale (same as the self-study record): correct 1, minor 0.8, incomplete 0.5, major issues 0.")
  add("")

  local names = vim.tbl_keys(manuals)
  table.sort(names)
  add("## By manual")
  add("")
  add("| Manual | Exercises | Score | Verdicts | Errors | Rigor | Improve | LaTeX |")
  add("|---|---|---|---|---|---|---|---|")
  for _, name in ipairs(names) do
    local m = manuals[name]
    local mn, ms, mb = grade(m.latest)
    add(string.format("| %s | %d | %s | %s | %s | %s | %s | %s |", name, mn, pct(ms), verdict_mix(mb),
      sev_cell(m.counts, "error"), sev_cell(m.counts, "rigor"), sev_cell(m.counts, "improve"), sev_cell(m.counts, "latex")))
  end
  add("")

  add("## By chapter")
  for _, name in ipairs(names) do
    add("")
    add("### " .. name)
    add("")
    add("| Chapter | Exercises | Score | Verdicts | Errors | Rigor |")
    add("|---|---|---|---|---|---|")
    local chs = vim.tbl_keys(manuals[name].chapters)
    table.sort(chs)
    for _, chn in ipairs(chs) do
      local ch = manuals[name].chapters[chn]
      local cn, cs, cb = grade(ch.latest)
      add(string.format("| %s | %d | %s | %s | %s | %s |", chn, cn, pct(cs), verdict_mix(cb),
        sev_cell(ch.counts, "error"), sev_cell(ch.counts, "rigor")))
    end
  end
  add("")

  -- Weekly trend (ISO-ish weeks, newest last, at most 12).
  local weeks, order = {}, {}
  for _, r in ipairs(reviews) do
    local wk = os.date("%G-W%V", r.at)
    if not weeks[wk] then weeks[wk] = { n = 0, sum = 0, scored = 0, err = 0, rig = 0 }; order[#order + 1] = wk end
    local w = weeks[wk]
    w.n = w.n + 1
    if is_exercise(r) and M.score[r.verdict] then w.scored, w.sum = w.scored + 1, w.sum + M.score[r.verdict] end
    w.err = w.err + ((r.counts or {}).error or 0)
    w.rig = w.rig + ((r.counts or {}).rigor or 0)
  end
  add("## Week by week")
  add("")
  add("Every review that week counts, including re-reviews after a fix.")
  add("")
  add("| Week | Reviews | Avg score | Errors per review | Rigor per review |")
  add("|---|---|---|---|---|")
  for i = math.max(1, #order - 11), #order do
    local w = weeks[order[i]]
    add(string.format("| %s | %d | %s | %.1f | %.1f |", order[i], w.n,
      pct(w.scored > 0 and w.sum / w.scored or nil), w.err / w.n, w.rig / w.n))
  end
  add("")

  -- Re-reviewed exercises whose verdict changed.
  local changed = {}
  for key, r in pairs(latest) do
    local f = first[key]
    if f ~= r and M.score[f.verdict] and M.score[r.verdict] and f.verdict ~= r.verdict then
      changed[#changed + 1] = string.format("- %s · %s %s: %s → %s", r.manual, r.chapter, show(r.unit),
        verdict_short[f.verdict], verdict_short[r.verdict])
    end
  end
  table.sort(changed)
  if #changed > 0 then
    add("## Changed on re-review")
    add("")
    for _, l in ipairs(changed) do add(l) end
    add("")
  end

  -- What keeps coming up: the latest error and rigor comments you resolved.
  local recent = {}
  for i = #resolves, 1, -1 do
    local r = resolves[i]
    if r.severity == "error" or r.severity == "rigor" then
      recent[#recent + 1] = string.format("- %s · %s %s · **%s**: %s", os.date("%b %d", r.at), r.manual,
        show(r.unit), config.sev(r.severity).label, r.title or "")
      if #recent >= 15 then break end
    end
  end
  if #recent > 0 then
    add("## Recent errors and rigor issues you fixed")
    add("")
    for _, l in ipairs(recent) do add(l) end
    add("")
  end
  return L
end

-- Write the report to progress.md and show it in a split.
function M.open()
  local lines = M.report()
  vim.fn.mkdir(M.dir, "p")
  vim.fn.writefile(lines, M.report_path)
  vim.cmd("topleft split " .. vim.fn.fnameescape(M.report_path))
  vim.cmd("edit!") -- reload if it was already open
  vim.bo.modifiable = true
  local b = api.nvim_get_current_buf()
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, silent = true })
end

return M
