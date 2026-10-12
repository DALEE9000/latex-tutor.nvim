-- latex-tutor: Google-Docs-style review comments on LaTeX solutions, written
-- by Claude Code (your subscription, via `claude -p`), shown in nvim and in
-- the live TeXpresso preview.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local ui = require("latex-tutor.ui")
local panel = require("latex-tutor.panel")
local pdf = require("latex-tutor.pdf")
local prompt = require("latex-tutor.prompt")
local claude = require("latex-tutor.claude")
local scope = require("latex-tutor.scope")
local progress = require("latex-tutor.progress")

local M = {}

-- Separate from store.ns, which every render clears.
local ns_anchor = api.nvim_create_namespace("latex_tutor_anchor")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

local function is_tex(buf)
  return api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "tex"
end

-- Redraw everything that shows comments for `buf`.
function M.refresh(buf)
  ui.render(buf)
  if panel.is_open() and panel.src == buf then panel.render() end
  pdf.sync_soon(buf)
  store.save_soon(buf)
  if ui.card.id and not store.hidden then
    local c = store.get(buf).comments[ui.card.id]
    if c and api.nvim_get_current_buf() == buf then ui.show_card(c, true) else ui.close_card() end
  end
end

-- Hide / show ---------------------------------------------------------------

-- Close the panel and card and take every mark out of nvim and TeXpresso.
-- Comments are kept (extmarks still follow your edits); show() brings them back.
function M.set_hidden(hidden)
  if store.hidden == hidden then return end
  store.hidden = hidden
  if hidden then
    panel.close()
    ui.close_card()
  end
  for b in pairs(store.bufs) do
    if api.nvim_buf_is_valid(b) then
      if hidden then ui.set_active(b, nil) end
      ui.render(b)
      pdf.sync(b)
    end
  end
end

function M.show() M.set_hidden(false) end

function M.toggle_hidden()
  M.set_hidden(not store.hidden)
  local p = config.get().keymaps
  local key = (p.prefix .. (p.hide or "")):gsub("<localleader>", vim.g.maplocalleader == " " and "Space " or (vim.g.maplocalleader or "\\"))
  notify(store.hidden and ("Tutor hidden (" .. key .. " or :Tutor show brings it back)") or "Tutor shown")
end

-- Review ------------------------------------------------------------------

