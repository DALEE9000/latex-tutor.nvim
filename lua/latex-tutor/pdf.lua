-- Mirrors comments into the live TeXpresso preview as numbered, coloured
-- badges (plus the title in the margin where LaTeX allows a \marginpar).
--
-- Nothing touches the file on disk or the nvim buffer. TeXpresso renders the
-- text nvim sends it, so we send it an annotated copy of just the lines that
-- carry comments ("change-lines", one line at a time, line count unchanged).
-- Clearing a comment sends the original line back. texpresso.lua is not
-- modified; we only call its public send() and wrap its reload() so a full
-- re-open from nvim gets re-annotated.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local M = { enabled = nil }

local ns = api.nvim_create_namespace("latex_tutor_pdf")
local sent = {} -- buf -> { [mark_id] = text TeXpresso currently holds for that row }

local function tx()
  local ok, t = pcall(require, "texpresso")
  if ok and type(t) == "table" and t.send and t.is_running then return t end
end

function M.is_enabled()
  if M.enabled == nil then M.enabled = config.get().texpresso.annotate end
  return M.enabled
end

-- One self-contained TeX snippet: defines the macros on first use (\gdef, so
-- grouping doesn't matter and no preamble is needed), then the badge. The
-- \marginpar only fires in outer paragraph mode of the main text column:
-- not inner (hbox), \hsize = \textwidth (catches \parbox), and \@mpfn =
-- footnote (catches minipage / tcolorbox, which reset \textwidth itself),
-- and \@captype undefined (not inside a figure/table float).
local DEF_NOTES = [[\ifdefined\tutormarkN\else\gdef\tutorfn{footnote}]]
  .. [[\gdef\tutorbadge#1#2{\textsuperscript{\colorbox[rgb]{#1}{\color[rgb]{1,1,1}\tiny\sffamily\bfseries\,#2\,}}}]]
  .. [[\gdef\tutormarkN#1#2#3{\ifmmode\mbox{\tutorbadge{#1}{#2}}\else\leavevmode\tutorbadge{#1}{#2}]]
  .. [[\ifinner\else\ifdim\hsize=\textwidth\expandafter\ifx\csname @mpfn\endcsname\tutorfn]]
  .. [[\ifcsname @captype\endcsname\else]]
  .. [[\marginpar{\raggedright\tiny\sffamily\color[rgb]{#1}\textbf{#2}\ #3}\fi\fi\fi\fi\fi}\fi]]
local DEF_PLAIN = [[\ifdefined\tutormarkB\else]]
  .. [[\gdef\tutorbadge#1#2{\textsuperscript{\colorbox[rgb]{#1}{\color[rgb]{1,1,1}\tiny\sffamily\bfseries\,#2\,}}}]]
  .. [[\gdef\tutormarkB#1#2#3{\ifmmode\mbox{\tutorbadge{#1}{#2}}\else\leavevmode\tutorbadge{#1}{#2}\fi}\fi]]

local function tex_safe(s)
  s = (s or ""):gsub("[^%w%s%.,;:!%?'%(%)%-/=+]", " "):gsub("%s+", " ")
  s = vim.trim(s)
  if #s > 60 then s = s:sub(1, 57) .. "..." end
  return s
end

-- Literal / picture environments where injected text would break or print.
local UNSAFE_ENV = {
  verbatim = true, ["verbatim*"] = true, Verbatim = true, lstlisting = true, minted = true,
  python = true, comment = true, tikzpicture = true, pgfpicture = true, axis = true,
  tikzcd = true, forest = true, filecontents = true, ["filecontents*"] = true,
}

-- Lines that only open/close structure: a badge there would start a stray
-- paragraph or (in a list, before the first \item) be an error.
local STRUCTURAL = {
  "^\\newpage", "^\\clearpage", "^\\pagebreak", "^\\vspace", "^\\vskip", "^\\hline",
  "^\\toprule", "^\\midrule", "^\\bottomrule", "^\\centering", "^\\maketitle",
  "^\\tableofcontents", "^\\par$", "^\\noindent$", "^\\bigskip$", "^\\medskip$", "^\\smallskip$",
  "^\\label%s*%b{}$", "^\\item$",
}

-- True if the line is nothing but \begin{..}[..]{..} / \end{..} / \[ / \] /
-- braces, e.g. "\begin{enumerate}[label=(\alph*)]" or "\end{enumerate}}".
local function structural(t)
  local prev
  repeat
    prev = t
    t = t:gsub("^%s+", ""):gsub("^\\begin%s*%b{}", ""):gsub("^\\end%s*%b{}", "")
      :gsub("^%b[]", ""):gsub("^%b{}", ""):gsub("^\\[%[%]]", ""):gsub("^%$%$", ""):gsub("^[{}]", "")
  until t == prev
  if t == "" then return true end
  -- Ends by opening an environment (a list there needs \item first).
  local tail = t:gsub("%s+$", "")
  repeat
    prev = tail
    tail = tail:gsub("%b[]$", ""):gsub("%s+$", "")
  until tail == prev
  if tail:find("\\begin%s*%b{}$") then return true end
  for _, p in ipairs(STRUCTURAL) do if t:find(p) then return true end end
  return false
end

-- Moving arguments (copied to .toc/.aux) and verbatim-ish commands.
local FRAGILE = { "\\%a*section%*?%s*[%[{]", "\\chapter", "\\caption", "\\paragraph", "\\title",
  "\\author", "\\date", "\\verb", "\\lstinline", "\\pythoninline", "\\url", "\\href", "\\input", "\\include" }

-- Brace groups that carry typeset text, so a badge inside them is fine.
-- Any other open group spanning a line end (\tikzset{, \newcommand{,
-- \frac{ ...) makes the line unsafe.
local TEXT_GROUP = {
  [""] = true, qs = true, textbf = true, textit = true, emph = true, textsf = true, texttt = true,
  textsc = true, textrm = true, underline = true, uline = true, text = true, mbox = true, fbox = true,
  parbox = true, footnote = true, centerline = true, makebox = true, framebox = true,
}

-- Name of the command a "{" at byte `i` belongs to ("" for a bare group):
-- skip back over arguments already given, e.g. \qs{5.8.1}{ -> "qs".
local function opener(code, i)
  local pre = code:sub(1, i - 1)
  local prev
  repeat
    prev = pre
    pre = pre:gsub("%s+$", ""):gsub("%b{}$", ""):gsub("%b[]$", "")
  until pre == prev
  return pre:match("\\(%a+)%*?$") or (pre:match("[%w}%]]$") and "?" or "")
end

-- Code part of a line (before an unescaped %), and the rest.
local function split_comment(l)
  local i = 1
  while true do
    local p = l:find("%", i, true)
    if not p then return l, "" end
    local bs = 0
    local j = p - 1
    while j >= 1 and l:sub(j, j) == "\\" do bs = bs + 1; j = j - 1 end
    if bs % 2 == 0 then return l:sub(1, p - 1), l:sub(p) end
    i = p + 1
  end
end

-- safe[i] (1-based) = true if a badge may be appended to line i.
local function scan(lines)
  local safe = {}
  local n = #lines
  local first, last = 1, n
  local has_class = false
  for i, l in ipairs(lines) do
    local code = split_comment(l)
    if code:find("\\documentclass") then has_class = true end
    if code:find("\\begin%s*{document}") then first = i + 1 end
    if code:find("\\end%s*{document}") then last = i - 1 end
  end
  if has_class and first == 1 then return safe end -- preamble-only buffer
  local depth = 0
  local groups = {} -- stack of opener names
  local await_item = false -- a list was opened and has no \item yet
  for i = 1, n do
    local code = split_comment(lines[i])
    local was = depth
    local was_text = true
    for _, g in ipairs(groups) do if not TEXT_GROUP[g] then was_text = false; break end end
    local j = 1
    while true do
      local p = code:find("[{}]", j)
      if not p then break end
      local bs, k = 0, p - 1
      while k >= 1 and code:sub(k, k) == "\\" do bs = bs + 1; k = k - 1 end
      if bs % 2 == 0 then
        if code:sub(p, p) == "{" then
          groups[#groups + 1] = opener(code, p)
        elseif #groups > 0 then
          groups[#groups] = nil
        end
      end
      j = p + 1
    end
    -- Track "list opened, no \item yet": text there is a LaTeX error.
    local last_list, last_item = 0, 0
    for pos in code:gmatch("()\\begin%s*{%a*enumerate%*?}") do last_list = pos end
    for pos in code:gmatch("()\\begin%s*{%a*itemize%*?}") do last_list = math.max(last_list, pos) end
    for pos in code:gmatch("()\\begin%s*{description}") do last_list = math.max(last_list, pos) end
    for pos in code:gmatch("()\\item%f[^%a]") do last_item = pos end
    if last_list > last_item then await_item = true elseif last_item > 0 then await_item = false end
    local in_text = was_text and not await_item
    for _, g in ipairs(groups) do if not TEXT_GROUP[g] then in_text = false; break end end
    for cmd, env in code:gmatch("\\(%a+)%s*{([^}]*)}") do
      if UNSAFE_ENV[env] then
        if cmd == "begin" then depth = depth + 1 elseif cmd == "end" then depth = math.max(0, depth - 1) end
      end
    end
    local t = vim.trim(code)
    local ok = i >= first and i <= last and was == 0 and depth == 0 and in_text and t ~= ""
    if ok and structural(t) then ok = false end
    if ok then
      for _, p in ipairs(FRAGILE) do if t:find(p) then ok = false; break end end
    end
    safe[i] = ok
  end
  return safe
end

-- Nearest safe line to `i`: upward first (stays inside the same exercise),
-- then downward.
local function target_line(safe, i, n)
  for d = 0, 40 do
    if safe[i - d] then return i - d end
  end
  for d = 1, 40 do
    if i + d <= n and safe[i + d] then return i + d end
  end
end

local function annotate(line, marks)
  local code, rest = split_comment(line)
  local body = code:gsub("%s+$", "")
  local trail = code:sub(#body + 1)
  local tail = ""
  -- Keep a trailing \\ (row/line break) after the badge.
  local a = body:find("\\\\%*?%s*%b[]$") or body:find("\\\\%*?$")
  if a then
    local bs = 0
    local j = a - 1
    while j >= 1 and body:sub(j, j) == "\\" do bs = bs + 1; j = j - 1 end
    if bs % 2 == 0 then body, tail = body:sub(1, a - 1), body:sub(a) end
  end
  return body .. table.concat(marks) .. tail .. trail .. rest
end

-- Recompute and push the annotated lines for `buf`.
function M.sync(buf)
  local t = tx()
  if not t or not api.nvim_buf_is_valid(buf) then return end
  local path = api.nvim_buf_get_name(buf)
  if path == "" then return end
  sent[buf] = sent[buf] or {}
  local held = sent[buf]
  if not t.is_running() then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    sent[buf] = {}
    return
  end

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local desired = {} -- row0 -> text
  if M.is_enabled() and not store.hidden then
    local notes = config.get().texpresso.margin_notes
    local def, macro = notes and DEF_NOTES or DEF_PLAIN, notes and "\\tutormarkN" or "\\tutormarkB"
    local safe = scan(lines)
    local per = {}
    store.sync(buf)
    for _, c in ipairs(store.list(buf, { open = true, focus = true })) do
      local L = target_line(safe, c.row + 1, #lines)
      if L then
        per[L] = per[L] or {}
        local m = string.format("%s{%s}{%d}{%s}", macro, config.sev(c.severity).rgb, c.n,
          notes and tex_safe(c.title) or "")
        table.insert(per[L], (#per[L] == 0 and def or "") .. m)
      end
    end
    for L, marks in pairs(per) do desired[L - 1] = annotate(lines[L], marks) end
  end

  -- Rows TeXpresso currently holds annotated (tracked by extmark).
  local current = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    local id, row = m[1], m[2]
    if held[id] == nil or current[row] then
      api.nvim_buf_del_extmark(buf, ns, id)
      held[id] = nil
    else
      current[row] = id
    end
  end
  local function push(row, text)
    t.send("change-lines", path, row, 1, text .. "\n")
  end
  for row, id in pairs(current) do
    local want = desired[row]
    if want ~= held[id] then
      push(row, want or lines[row + 1] or "")
      if want then
        held[id] = want
      else
        held[id] = nil
        api.nvim_buf_del_extmark(buf, ns, id)
      end
    end
  end
  for row, want in pairs(desired) do
    if not current[row] then
      push(row, want)
      local id = api.nvim_buf_set_extmark(buf, ns, row, 0, { right_gravity = false })
      held[id] = want
    end
  end
end

local timers = {}
function M.sync_soon(buf, ms)
  if timers[buf] then timers[buf]:stop() end
  timers[buf] = vim.defer_fn(function()
    timers[buf] = nil
    M.sync(buf)
  end, ms or 300)
end

-- Rows the user just edited were re-sent to TeXpresso verbatim by
-- texpresso.lua's own on_lines hook. Mark what TeXpresso holds for them as
-- unknown (false) so the next sync re-sends either the annotation or the
-- plain line.
function M.on_lines(buf, first, new_last)
  local held = sent[buf]
  if not held or next(held) == nil then return end
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { math.max(first, new_last - 1), -1 }, {})) do
    if held[m[1]] ~= nil then held[m[1]] = false end
  end
  M.sync_soon(buf)
end

-- After a full reload/relaunch TeXpresso holds the plain file again.
local function forget(buf)
  sent[buf] = {}
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

local wrapped = false
function M.hook()
  local t = tx()
  if not t or wrapped then return end
  wrapped = true
  local reload, launch = t.reload, t.launch
  t.reload = function(buf, ...)
    local r = reload(buf, ...)
    local b = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    forget(b)
    M.sync_soon(b, 150)
    return r
  end
  if launch then
    t.launch = function(...)
      local r = launch(...)
      for b in pairs(sent) do forget(b) end
      return r
    end
  end
end

-- Synctex jump so the PDF shows the commented line.
function M.reveal(buf, row0)
  local t = tx()
  if t and t.is_running() and config.get().texpresso.sync_on_jump and not store.hidden then
    t.send("synctex-forward", api.nvim_buf_get_name(buf), row0 + 1)
  end
end

function M.toggle(buf)
  M.enabled = not M.is_enabled()
  M.sync(buf)
  return M.enabled
end

M._scan, M._annotate = scan, annotate -- for tests
return M
