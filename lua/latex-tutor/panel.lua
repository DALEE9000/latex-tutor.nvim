-- The comment sidebar: review summaries on top, then one card per comment in
-- document order. It follows whichever .tex buffer you're in, highlights the
-- card for the comment under your cursor, and re-wraps when resized.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local scope = require("latex-tutor.scope")
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

local status_icon = { open = "○", edited = "✎", fixed = "✓", praise = "★" }
local status_hl = { open = "LatexTutorOpen", edited = "LatexTutorEdited", fixed = "LatexTutorFixed",
  praise = "LatexTutorPraiseSign" }

-- Praise isn't something to fix, so it has its own status and doesn't count.
local function status_of(src, c)
  if c.severity == "praise" then return "praise" end
  return store.status(src, c)
end

local function keyname(k)
  local p = config.get().keymaps.prefix:gsub("<localleader>", vim.g.maplocalleader == " " and "␣" or "‹ll›")
  return p .. k
end

-- Latest summary per question label.
local function summary_for(st, label)
  for i = #st.summaries, 1, -1 do
    if st.summaries[i].label == label then return st.summaries[i] end
  end
end

-- "▰▰▱▱▱ 2/5 fixed · 1 edited"
local function progress_line(src, list)
  local fixed, edited, total = 0, 0, 0
  for _, c in ipairs(list) do
    local s = status_of(src, c)
    if s ~= "praise" then total = total + 1 end
    if s == "fixed" then fixed = fixed + 1 elseif s == "edited" then edited = edited + 1 end
  end
  local slots = math.min(total, 10)
  local filled = total > 0 and math.floor(fixed / total * slots + 0.5) or 0
  local bar = string.rep("▰", filled) .. string.rep("▱", slots - filled)
  local text = string.format("%d/%d fixed", fixed, total)
  if edited > 0 then text = text .. string.format(" · %d edited", edited) end
  return bar, text, fixed, total
end

