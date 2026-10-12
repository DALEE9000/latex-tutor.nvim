-- In-buffer rendering: highlighted ranges, numbered signs, end-of-line notes,
-- the floating comment card, a progress spinner and the reply composer.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local M = {}

local ns_active = api.nvim_create_namespace("latex_tutor_active")
local ns_pending = api.nvim_create_namespace("latex_tutor_pending")

function M.highlights()
  local set = function(name, val)
    val.default = true
    api.nvim_set_hl(0, name, val)
  end
  for name, s in pairs(config.severities) do
    local g = config.group(name)
    set(g, { bg = s.tint, sp = s.hex, undercurl = name ~= "praise", underline = name == "praise" })
    set(g .. "Sign", { fg = s.hex, bold = true })
    set(g .. "Virt", { fg = s.hex, italic = true })
    set(g .. "Badge", { fg = "#16181d", bg = s.hex, bold = true })
    set(g .. "Bar", { fg = s.hex })
  end
  set("LatexTutorResolved", { sp = "#6c7086", underdotted = true })
  set("LatexTutorActive", { bg = "#3a3f58" })
  set("LatexTutorPending", { fg = "#7f849c" })
  set("LatexTutorTitle", { bold = true })
  set("LatexTutorDim", { link = "Comment" })
  set("LatexTutorHeader", { fg = "#16181d", bg = "#c0caf5", bold = true })
end

