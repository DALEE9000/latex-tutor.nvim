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

-- Every unit in the buffer, in order: { s, e, label } (1-based, inclusive).
function M.units(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local starts = unit_starts(lines)
  local out = {}
  for k, st in ipairs(starts) do
    local e = (starts[k + 1] or (#lines + 1)) - 1
    out[#out + 1] = { s = st, e = e, label = label_for(lines, st, e) }
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