function M.review(buf, unit)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local file = api.nvim_buf_get_name(buf)
  if file == "" then return notify("Save the buffer first", vim.log.levels.WARN) end
  local key = "review:" .. buf
  if claude.running(key) then
    return notify("A review is already running for this buffer (" .. config.get().keymaps.prefix
      .. config.get().keymaps.cancel .. " cancels it)", vim.log.levels.WARN)
  end
  local cfg = config.get()
  if unit.e - unit.s + 1 > cfg.max_lines then
    local ok = vim.fn.confirm(string.format("Send %d lines to Claude?", unit.e - unit.s + 1), "&Yes\n&No", 2)
    if ok ~= 1 then return end
  end
  store.load(buf)
  M.show()
  local root = prompt.project_root(file)
  local prefs_path, prefs = prompt.find_prefs(file)
  if not prefs then
    notify("No tutoring preferences found (" .. prefs_path .. "); using defaults", vim.log.levels.WARN)
  end
  -- Tracks where the reviewed range moves to if you keep editing meanwhile.
  local anchor = api.nvim_buf_set_extmark(buf, ns_anchor, unit.s - 1, 0, { right_gravity = false })
  local tick = api.nvim_buf_get_changedtick(buf)
  ui.mark_pending(buf, unit.s, unit.e)
  ui.task_start(key, "Tutor · " .. unit.label)

  claude.run({
    key = key,
    prompt = prompt.review(buf, unit, root),
    system = prompt.system(prefs),
    schema = prompt.review_schema,
    cwd = root,
  }, function(err, out, session)
    ui.task_stop(key)
    if not api.nvim_buf_is_valid(buf) then return end
    ui.mark_pending(buf)
    local pos = api.nvim_buf_get_extmark_by_id(buf, ns_anchor, anchor, {})
    pcall(api.nvim_buf_del_extmark, buf, ns_anchor, anchor)
    if err then return notify(err, vim.log.levels.ERROR) end

    local shift = (pos[1] or (unit.s - 1)) - (unit.s - 1)
    local s0, e0 = unit.s - 1 + shift, unit.e - 1 + shift
    if api.nvim_buf_get_changedtick(buf) ~= tick then
      -- Lines may have been added inside the range; widen generously.
      e0 = e0 + 50
    end
    -- A new review of a range replaces its open comments (resolved ones stay).
    store.sync(buf)
    for _, c in ipairs(store.list(buf, { open = true })) do
      if c.row >= s0 and c.row <= e0 then store.remove(buf, c.id) end
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local counts = {}
    for _, rc in ipairs(out.comments or {}) do
      if type(rc) == "table" and rc.line then
        local L = rc.line + shift
        local row, col, er, ec = store.anchor(lines, L, rc.quote, rc.end_line and (rc.end_line + shift), 8)
        store.add(buf, {
          row = row, col = col, end_row = er, end_col = ec,
          quote = rc.quote, severity = config.severities[rc.severity] and rc.severity or "improve",
          title = rc.title or "(untitled)", body = rc.body or "", hint = rc.hint, fix = rc.fix,
          confidence = rc.confidence, session = session, created = os.time(), unit = unit.label,
        })
        counts[rc.severity] = (counts[rc.severity] or 0) + 1
      end
    end
    local st = store.get(buf)
    table.insert(st.summaries, {
      label = unit.label, verdict = out.verdict, summary = out.summary, at = os.time(), session = session,
    })
    while #st.summaries > 30 do table.remove(st.summaries, 1) end
    pcall(progress.record_review, file, unit, out)

    panel.src = buf
    if cfg.panel.auto_open and not panel.is_open() and not store.hidden then panel.open(buf) end
    M.refresh(buf)

    local parts = {}
    for _, sev in ipairs(config.severity_order) do
      if counts[sev] then parts[#parts + 1] = counts[sev] .. " " .. config.sev(sev).label:lower() end
    end
    notify(string.format("%s: %s", unit.label, #parts > 0 and table.concat(parts, ", ") or "no comments"))
  end)
end

function M.cancel(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local key = "review:" .. buf
  if claude.cancel(key) then
    ui.task_stop(key)
    ui.mark_pending(buf)
    notify("Review cancelled")
  else
    notify("No review running")
  end
end

-- Comment actions -----------------------------------------------------------

local function source_win(buf)
  local w = vim.fn.bufwinid(buf)
  if w ~= -1 then return w end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if win ~= panel.win and api.nvim_win_get_config(win).relative == "" then
      api.nvim_win_set_buf(win, buf)
      return win
    end
  end
end

function M.jump(buf, c, focus)
  M.show()
  local win = source_win(buf)
  if not win then return end
  store.sync(buf)
  api.nvim_win_set_cursor(win, { c.row + 1, c.col })
  if focus then api.nvim_set_current_win(win) end
  api.nvim_win_call(win, function() vim.cmd("normal! zv") end)
  ui.set_active(buf, c)
  panel.highlight(c.id, true)
  pdf.reveal(buf, c.row)
  if not panel.is_open() and api.nvim_get_current_win() == win then ui.show_card(c, true) end
end

function M.toggle_resolve(buf, c)
  c.resolved = not c.resolved
  if c.resolved then pcall(progress.record_resolve, api.nvim_buf_get_name(buf), c, "you") end
  M.refresh(buf)
end

function M.delete(buf, c)
  store.remove(buf, c.id)
  M.refresh(buf)
end

function M.reply(buf, c)
  ui.compose(string.format("Reply to #%d · %s", c.n, c.title), function(text)
    table.insert(c.thread, { role = "you", text = text, at = os.time() })
    c.pending = true
    M.refresh(buf)

    store.sync(buf)
    -- Context: the exercise containing the comment, as it reads now.
    local unit = scope.unit_at(buf, c.row + 1)
    local file = api.nvim_buf_get_name(buf)
    local root = prompt.project_root(file)
    local _, prefs = prompt.find_prefs(file)
    local key = "reply:" .. c.id
    ui.task_start(key, "Tutor replying to #" .. c.n)
    local function run(resume)
      claude.run({
        key = key,
        prompt = prompt.reply(buf, c, text, unit.s, unit.e),
        system = prompt.system(prefs),
        schema = prompt.reply_schema,
        cwd = root,
        resume = resume,
      }, function(err, out, session)
        if err and resume then return run(nil) end -- session gone: retry fresh
        ui.task_stop(key)
        c.pending = nil
        if err then
          notify(err, vim.log.levels.ERROR)
        else
          table.insert(c.thread, { role = "tutor", text = out.reply or "", at = os.time() })
          c.session = session or c.session
          if out.resolved and config.get().auto_resolve then
            c.resolved = true
            pcall(progress.record_resolve, file, c, "tutor")
            notify(string.format("#%d resolved by the tutor", c.n))
          end
        end
        if api.nvim_buf_is_valid(buf) then M.refresh(buf) end
      end)
    end
    run(c.session)
  end)
end

local function cursor_comment()
  local buf = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  store.sync(buf)
  return buf, store.at(buf, pos[1] - 1, pos[2])
end

local function with_cursor_comment(fn)
  return function()
    local buf, c = cursor_comment()
    if not c then return notify("No comment under the cursor", vim.log.levels.WARN) end
    fn(buf, c)
  end
end

function M.next(dir)
  local buf = api.nvim_get_current_buf()
  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1
  store.sync(buf)
  local list = store.list(buf, { open = true })
  if #list == 0 then return notify("No open comments") end
  local target
  if dir > 0 then
    for _, c in ipairs(list) do
      if c.row > row or (c.row == row and c.col > col) then target = c; break end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      local c = list[i]
      if c.row < row or (c.row == row and c.col < col) then target = c; break end
    end
    target = target or list[#list]
  end
  M.jump(buf, target, true)
end

-- Cursor tracking: active highlight, panel card, auto card.
local cursor_timer
local function on_cursor()
  if cursor_timer then cursor_timer:stop() end
  cursor_timer = vim.defer_fn(function()
    cursor_timer = nil
    local buf = api.nvim_get_current_buf()
    if store.hidden or not is_tex(buf) or not store.bufs[buf] then return end
    local _, c = cursor_comment()
    ui.set_active(buf, c)
    if panel.is_open() then
      panel.highlight(c and c.id, true)
    elseif c and config.get().card.auto and not vim.fn.mode():find("^i") then
      ui.show_card(c)
    end
    if not c and ui.card.win and api.nvim_get_current_win() ~= ui.card.win then ui.close_card() end
  end, 120)
end

-- Buffer setup ----------------------------------------------------------------

local attached = {}

local function keymaps(buf)
  local k = config.get().keymaps
  if not k or not k.prefix then return end
  local map = function(mode, key, fn, desc)
    if key then vim.keymap.set(mode, k.prefix .. key, fn, { buffer = buf, desc = "Tutor: " .. desc }) end
  end
  map("n", k.review, function() M.review(buf, scope.unit_at(buf, api.nvim_win_get_cursor(0)[1])) end, "review exercise")
  map("x", k.review, function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    if a > b then a, b = b, a end
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    M.review(buf, scope.range(buf, a, b))
  end, "review selection")
  map("n", k.review_file, function() M.review(buf, scope.file(buf)) end, "review whole file")
  map("n", k.panel, function() M.show(); panel.toggle(buf) end, "toggle comment panel")
  map("n", k.next, function() M.next(1) end, "next comment")
  map("n", k.prev, function() M.next(-1) end, "previous comment")
  map("n", k.card, with_cursor_comment(function(_, c) M.show(); ui.show_card(c, true) end), "show comment")
  map("n", k.resolve, with_cursor_comment(M.toggle_resolve), "resolve comment")
  map("n", k.reply, with_cursor_comment(M.reply), "reply to comment")
  map("n", k.delete, with_cursor_comment(M.delete), "delete comment")
  map("n", k.pdf, function()
    notify("TeXpresso annotations " .. (pdf.toggle(buf) and "on" or "off"))
  end, "toggle PDF annotations")
  map("n", k.cancel, function() M.cancel(buf) end, "cancel review")
  map("n", k.hide, M.toggle_hidden, "hide / show everything")
  map("n", k.progress, progress.open, "progress report")
  map("n", k.prefs, function() vim.cmd.edit(vim.fn.fnameescape((prompt.find_prefs(api.nvim_buf_get_name(buf))))) end,
    "edit tutoring preferences")
end

function M.attach(buf)
  if attached[buf] or not is_tex(buf) then return end
  attached[buf] = true
  store.load(buf)
  keymaps(buf)
  ui.render(buf)
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, new_last)
      pdf.on_lines(b, first, new_last)
    end,
    on_detach = function(_, b) attached[b] = nil end,
  })
  -- Give TeXpresso time to open the file before the first annotation push.
  pdf.sync_soon(buf, 1500)
end

function M.setup(opts)
  config.setup(opts)
  ui.highlights()
  panel.set_actions(M)
  pdf.hook()

  local group = api.nvim_create_augroup("LatexTutor", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = group, pattern = "tex",
    callback = function(a) M.attach(a.buf) end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = ui.highlights })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, pattern = "*.tex", callback = on_cursor })
  api.nvim_create_autocmd("BufEnter", {
    group = group, pattern = "*.tex",
    callback = function(a)
      if panel.is_open() and panel.src ~= a.buf and attached[a.buf] then
        panel.src = a.buf
        panel.render()
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function() vim.schedule(panel.fit) end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if panel.is_open() and vim.tbl_contains(vim.v.event.windows or {}, panel.win) then panel.render() end
    end,
  })
  api.nvim_create_autocmd({ "BufWritePost", "BufUnload" }, {
    group = group, pattern = "*.tex",
    callback = function(a) if store.bufs[a.buf] then store.save(a.buf) end end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() for b in pairs(store.bufs) do store.save(b) end end,
  })

  api.nvim_create_user_command("Tutor", function(o)
    local buf = api.nvim_get_current_buf()
    local what = o.args
    if o.range > 0 and what == "" then
      M.review(buf, scope.range(buf, o.line1, o.line2))
    elseif what == "file" then
      M.review(buf, scope.file(buf))
    elseif what == "" or what == "exercise" then
      M.review(buf, scope.unit_at(buf, api.nvim_win_get_cursor(0)[1]))
    elseif what == "panel" then M.show(); panel.toggle(buf)
    elseif what == "progress" then progress.open()
    elseif what == "hide" then if not store.hidden then M.toggle_hidden() end
    elseif what == "show" then if store.hidden then M.toggle_hidden() end
    elseif what == "next" then M.next(1)
    elseif what == "prev" then M.next(-1)
    elseif what == "cancel" then M.cancel(buf)
    elseif what == "pdf" then notify("TeXpresso annotations " .. (pdf.toggle(buf) and "on" or "off"))
    elseif what == "prefs" then vim.cmd.edit(vim.fn.fnameescape((prompt.find_prefs(api.nvim_buf_get_name(buf)))))
    elseif what == "clear" then
      for _, c in ipairs(store.list(buf)) do store.remove(buf, c.id) end
      store.get(buf).summaries = {}
      M.refresh(buf)
    else
      notify("Unknown :Tutor argument " .. what, vim.log.levels.ERROR)
    end
  end, {
    nargs = "?", range = true,
    complete = function() return { "exercise", "file", "panel", "hide", "show", "progress", "next", "prev", "cancel", "pdf", "prefs", "clear" } end,
    desc = "latex-tutor",
  })

  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then M.attach(b) end
  end
end

return M