-- Draw every visible comment of `buf`. Positions are read back from the old
-- extmarks first so edits made since the last render are kept.
function M.render(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local cfg = config.get()
  store.sync(buf)
  api.nvim_buf_clear_namespace(buf, store.ns, 0, -1)
  local n = api.nvim_buf_line_count(buf)
  for _, c in ipairs(store.list(buf, { visible = true })) do
    local g = config.group(c.severity)
    local row = math.min(c.row, n - 1)
    local end_row = math.min(math.max(c.end_row, row), n - 1)
    local start_len = #(api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
    local end_len = #(api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or "")
    local col = math.min(c.col, start_len)
    local end_col = math.min(c.end_col, end_len)
    if end_row == row and end_col < col then end_col = col end
    local o = store.hidden and {
      end_row = end_row, end_col = end_col, right_gravity = false, end_right_gravity = true, strict = false,
    } or {
      end_row = end_row,
      end_col = end_col,
      hl_group = c.resolved and "LatexTutorResolved" or g,
      hl_mode = "combine",
      priority = 150,
      right_gravity = false,
      end_right_gravity = true,
      sign_text = c.n < 100 and tostring(c.n) or "#",
      sign_hl_group = c.resolved and "LatexTutorDim" or (g .. "Sign"),
      strict = false,
    }
    if cfg.virtual_text and not c.resolved and not store.hidden then
      o.virt_text = { { " " .. c.n .. " ", g .. "Badge" }, { " " .. c.title, g .. "Virt" } }
      o.virt_text_pos = "eol"
    end
    c.mark = api.nvim_buf_set_extmark(buf, store.ns, row, col, o)
  end
end

function M.set_active(buf, c)
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_clear_namespace(buf, ns_active, 0, -1)
  if c then
    api.nvim_buf_set_extmark(buf, ns_active, c.row, c.col, {
      end_row = c.end_row, end_col = c.end_col, hl_group = "LatexTutorActive",
      hl_mode = "combine", priority = 160, strict = false,
    })
  end
end

-- Faint gutter marks over a range being reviewed.
function M.mark_pending(buf, s, e)
  api.nvim_buf_clear_namespace(buf, ns_pending, 0, -1)
  if not s then return end
  for r = s - 1, e - 1 do
    api.nvim_buf_set_extmark(buf, ns_pending, r, 0, {
      sign_text = "┊", sign_hl_group = "LatexTutorPending", priority = 5, strict = false,
    })
  end
end

-- Card --------------------------------------------------------------------

-- Markdown body shared by the card (the panel renders its own layout).
function M.card_lines(c)
  local s = config.sev(c.severity)
  local out = {
    string.format("**%s**", c.title),
    string.format("*%s · line %d · confidence %s%s*", s.label, c.row + 1, c.confidence or "?",
      c.resolved and " · resolved" or (c.moved and " · text changed" or "")),
    "",
  }
  vim.list_extend(out, vim.split(c.body or "", "\n", { plain = true }))
  if c.hint and c.hint ~= "" then
    out[#out + 1] = ""
    for i, l in ipairs(vim.split(c.hint, "\n", { plain = true })) do
      out[#out + 1] = "> " .. (i == 1 and "**Hint:** " or "") .. l
    end
  end
  if c.fix and c.fix ~= "" then
    vim.list_extend(out, { "", "**Suggested fix:**", "```latex" })
    vim.list_extend(out, vim.split(c.fix, "\n", { plain = true }))
    out[#out + 1] = "```"
  end
  for _, t in ipairs(c.thread or {}) do
    out[#out + 1] = ""
    out[#out + 1] = (t.role == "you" and "↳ **You:** " or "↳ **Tutor:** ") .. (t.text:gsub("\n", " "))
  end
  if c.pending then
    vim.list_extend(out, { "", "↳ *tutor is thinking…*" })
  end
  local p = config.get().keymaps.prefix:gsub("<localleader>", "‹ll›")
  vim.list_extend(out, { "", string.format("`%s%s` resolve · `%s%s` reply · `%s%s` next",
    p, config.get().keymaps.resolve, p, config.get().keymaps.reply, p, config.get().keymaps.next) })
  return out
end

M.card = { win = nil, id = nil }

function M.close_card()
  if M.card.win and api.nvim_win_is_valid(M.card.win) then
    pcall(api.nvim_win_close, M.card.win, true)
  end
  M.card.win, M.card.id = nil, nil
end

function M.show_card(c, force)
  if not force and M.card.id == c.id and M.card.win and api.nvim_win_is_valid(M.card.win) then
    return
  end
  M.close_card()
  local cfg = config.get()
  local g = config.group(c.severity)
  local _, win = vim.lsp.util.open_floating_preview(M.card_lines(c), "markdown", {
    border = "rounded",
    max_width = math.min(cfg.card.max_width, vim.o.columns - 6),
    max_height = math.max(8, math.floor(vim.o.lines * 0.45)),
    wrap = true,
    focusable = true,
    focus_id = "latex_tutor_card",
    close_events = { "BufLeave", "InsertEnter" },
    title = { { " " .. c.n .. " ", g .. "Badge" }, { " " .. config.sev(c.severity).label .. " ", g .. "Sign" } },
    title_pos = "left",
  })
  if win then
    vim.wo[win].conceallevel = 2
    M.card.win, M.card.id = win, c.id
  end
end

-- Spinner -----------------------------------------------------------------

local spin = { win = nil, buf = nil, timer = nil, tasks = {} }
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function spin_draw()
  local items = {}
  for _, t in pairs(spin.tasks) do items[#items + 1] = t end
  if #items == 0 then
    if spin.timer then spin.timer:stop(); spin.timer:close(); spin.timer = nil end
    if spin.win and api.nvim_win_is_valid(spin.win) then api.nvim_win_close(spin.win, true) end
    spin.win = nil
    return
  end
  table.sort(items, function(a, b) return a.t0 < b.t0 end)
  local f = frames[(math.floor(vim.uv.now() / 90) % #frames) + 1]
  local lines = {}
  for _, t in ipairs(items) do
    lines[#lines + 1] = string.format(" %s %s · %ds ", f, t.text, math.floor((vim.uv.now() - t.t0) / 1000))
  end
  local w = 10
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  if not (spin.buf and api.nvim_buf_is_valid(spin.buf)) then
    spin.buf = api.nvim_create_buf(false, true)
  end
  api.nvim_buf_set_lines(spin.buf, 0, -1, false, lines)
  local wc = { relative = "editor", anchor = "NE", row = 1, col = vim.o.columns - 1, width = w,
    height = #lines, style = "minimal", border = "rounded", focusable = false, zindex = 60 }
  if spin.win and api.nvim_win_is_valid(spin.win) then
    api.nvim_win_set_config(spin.win, wc)
  else
    wc.noautocmd = true
    spin.win = api.nvim_open_win(spin.buf, false, wc)
    vim.wo[spin.win].winhighlight = "Normal:NormalFloat,FloatBorder:LatexTutorPending"
  end
end

function M.task_start(key, text)
  spin.tasks[key] = { text = text, t0 = vim.uv.now() }
  if not spin.timer then
    spin.timer = vim.uv.new_timer()
    spin.timer:start(0, 100, vim.schedule_wrap(spin_draw))
  end
end

function M.task_stop(key)
  spin.tasks[key] = nil
  vim.schedule(spin_draw)
end

-- Reply composer ------------------------------------------------------------

-- A small markdown scratch float. <C-s> (or <CR> in normal mode) sends,
-- q / <Esc> in normal mode cancels.
function M.compose(title, on_submit)
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "markdown"
  vim.bo[b].bufhidden = "wipe"
  local w = math.min(76, vim.o.columns - 6)
  local h = math.min(8, vim.o.lines - 6)
  local win = api.nvim_open_win(b, true, {
    relative = "editor", row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, style = "minimal", border = "rounded",
    title = " " .. title .. " ", title_pos = "left",
    footer = " <C-s> send · q cancel ", footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    pcall(api.nvim_win_close, win, true)
    if text ~= "" then on_submit(text) end
  end
  local function cancel()
    pcall(api.nvim_win_close, win, true)
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = b })
  vim.keymap.set("n", "<CR>", submit, { buffer = b })
  vim.keymap.set("n", "q", cancel, { buffer = b })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = b })
  vim.cmd("startinsert")
end

return M
