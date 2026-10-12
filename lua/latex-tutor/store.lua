-- Comment state per buffer. Live positions are held by extmarks (so comments
-- ride along with your edits); this module reads them back, re-anchors
-- comments by their quoted text, and persists everything to stdpath("state")
-- so nothing is written next to your .tex files.

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("latex_tutor")
M.bufs = {}
-- `:Tutor hide`: every display is off, but extmarks keep tracking edits.
M.hidden = false

local function resolve_buf(buf)
  if not buf or buf == 0 then return api.nvim_get_current_buf() end
  return buf
end

function M.get(buf)
  buf = resolve_buf(buf)
  local st = M.bufs[buf]
  if not st then
    st = { comments = {}, summaries = {}, next_n = 1, show_resolved = false, loaded = false }
    M.bufs[buf] = st
  end
  return st
end

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- Escape a literal string for a Lua pattern, letting runs of whitespace match
-- any whitespace (Claude sometimes normalises tabs/double spaces in quotes).
local function loose_pattern(s)
  s = vim.trim(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  return (s:gsub("%s+", "%%s+"))
end

-- Locate `quote` near 1-based line `line1` in `lines`. Searches outward up to
-- `radius` lines. Returns 0-based row, col, end_row, end_col and whether the
-- quote was found (false = fell back to highlighting whole lines).
function M.anchor(lines, line1, quote, end_line1, radius)
  local n = #lines
  if n == 0 then return 0, 0, 0, 0, false end
  local L = clamp(line1 or 1, 1, n)
  radius = radius or 6
  if quote and vim.trim(quote) ~= "" then
    local loose = loose_pattern(quote)
    for pass = 1, 2 do
      for d = 0, radius do
        for _, i in ipairs(d == 0 and { L } or { L - d, L + d }) do
          local t = lines[i]
          if t then
            local a, b
            if pass == 1 then
              a, b = t:find(quote, 1, true)
            else
              a, b = t:find(loose)
            end
            if a then return i - 1, a - 1, i - 1, b, true end
          end
        end
      end
    end
  end
  local E = clamp(end_line1 or L, L, n)
  local first = (lines[L]:find("%S") or 1) - 1
  return L - 1, first, E - 1, #lines[E], false
end

-- Pull current extmark positions back into the comment tables.
function M.sync(buf)
  buf = resolve_buf(buf)
  local st = M.get(buf)
  if not api.nvim_buf_is_valid(buf) then return st end
  for _, c in pairs(st.comments) do
    if c.mark then
      local m = api.nvim_buf_get_extmark_by_id(buf, M.ns, c.mark, { details = true })
      if m and m[1] then
        c.row, c.col = m[1], m[2]
        c.end_row = m[3].end_row or c.row
        c.end_col = m[3].end_col or c.col
      end
    end
  end
  return st
end

local function by_position(a, b)
  if a.row ~= b.row then return a.row < b.row end
  if a.col ~= b.col then return a.col < b.col end
  return a.n < b.n
end

-- Sorted list. opts.open = only unresolved; opts.visible = respects show_resolved.
function M.list(buf, opts)
  opts = opts or {}
  local st = M.get(buf)
  local out = {}
  for _, c in pairs(st.comments) do
    local keep = true
    if opts.open and c.resolved then keep = false end
    if opts.visible and c.resolved and not st.show_resolved then keep = false end
    if keep then out[#out + 1] = c end
  end
  table.sort(out, by_position)
  return out
end

-- Comment covering the cursor (0-based row). Prefers one containing `col`.
function M.at(buf, row, col)
  local best
  for _, c in ipairs(M.list(buf, { visible = true })) do
    if row >= c.row and row <= c.end_row then
      local inside = (row > c.row or col >= c.col) and (row < c.end_row or col < math.max(c.end_col, c.col + 1))
      if inside then return c end
      best = best or c
    end
  end
  return best
end

function M.add(buf, c)
  local st = M.get(buf)
  c.id = c.id or string.format("%d-%d", os.time(), st.next_n)
  c.n = c.n or st.next_n
  st.next_n = math.max(st.next_n, c.n) + 1
  c.thread = c.thread or {}
  st.comments[c.id] = c
  return c
end

function M.remove(buf, id)
  buf = resolve_buf(buf)
  local st = M.get(buf)
  local c = st.comments[id]
  if c and c.mark then pcall(api.nvim_buf_del_extmark, buf, M.ns, c.mark) end
  st.comments[id] = nil
end

-- Persistence --------------------------------------------------------------

local dir = vim.fn.stdpath("state") .. "/latex-tutor"

local function state_file(buf)
  local name = api.nvim_buf_get_name(buf)
  if name == "" then return nil end
  local key = vim.fn.fnamemodify(name, ":p"):gsub("[/\\:]", "%%")
  return dir .. "/" .. key .. ".json"
end

function M.save(buf)
  buf = resolve_buf(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local path = state_file(buf)
  local st = M.bufs[buf]
  if not path or not st or not st.loaded then return end
  M.sync(buf)
  local comments = {}
  for _, c in pairs(st.comments) do
    local copy = vim.deepcopy(c)
    copy.mark, copy.pending = nil, nil
    comments[#comments + 1] = copy
  end
  if #comments == 0 and #st.summaries == 0 then
    os.remove(path)
    return
  end
  vim.fn.mkdir(dir, "p")
  local f = io.open(path, "w")
  if not f then return end
  f:write(vim.json.encode({
    version = 1,
    file = api.nvim_buf_get_name(buf),
    next_n = st.next_n,
    show_resolved = st.show_resolved,
    summaries = st.summaries,
    comments = comments,
  }))
  f:close()
end

local save_timers = {}
function M.save_soon(buf)
  buf = resolve_buf(buf)
  if save_timers[buf] then save_timers[buf]:stop() end
  save_timers[buf] = vim.defer_fn(function()
    save_timers[buf] = nil
    M.save(buf)
  end, 800)
end

-- Load saved comments, re-anchoring each by its quote in the current text
-- (the file may have been edited outside nvim since).
function M.load(buf)
  buf = resolve_buf(buf)
  local st = M.get(buf)
  if st.loaded then return st end
  st.loaded = true
  local path = state_file(buf)
  local f = path and io.open(path, "r")
  if not f then return st end
  local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
  f:close()
  if not ok or type(data) ~= "table" then return st end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  st.next_n = data.next_n or 1
  st.show_resolved = data.show_resolved or false
  st.summaries = data.summaries or {}
  for _, c in ipairs(data.comments or {}) do
    local row, col, er, ec, found = M.anchor(lines, (c.row or 0) + 1, c.quote,
      (c.end_row or c.row or 0) + 1, #lines)
    c.row, c.col, c.end_row, c.end_col = row, col, er, ec
    c.moved = not found and c.quote ~= nil and c.quote ~= ""
    M.add(buf, c)
  end
  return st
end

return M