function M.render()
  if not M.is_open() then return end
  local src = M.src
  local width = math.max(20, api.nvim_win_get_width(M.win) - 1)
  local lines, hls = {}, {}
  M.rows, M.spans = {}, {}

  local function add(text, group, target)
    lines[#lines + 1] = text
    if group then hls[#hls + 1] = { #lines - 1, 0, -1, group } end
    if target then M.rows[#lines] = target end
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
      for _, l in ipairs({
        "<CR> open/jump · r resolve · R reply · dd delete",
        "J/K next/prev · a all questions · s show resolved in file · q close",
        string.format("%s review · %s next · %s check fixes · %s hide", keyname(config.get().keymaps.review),
          keyname(config.get().keymaps.next), keyname(config.get().keymaps.check), keyname(config.get().keymaps.hide)),
        "○ open · ✎ you edited it · ✓ fixed",
      }) do
        for _, w in ipairs(wrap(l, width - 1)) do add(" " .. w, "LatexTutorDim") end
      end
    end

    -- One comment: a single line, or the full card when it's the active one.
    local function comment(c)
      local g = config.group(c.severity)
      local status = status_of(src, c)
      local active = st.active == c.id
      local first = #lines + 1
      if not active then
        local head = string.format(" %s %d ", status_icon[status], c.n)
        local room = width - vim.fn.strdisplaywidth(head)
        local title = c.title
        if vim.fn.strdisplaywidth(title) > room then
          title = vim.fn.strcharpart(title, 0, math.max(1, room - 1)) .. "…"
        end
        add(head .. title, nil, c.id)
        local icon_end = #(" " .. status_icon[status])
        hl(0, icon_end, status_hl[status])
        hl(icon_end + 1, #head, status == "fixed" and "LatexTutorDim" or (g .. "Sign"))
        hl(#head, -1, status == "fixed" and "LatexTutorDim" or nil)
        M.spans[c.id] = { first - 1, #lines }
        return
      end
      if lines[#lines] ~= "" then add("") end
      local bar = status == "fixed" and "LatexTutorDim" or (g .. "Bar")
      local head = string.format("▎ %d  %s · L%d", c.n, config.sev(c.severity).label:upper(), c.row + 1)
      local tail = status_icon[status] .. " " .. status .. (c.confidence and (" · " .. c.confidence) or "")
      local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail))
      add(head .. string.rep(" ", pad) .. tail, nil, c.id)
      hl(0, #"▎", bar)
      hl(#"▎ ", #"▎ " + #tostring(c.n), status == "fixed" and "LatexTutorDim" or (g .. "Badge"))
      hl(#"▎ " + #tostring(c.n), #head, status == "fixed" and "LatexTutorDim" or (g .. "Sign"))
      hl(#head + pad, -1, status_hl[status])
      local function body(text, group, prefix)
        prefix = prefix or ""
        for k, w in ipairs(wrap(text, width - 2 - vim.fn.strdisplaywidth(prefix))) do
          add("▎ " .. (k == 1 and prefix or string.rep(" ", vim.fn.strdisplaywidth(prefix))) .. w, nil, c.id)
          hl(0, #"▎", bar)
          if group then hl(#"▎ ", -1, group) end
        end
      end
      body(c.title, "LatexTutorTitle")
      body(c.body)
      if c.hint and c.hint ~= "" then body(c.hint, "LatexTutorDim", "Hint: ") end
      if c.fix and c.fix ~= "" then body(c.fix, "LatexTutorDim", "Fix: ") end
      if c.moved then body("(the quoted text changed since this review)", "LatexTutorDim") end
      for _, t in ipairs(c.thread or {}) do
        body(t.text, t.role == "you" and nil or "LatexTutorDim", t.role == "you" and "↳ You: " or "↳ Tutor: ")
      end
      if c.pending then body("tutor is thinking…", "LatexTutorDim", "↳ ") end
      if status == "edited" and not c.pending then
        body(string.format("You edited this. %s asks the tutor to check.", keyname(config.get().keymaps.check)),
          "LatexTutorEdited")
      end
      add("")
      M.spans[c.id] = { first - 1, #lines }
    end

    -- One question: header, progress, summary (focused only), comments.
    local function question(label, list, sum, focused)
      add("")
      local head = label
      if sum then head = head .. " · " .. (verdict_text[sum.verdict] or sum.verdict or "") end
      for _, w in ipairs(wrap(head, width - 2)) do add(" " .. w, "LatexTutorTitle") end
      local bar, text, _, total = progress_line(src, list)
      if total > 0 then
        add(" " .. bar .. " " .. text)
        hl(1, 1 + #bar, "LatexTutorFixed")
        hl(1 + #bar, -1, "LatexTutorDim")
      end
      if focused and sum then
        for _, w in ipairs(wrap(sum.summary .. " (" .. ago(sum.at) .. ")", width - 2)) do add(" " .. w, "LatexTutorDim") end
      end
      if #list > 0 then add("") end
      for _, c in ipairs(list) do comment(c) end
    end

    local units = scope.units(src)
    local function unit_of(row1)
      for i = #units, 1, -1 do
        if units[i].s <= row1 then return units[i] end
      end
    end
    -- Group comments by the question they sit in.
    local groups, order = {}, {}
    for _, c in ipairs(store.list(src)) do
      local u = unit_of(c.row + 1)
      local key = u and u.label or "(before the first question)"
      if not groups[key] then groups[key] = { list = {}, s = u and u.s or 1 }; order[#order + 1] = key end
      table.insert(groups[key].list, c)
    end
    for _, sm in ipairs(st.summaries) do
      if not groups[sm.label] then
        local s_line
        for _, u in ipairs(units) do if u.label == sm.label then s_line = u.s; break end end
        if s_line then groups[sm.label] = { list = {}, s = s_line }; order[#order + 1] = sm.label end
      end
    end
    table.sort(order, function(x, y) return groups[x].s < groups[y].s end)

    local f = st.focus
    if st.show_all then
      add("")
      add(" All questions in this file (a: just this one)", "LatexTutorDim")
      for _, key in ipairs(order) do
        question(key, groups[key].list, summary_for(st, key), f and f.label == key)
      end
    else
      local label = f and f.label or "?"
      local list = store.list(src, { focus = true })
      local sum = summary_for(st, label)
      if #list == 0 and not sum then
        add("")
        for _, w in ipairs(wrap(label .. " · not reviewed yet", width - 2)) do add(" " .. w, "LatexTutorTitle") end
        add(" " .. keyname(config.get().keymaps.review) .. " reviews it.", "LatexTutorDim")
      else
        question(label, list, sum, true)
        if sum and #list == 0 then add(" No comments: nothing to fix.", "LatexTutorDim") end
      end
      -- Index of the other reviewed questions, one line each.
      local others = {}
      for _, key in ipairs(order) do if key ~= label then others[#others + 1] = key end end
      if #others > 0 then
        add("")
        add(" Other reviewed questions", "LatexTutorDim")
        for _, key in ipairs(others) do
          local g = groups[key]
          local sum2 = summary_for(st, key)
          local _, text, fixed, total = progress_line(src, g.list)
          local mark = (total > 0 and fixed == total) and "✓" or "·"
          local line = string.format(" %s %s  %s", mark, key, total > 0 and text or ((sum2 and verdict_text[sum2.verdict]) or ""))
          add(line, nil, { line = g.s })
          hl(0, #(" " .. mark), mark == "✓" and "LatexTutorFixed" or "LatexTutorDim")
          hl(#(" " .. mark .. " " .. key), -1, "LatexTutorDim")
        end
      end
    end
    add("")
    add(string.format(" %s next · %s check fixes · ? keys", keyname(config.get().keymaps.next),
      keyname(config.get().keymaps.check)), "LatexTutorDim")
  end

  vim.bo[M.buf].modifiable = true
  api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local len = #(lines[h[1] + 1] or "")
    local e = h[3] == -1 and len or math.min(h[3], len)
    if h[4] and h[2] < e then
      api.nvim_buf_set_extmark(M.buf, ns, h[1], h[2], { end_col = e, hl_group = h[4], priority = 100 })
    end
  end
  M.highlight(src and api.nvim_buf_is_valid(src) and store.get(src).active or nil, false)
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
  return type(id) == "string" and store.get(M.src).comments[id] or nil
end

local function line_under_cursor()
  local t = M.rows[api.nvim_win_get_cursor(M.win)[1]]
  return type(t) == "table" and t.line or nil
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
  local function open_row()
    local c = comment_under_cursor()
    if c then
      -- First <CR> on a one-line comment expands it here; a second jumps to it.
      if store.get(M.src).active ~= c.id then
        actions.activate(M.src, c)
      else
        actions.jump(M.src, c, true)
      end
      return
    end
    local line = line_under_cursor()
    if line then actions.jump_line(M.src, line) end
  end
  map("<CR>", open_row)
  map("o", open_row)
  map("a", function()
    local st = store.get(M.src)
    st.show_all = not st.show_all
    actions.refresh(M.src)
  end)
  map("v", function() actions.check(M.src) end)
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
