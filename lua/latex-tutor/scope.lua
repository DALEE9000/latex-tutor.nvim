-- Work out which lines to send: the exercise under the cursor, a selection,
-- or the whole file.

local api = vim.api
local config = require("latex-tutor.config")
local M = {}

local function matches_any(line, patterns)
  for _, p in ipairs(patterns) do
    if line:find(p) then return true end
  end
  return false
end

-- 1-based start lines of every unit. A section heading also starts a unit so
-- an exercise never swallows the next section.
local function unit_starts(lines)
  local cfg = config.get()
  local starts, prev_marker = {}, false
  for i, l in ipairs(lines) do
    local unit = matches_any(l, cfg.unit_patterns)
    local sect = matches_any(l, cfg.section_patterns)
    if (unit and not prev_marker) or sect then
      starts[#starts + 1] = i
    end
    prev_marker = unit
  end
  return starts
end

-- Short label for the unit, e.g. "Q 5.8.1" from \qs{5.8.1}{...}.
local function label_for(lines, s, e)
  for i = s, math.min(e, s + 3) do
    local q = lines[i]:match("\\qs%s*{([^}]*)}")
    if q then return "Q " .. q end
  end
  for i = s, math.min(e, s + 3) do
    local n = lines[i]:match("^%s*%%+%s*QUESTION%s*(%S+)")
    if n then return "Question " .. n end
    local sec = lines[i]:match("\\%a*section%*?%s*{([^}]*)}")
    if sec then return sec end
  end
  return string.format("lines %d–%d", s, e)
end

-- The {...} argument starting at byte i of str (balanced braces), or the
-- rest of the line if it never closes. Returns the inside and the index after.
local function brace_arg(str, i)
  if str:sub(i, i) ~= "{" then return nil, i end
  local depth = 0
  for j = i, #str do
    local ch = str:sub(j, j)
    if ch == "{" and str:sub(j - 1, j - 1) ~= "\\" then depth = depth + 1
    elseif ch == "}" and str:sub(j - 1, j - 1) ~= "\\" then
      depth = depth - 1
      if depth == 0 then return str:sub(i + 1, j - 1), j + 1 end
    end
  end
  return str:sub(i + 1), #str + 1
end

-- LaTeX heading text -> plain text for the Tutor window:
-- "\textsf{I.4 - Elimination and \texorpdfstring{\(\bm{A = LU}\)}{A = LU}}"
-- -> "I.4 – Elimination and A = LU".
function M.plain(tex)
  local s = tex
  -- \texorpdfstring{tex}{plain} -> plain
  while true do
    local a, b = s:find("\\texorpdfstring%s*")
    if not a then break end
    local _, after1 = brace_arg(s, b + 1)
    local plain, after2 = brace_arg(s, after1)
    s = s:sub(1, a - 1) .. (plain or "") .. s:sub(after2)
  end
  s = s:gsub("\\[%(%)%[%]]", "")          -- \( \) \[ \]
       :gsub("%$", "")
       :gsub("\\\\", " ")                  -- line breaks
       :gsub("\\([%%&#_{}])", "%1")         -- \% \& \_ ...
       :gsub("\\%a+%*?", function(cmd)      -- drop command names, keep arguments
         local spaced = { ["\\quad"] = 1, ["\\qquad"] = 1, ["\\enspace"] = 1, ["\\ "] = 1 }
         return spaced[cmd] and " " or ""
       end)
       :gsub("\\[,;:! ]", " ")
       :gsub("[{}]", "")
       :gsub("~", " ")
       :gsub("%-%-%-", "—"):gsub("%-%-", "–")
       :gsub("%s+%-%s+", " – ")
       :gsub("%s+", " ")
  return vim.trim(s)
end

-- The display title of a unit that starts with a heading:
-- returns the plain heading text, or nil if the unit isn't a section.
local function heading_for(lines, s, e)
  for i = s, math.min(e, s + 3) do
    if lines[i]:match("\\qs%s*{") or lines[i]:match("^%s*%%+%s*QUESTION") then return nil end
    local a, b = lines[i]:find("\\%a*section%*?%s*")
    if not a then a, b = lines[i]:find("\\chapter%*?%s*") end
    if a then
      local j = b + 1
      if lines[i]:sub(j, j) == "[" then j = (lines[i]:find("]", j, true) or j) + 1 end
      local arg = brace_arg(lines[i], j)
      if arg then
        local t = M.plain(arg)
        if t ~= "" then return t end
      end
    end
  end
end

-- Display title for a label: the unit at line s (if it is a section) gets its
-- clean heading; anything else keeps the label. Returns title, is_section.
function M.title(buf, s, label)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if s and lines[s] then
    local t = heading_for(lines, s, #lines)
    if t then return t, true end
  end
  return label, false
end

-- Every unit in the buffer, in order: { s, e, label } (1-based, inclusive).
function M.units(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local starts = unit_starts(lines)
  local out = {}
  for k, st in ipairs(starts) do
    local e = (starts[k + 1] or (#lines + 1)) - 1
    local title = heading_for(lines, st, e)
    out[#out + 1] = { s = st, e = e, label = label_for(lines, st, e), title = title or nil, section = title and true or nil }
  end
  return out
end

-- Returns { s = first, e = last (1-based, inclusive), label = ... }
function M.unit_at(buf, row1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local starts = unit_starts(lines)
  local s, e = 1, #lines
  for k, st in ipairs(starts) do
    if st <= row1 then
      s = st
      e = (starts[k + 1] or (#lines + 1)) - 1
    end
  end
  if s == 1 and (starts[1] or math.huge) > row1 then
    -- Cursor is above the first unit (preamble): take up to the first unit.
    e = (starts[1] or (#lines + 1)) - 1
  end
  -- Trim trailing blank lines / \newpage so line numbers stay meaningful.
  while e > s and (lines[e]:match("^%s*$") or lines[e]:match("^%s*\\newpage%s*$")
    or lines[e]:match("^%s*\\end{document}")) do
    e = e - 1
  end
  return { s = s, e = e, label = label_for(lines, s, e), kind = "exercise" }
end

function M.range(buf, s, e)
  local lines = api.nvim_buf_get_lines(buf, s - 1, e, false)
  return { s = s, e = e, label = label_for(lines, 1, #lines):gsub("^lines .*", string.format("lines %d–%d", s, e)), kind = "range" }
end

function M.file(buf)
  local n = api.nvim_buf_line_count(buf)
  return { s = 1, e = n, label = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t"), kind = "file" }
end

return M
