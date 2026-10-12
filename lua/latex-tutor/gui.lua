-- The GUI window: a local server (gui/server.py) shows your compiled PDF with
-- comment cards in the margin, in a browser app window (Edge --app on WSL).
-- nvim pushes state to it over the server's stdin; clicks come back on its
-- stdout as actions.

local api = vim.api
local config = require("latex-tutor.config")
local store = require("latex-tutor.store")
local scope = require("latex-tutor.scope")
local ui = require("latex-tutor.ui")
local M = { job = nil, port = nil, buf = nil }

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

function M.running()
  return M.job ~= nil and M.port ~= nil
end

local function send(msg)
  if not M.job then return end
  pcall(function() M.job:write(vim.json.encode(msg) .. "\n") end)
end

local function ago(t)
  local d = os.time() - (t or os.time())
  if d < 60 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. " min ago" end
  if d < 86400 then return math.floor(d / 3600) .. " h ago" end
  return os.date("%b %d", t)
end

local function summary_for(st, label)
  for i = #st.summaries, 1, -1 do
    local s = st.summaries[i]
    if s.label == label then
      return { verdict = s.verdict, summary = s.summary, ago = ago(s.at) }
    end
  end
end

-- Everything the window draws, for buffer `buf`.
function M.state(buf)
  local st = store.sync(buf)
  local file = api.nvim_buf_get_name(buf)
  local units = scope.units(buf)
  local function unit_of(row1)
    for i = #units, 1, -1 do
      if units[i].s <= row1 then return units[i] end
    end
  end
  local all = store.list(buf)
  local shown = st.show_all and all or store.list(buf, { focus = true })
  local comments = {}
  for _, c in ipairs(shown) do
    local u = unit_of(c.row + 1)
    comments[#comments + 1] = {
      id = c.id, n = c.n, severity = c.severity, sevlabel = config.sev(c.severity).label,
      title = c.title, body = c.body, hint = c.hint, fix = c.fix, thread = c.thread,
      status = store.status(buf, c), row = c.row, end_row = c.end_row, confidence = c.confidence,
      pending = c.pending or nil, moved = c.moved or nil, group = u and u.label or "",
    }
  end
  -- Questions for the picker, with fixed/total counts.
  local counts = {}
  for _, c in ipairs(all) do
    local u = unit_of(c.row + 1)
    if u and c.severity ~= "praise" then
      counts[u.label] = counts[u.label] or { fixed = 0, total = 0 }
      counts[u.label].total = counts[u.label].total + 1
      if c.resolved then counts[u.label].fixed = counts[u.label].fixed + 1 end
    end
  end
  local questions, groups = {}, {}
  for _, u in ipairs(units) do
    if not u.label:match("^lines ") then
      local k = counts[u.label] or { fixed = 0, total = 0 }
      local sum = summary_for(st, u.label)
      questions[#questions + 1] = { label = u.label, line = u.s, fixed = k.fixed, total = k.total,
        verdict = sum and sum.verdict or nil }
      if k.total > 0 or sum then groups[#groups + 1] = { label = u.label, summary = sum } end
    end
  end
  local f = st.focus or {}
  return {
    type = "state",
    file = file,
    name = vim.fn.fnamemodify(file, ":t"),
    root = require("latex-tutor.prompt").project_root(file),
    focus = f.label and { label = f.label, s = f.s, e = f.e } or nil,
    -- the line you're on, so the window can keep it in view as you type
    cursor = api.nvim_get_current_buf() == buf and api.nvim_win_get_cursor(0)[1] or nil,
    show_all = st.show_all or false,
    active = st.active,
    comments = comments,
    questions = questions,
    groups = groups,
    summary = f.label and summary_for(st, f.label) or nil,
    running = ui.tasks(),
  }
end

local push_timer
function M.push_soon(buf)
  if not M.running() then return end
  buf = buf or M.buf
  if buf ~= M.buf or not (buf and api.nvim_buf_is_valid(buf)) then return end
  if push_timer then push_timer:stop() end
  push_timer = vim.defer_fn(function()
    push_timer = nil
    if M.running() and api.nvim_buf_is_valid(buf) then
      send(M.state(buf))
      M.live_soon(buf)  -- no-op unless the question or text changed
    end
  end, 60)
end

function M.compile(buf)
  buf = buf or M.buf
  if not M.running() or buf ~= M.buf then return end
  local file = api.nvim_buf_get_name(buf)
  if file ~= "" then send({ type = "compile", file = file, engine = config.get().gui.engine }) end
end

-- Live preview: send the unsaved text a moment after you stop typing. Only
-- the question under the cursor is built (the whole file in "All questions"
-- mode, or when the cursor isn't in a question).
local live_timer, live_sent
function M.live_soon(buf, now)
  local g = config.get().gui
  if not g.live or not M.running() then return end
  buf = buf or M.buf
  if buf ~= M.buf or not (buf and api.nvim_buf_is_valid(buf)) then return end
  if live_timer then live_timer:stop() end
  live_timer = vim.defer_fn(function()
    live_timer = nil
    if not (M.running() and api.nvim_buf_is_valid(buf)) then return end
    local st = store.get(buf)
    local f = (not st.show_all) and st.focus or nil
    local tick = api.nvim_buf_get_changedtick(buf)
    local key = table.concat({ buf, tick, f and f.s or 0, f and f.e or 0 }, ":")
    if key == live_sent then return end
    live_sent = key
    send({
      type = "live", file = api.nvim_buf_get_name(buf), engine = g.engine,
      lines = api.nvim_buf_get_lines(buf, 0, -1, false),
      s = f and f.s or nil, e = f and f.e or nil, label = f and f.label or nil,
    })
  end, now and 0 or g.live_delay)
end

-- The progress report, shown over the PDF in the window.
function M.show_progress()
  if not M.running() then return false end
  send({ type = "progress", md = table.concat(require("latex-tutor.progress").report(), "\n") })
  return true
end

-- A Σ answer (math.lua), shown over the PDF with Insert / Copy buttons.
function M.show_math(r)
  if not M.running() or r.buf ~= M.buf then return false end
  send({ type = "math", ask = r.ask, text = r.text, line = r.e, out = r.out,
    root = require("latex-tutor.prompt").project_root(api.nvim_buf_get_name(r.buf)) })
  return true
end

-- Follow the .tex buffer you switch to.
function M.follow(buf)
  if not M.running() or buf == M.buf then return end
  M.buf = buf
  M.push_soon(buf)
  M.compile(buf)
end

local function open_window(url)
  local g = config.get().gui
  local cmd
  if type(g.open_cmd) == "function" then
    return g.open_cmd(url)
  elseif type(g.open_cmd) == "table" then
    cmd = vim.list_extend(vim.deepcopy(g.open_cmd), { url })
  elseif vim.fn.has("wsl") == 1 or vim.env.WSL_DISTRO_NAME then
    -- A chromeless Edge app window on the Windows side; WSL forwards localhost.
    cmd = { "/mnt/c/Windows/System32/cmd.exe", "/c", "start", "", "msedge",
      "--app=" .. url, "--window-size=" .. g.window_size }
  elseif vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  else
    cmd = { "xdg-open", url }
  end
  pcall(vim.system, cmd, { cwd = (vim.fn.has("wsl") == 1 or vim.env.WSL_DISTRO_NAME) and "/mnt/c" or nil, detach = true })
end

local function act(msg)
  local T = require("latex-tutor")
  local buf = M.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then return end
  local st = store.get(buf)
  local c = msg.id and st.comments[msg.id]
  local a = msg.action
  if a == "jump" and c then T.jump(buf, c, true)
  elseif a == "activate" and c then T.activate(buf, c)
  elseif a == "resolve" and c then T.toggle_resolve(buf, c)
  elseif a == "reply" and c and type(msg.text) == "string" and msg.text ~= "" then T.reply(buf, c, msg.text)
  elseif a == "check" then T.check(buf)
  elseif a == "review" then
    local row = st.focus and st.focus.s or api.nvim_win_get_cursor(0)[1]
    T.review(buf, scope.unit_at(buf, row))
  elseif a == "show_all" then
    st.show_all = not st.show_all
    T.refresh(buf)
  elseif a == "jump_line" and tonumber(msg.line) then T.jump_line(buf, tonumber(msg.line))
  elseif a == "progress" then M.show_progress()
  elseif a == "math_insert" then require("latex-tutor.math").insert()
  end
end

local function on_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  if msg.type == "ready" then
    M.port = msg.port
    M.url = "http://127.0.0.1:" .. msg.port .. "/"
    M.push_soon(M.buf)
    M.compile(M.buf)
    open_window(M.url)
    notify("Tutor window opening at " .. M.url)
  elseif msg.type == "action" then
    act(msg)
  end
end

function M.open(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  M.buf = buf
  if M.running() then
    M.push_soon(buf)
    M.compile(buf)
    open_window(M.url)
    return
  end
  if M.job then return end -- starting
  local g = config.get().gui
  if vim.fn.executable(g.python) == 0 then
    return notify("`" .. g.python .. "` not found; the GUI needs Python 3", vim.log.levels.ERROR)
  end
  local pending = ""
  local ok, job = pcall(vim.system, { g.python, root .. "/gui/server.py", "--port", tostring(g.port), "--engine", g.engine }, {
    stdin = true,
    stdout = function(_, data)
      if not data then return end
      pending = pending .. data
      local lines = {}
      while true do
        local i = pending:find("\n", 1, true)
        if not i then break end
        lines[#lines + 1] = pending:sub(1, i - 1)
        pending = pending:sub(i + 1)
      end
      if #lines > 0 then vim.schedule(function() for _, l in ipairs(lines) do on_line(l) end end) end
    end,
    stderr = function() end,
  }, function(res)
    vim.schedule(function()
      M.job, M.port = nil, nil
      if res.code ~= 0 and res.signal == 0 then notify("Tutor GUI server exited (" .. res.code .. ")", vim.log.levels.WARN) end
    end)
  end)
  if not ok then return notify("Could not start the GUI server: " .. tostring(job), vim.log.levels.ERROR) end
  M.job = job
end

function M.stop()
  if M.job then
    send({ type = "quit" })
    -- Give the server a moment to tell the window to close (:q, :wq).
    pcall(function() M.job:wait(800) end)
    pcall(function() M.job:kill(15) end)
  end
  M.job, M.port = nil, nil
end

ui.on_tasks = function() M.push_soon(M.buf) end

return M
