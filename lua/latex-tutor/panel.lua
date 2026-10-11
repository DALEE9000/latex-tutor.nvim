-- The comment sidebar: review summaries on top, then one card per comment in
-- document order. It follows whichever .tex buffer you're in, highlights the
-- card for the comment under your cursor, and re-wraps when resized.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local M = { win = nil, buf = nil, src = nil, rows = {}, spans = {}, help = false, active = nil }

local ns = api.nvim_create_namespace("latex_tutor_panel")
local ns_act = api.nvim_create_namespace("latex_tutor_panel_active")

local actions -- set by init to avoid a require cycle

function M.set_actions(a) actions = a end

function M.is_open()
  return M.win ~= nil and api.nvim_win_is_valid(M.win)
end

-- Greedy word wrap by display width; hard-splits words longer than `width`.
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= "" then out[#out + 1] = line; line = "" end
        local cut = vim.fn.strcharpart(word, 0, width)
        out[#out + 1] = cut
        word = vim.fn.strcharpart(word, vim.fn.strchars(cut))
      end
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line) + 1 + vim.fn.strdisplaywidth(word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function ago(t)
  local d = os.time() - (t or os.time())
  if d < 60 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  if d < 86400 then return math.floor(d / 3600) .. "h ago" end
  return os.date("%b %d", t)
end

local verdict_text = {
  correct = "✓ correct", minor_issues = "~ minor issues",
  major_issues = "✗ major issues", incomplete = "… incomplete",
}

function M.render()
  if not M.is_open() then return end
  local src = M.src
  local width = math.max(20, api.nvim_win_get_width(M.win) - 1)
  local lines, hls = {}, {}
  M.rows, M.spans = {}, {}

  local function add(text, group, id)
    lines[#lines + 1] = text
    if group then hls[#hls + 1] = { #lines - 1, 0, -1, group } end
    if id then M.rows[#lines] = id end
  end
  local function hl(col_s, col_e, group)
    hls[#hls + 1] = { #lines - 1, col_s, col_e, group }
  end

  if not (src and api.nvim_buf_is_valid(src)) then
    add(" No .tex buffer", "LatexTutorDim")
  else
    local st = store.get(src)
    store.sync(src)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(src), ":t")
    add(" TUTOR " .. " " .. name)
    hl(0, 7, "LatexTutorHeader")
    hl(7, -1, "LatexTutorTitle")

    if M.help then
      local p = config.get().keymaps
      for _, l in ipairs({
        "<CR> jump   r resolve   R reply   dd delete",
        "J/K next/prev card   s show resolved   q close",
        string.format("in .tex: %s%s review exercise · %s%s file", p.prefix, p.review, p.prefix, p.review_file),
      }) do
        for _, w in ipairs(wrap(l, width - 1)) do add(" " .. w, "LatexTutorDim") end
      end
    end

    for i = #st.summaries, math.max(1, #st.summaries - 2), -1 do
      local s = st.summaries[i]
      add("")
      local head = string.format("%s · %s · %s", s.label, verdict_text[s.verdict] or s.verdict or "", ago(s.at))
      for _, w in ipairs(wrap(head, width - 2)) do add(" " .. w, "LatexTutorTitle") end
      for _, w in ipairs(wrap(s.summary, width - 2)) do add(" " .. w, "LatexTutorDim") end
    end

    local all = store.list(src)
    local open, shown = 0, store.list(src, { visible = true })
    for _, c in ipairs(all) do if not c.resolved then open = open + 1 end end
    add("")
    add(string.format(" %d open · %d resolved%s", open, #all - open,
      st.show_resolved and " (shown)" or ""), "LatexTutorDim")
    if #shown == 0 then
      add("")
      add(#st.summaries == 0 and " No comments yet." or " Nothing open. ", "LatexTutorDim")
      add(" " .. config.get().keymaps.prefix .. config.get().keymaps.review .. " reviews the exercise under the cursor.", "LatexTutorDim")
    end

    for _, c in ipairs(shown) do
      local g = config.group(c.severity)
      local bar = c.resolved and "LatexTutorDim" or (g .. "Bar")
      local first = #lines + 1
      add("")
      local head = string.format("▎ %d  %s · L%d", c.n, config.sev(c.severity).label:upper(), c.row + 1)
      local tail = (c.resolved and "✓ " or "") .. (c.confidence or "")
      local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail))
      add(head .. string.rep(" ", pad) .. tail, nil, c.id)
      hl(0, #"▎", bar)
      hl(#"▎ ", #"▎ " + #tostring(c.n), c.resolved and "LatexTutorDim" or (g .. "Badge"))
      hl(#"▎ " + #tostring(c.n), #head, c.resolved and "LatexTutorDim" or (g .. "Sign"))
      hl(#head, -1, "LatexTutorDim")
      local function body(text, group, prefix)
        prefix = prefix or ""
        for k, w in ipairs(wrap(text, width - 2 - vim.fn.strdisplaywidth(prefix))) do
          add("▎ " .. (k == 1 and prefix or string.rep(" ", vim.fn.strdisplaywidth(prefix))) .. w, nil, c.id)
          hl(0, #"▎", bar)
          if group then hl(#"▎ ", -1, group) end
        end
      end
      body(c.title, c.resolved and "LatexTutorDim" or "LatexTutorTitle")
      if not c.resolved then
        body(c.body)
        if c.hint and c.hint ~= "" then body(c.hint, "LatexTutorDim", "Hint: ") end
        if c.fix and c.fix ~= "" then body(c.fix, "LatexTutorDim", "Fix: ") end
        if c.moved then body("(the quoted text changed since this review)", "LatexTutorDim") end
      end
      for _, t in ipairs(c.thread or {}) do
        body(t.text, t.role == "you" and nil or "LatexTutorDim", t.role == "you" and "↳ You: " or "↳ Tutor: ")
      end
      if c.pending then body("tutor is thinking…", "LatexTutorDim", "↳ ") end
      M.spans[c.id] = { first, #lines }
    end
  end

  vim.bo[M.buf].modifiable = true
  api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local len = #(lines[h[1] + 1] or "")
    local e = h[3] == -1 and len or math.min(h[3], len)
    if h[2] < e then
      api.nvim_buf_set_extmark(M.buf, ns, h[1], h[2], { end_col = e, hl_group = h[4], priority = 100 })
    end
  end
  M.highlight(M.active, false)
end

-- Highlight a card and, if `scroll`, bring it into view without focusing.
function M.highlight(id, scroll)
  M.active = id
  if not M.is_open() then return end
  api.nvim_buf_clear_namespace(M.buf, ns_act, 0, -1)
  local span = id and M.spans[id]
  if not span then return end
  for r = span[1] + 1, span[2] do
    api.nvim_buf_set_extmark(M.buf, ns_act, r - 1, 0, { line_hl_group = "LatexTutorActive", priority = 50 })
  end
  if scroll then
    local top = vim.fn.line("w0", M.win)
    local bot = vim.fn.line("w$", M.win)
    if span[1] + 1 < top or span[2] > bot then
      api.nvim_win_call(M.win, function()
        api.nvim_win_set_cursor(M.win, { math.min(span[1] + 1, api.nvim_buf_line_count(M.buf)), 0 })
        vim.cmd("normal! zt")
      end)
    end
  end
end

local function comment_under_cursor()
  local id = M.rows[api.nvim_win_get_cursor(M.win)[1]]
  return id and store.get(M.src).comments[id] or nil
end

local function move_card(dir)
  local row = api.nvim_win_get_cursor(M.win)[1]
  local starts = {}
  for _, span in pairs(M.spans) do starts[#starts + 1] = span[1] + 1 end
  table.sort(starts)
  local target
  if dir > 0 then
    for _, s in ipairs(starts) do if s > row then target = s; break end end
  else
    for i = #starts, 1, -1 do if starts[i] < row then target = starts[i]; break end end
  end
  if target then api.nvim_win_set_cursor(M.win, { target, 0 }) end
end

local function ensure_buf()
  if M.buf and api.nvim_buf_is_valid(M.buf) then return end
  M.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(M.buf, "latex-tutor://comments")
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "latextutor"
  vim.bo[M.buf].modifiable = false
  local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = M.buf, nowait = true, silent = true }) end
  local with = function(fn)
    return function()
      local c = comment_under_cursor()
      if c then fn(M.src, c) end
    end
  end
  map("<CR>", with(function(b, c) actions.jump(b, c, true) end))
  map("o", with(function(b, c) actions.jump(b, c, true) end))
  map("r", with(function(b, c) actions.toggle_resolve(b, c) end))
  map("R", with(function(b, c) actions.reply(b, c) end))
  map("dd", with(function(b, c) actions.delete(b, c) end))
  map("s", function()
    local st = store.get(M.src)
    st.show_resolved = not st.show_resolved
    actions.refresh(M.src)
  end)
  map("J", function() move_card(1) end)
  map("K", function() move_card(-1) end)
  map("?", function() M.help = not M.help; M.render() end)
  map("q", M.close)
end

-- Configured width, but never more than ~38% of the screen so the source
-- stays readable on a narrow terminal / split.
local function target_width()
  return math.max(28, math.min(config.get().panel.width, math.floor(vim.o.columns * 0.38)))
end

function M.fit()
  if M.is_open() then
    api.nvim_win_set_width(M.win, target_width())
    M.render()
  end
end

function M.open(src)
  if src then M.src = src end
  ensure_buf()
  if not M.is_open() then
    local cur = api.nvim_get_current_win()
    vim.cmd("botright vertical " .. target_width() .. "split")
    M.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(M.win, M.buf)
    local wo = vim.wo[M.win]
    wo.number, wo.relativenumber = false, false
    wo.signcolumn, wo.foldcolumn = "no", "0"
    wo.wrap, wo.list, wo.spell = false, false, false
    wo.cursorline = false
    wo.winfixwidth = true -- survives the VimResized `wincmd =` in autocmds.lua
    wo.statuscolumn = ""
    wo.winbar = ""
    if api.nvim_win_is_valid(cur) then api.nvim_set_current_win(cur) end
  end
  M.render()
end

function M.close()
  if M.is_open() then pcall(api.nvim_win_close, M.win, true) end
  M.win = nil
end

function M.toggle(src)
  if M.is_open() then M.close() else M.open(src) end
end

return M
