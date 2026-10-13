-- Chat: talk with the tutor about the exercise you're working on. Each
-- exercise has its own conversation. Every message carries the exercise as
-- it reads now (your unsaved edits too), so you can ask "is line 12 right?",
-- "why does the hint say Fubini?" or "what should I try next?". Your
-- tutoring preferences (TUTOR.md) apply, as in reviews.
--
-- With Claude the conversation is one resumed session; on Codex, or if the
-- session is gone, the earlier messages are sent along instead. Chats are
-- saved per file in stdpath("data")/latex-tutor/chats/.

local api = vim.api
local config = require("latex-tutor.config")
local claude = require("latex-tutor.claude")
local prompt = require("latex-tutor.prompt")
local scope = require("latex-tutor.scope")
local store = require("latex-tutor.store")
local ui = require("latex-tutor.ui")
local M = { threads = {}, loaded = {}, shown = nil, window_open = false }

M.dir = vim.fn.stdpath("data") .. "/latex-tutor/chats"
local KEEP = 60        -- messages kept per exercise
local HISTORY = 16     -- earlier messages sent along when there's no session

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "reply" },
  properties = {
    reply = { type = "string", description = "Your reply. Markdown, inline math as $...$, display math as $$...$$." },
  },
}

local function system(prefs)
  return table.concat({
    "You are the student's tutor, chatting with them inside their LaTeX editor about the textbook exercise they are working on (a self-taught student writing a solutions manual).",
    "This is read-only: never edit, create or delete files. You may Read/Grep the project to look up their header macros or an exercise they mention.",
    "",
    "How to answer:",
    "- Talk like a good tutor in office hours: direct, concise, conversational. A few short paragraphs at most unless they ask for more.",
    "- Each message includes the exercise as it reads now, with line numbers before the │. Refer to their lines by number.",
    "- When they ask whether something is right, redo the computation yourself first; check limiting cases or substitute back.",
    "- Say plainly when you're unsure. If they push back and they're right, admit it.",
    "- Math in $...$ or $$...$$, in their notation.",
    "",
    "The student's tutoring preferences follow. They decide tone and how much to give away (hints vs. answers).",
    "",
    "<tutoring_preferences>",
    prefs or "(none given)",
    "</tutoring_preferences>",
  }, "\n")
end

-- Saved chats --------------------------------------------------------------

local function chat_file(file)
  return M.dir .. "/" .. vim.fn.sha256(file):sub(1, 16) .. ".json"
end

local function load(file)
  if M.loaded[file] then return end
  M.loaded[file] = true
  local f = io.open(chat_file(file), "r")
  if not f then return end
  local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
  f:close()
  if ok and type(data) == "table" and type(data.threads) == "table" then
    for label, t in pairs(data.threads) do
      M.threads[file .. "\0" .. label] = vim.tbl_extend("keep", t, { file = file, label = label, msgs = {} })
    end
  end
end

local function save(file)
  local out = {}
  for _, t in pairs(M.threads) do
    if t.file == file and #t.msgs > 0 then
      out[t.label] = { label = t.label, msgs = t.msgs, session = t.session }
    end
  end
  vim.fn.mkdir(M.dir, "p")
  local f = io.open(chat_file(file), "w")
  if f then f:write(vim.json.encode({ file = file, threads = out })); f:close() end
end

-- The exercise a chat is about -----------------------------------------------

-- The question under the cursor (or the one the window shows).
local function current_unit(buf)
  if api.nvim_get_current_buf() == buf then return scope.unit_at(buf, api.nvim_win_get_cursor(0)[1]) end
  local f = store.get(buf).focus
  if f and f.label then return { s = f.s, e = f.e, label = f.label } end
  return scope.unit_at(buf, 1)
end

-- Where `label` is now (lines move as you edit).
local function find_unit(buf, label)
  for _, u in ipairs(scope.units(buf)) do
    if u.label == label then return u end
  end
end

local function thread_for(buf, unit)
  local file = api.nvim_buf_get_name(buf)
  load(file)
  local key = file .. "\0" .. unit.label
  M.threads[key] = M.threads[key] or { file = file, label = unit.label, msgs = {} }
  local t = M.threads[key]
  t.key, t.buf = key, buf
  return t
end

-- Prompt for one message ------------------------------------------------------

local function open_comments(buf, unit)
  local out = {}
  for _, c in ipairs(store.list(buf)) do
    if not c.resolved and c.row + 1 >= unit.s and c.row + 1 <= unit.e then
      out[#out + 1] = string.format("#%d [%s] line %d: %s", c.n, config.sev(c.severity).label, c.row + 1, c.title)
    end
  end
  return out
end

local function build_prompt(t, unit, text, with_history)
  local buf = t.buf
  local L = {}
  if with_history then
    L[#L + 1] = string.format("We are chatting about %s in %s.", unit.label,
      vim.fn.fnamemodify(t.file, ":~"))
    local first = math.max(1, #t.msgs - HISTORY)
    if #t.msgs > 0 then
      L[#L + 1] = ""
      L[#L + 1] = "Earlier in this chat:"
      for i = first, #t.msgs do
        local m = t.msgs[i]
        L[#L + 1] = (m.role == "you" and "Student: " or "Tutor: ") .. m.text:sub(1, 3000)
      end
    end
  end
  local numbered = prompt.numbered(buf, unit.s, unit.e)
  L[#L + 1] = ""
  if not with_history and t.sent == numbered then
    L[#L + 1] = string.format("(%s is unchanged since the last message.)", unit.label)
  else
    L[#L + 1] = string.format("%s as it reads now (lines %d–%d%s):", unit.label, unit.s, unit.e,
      with_history and "" or "; they may have edited it since")
    L[#L + 1] = "```latex"
    L[#L + 1] = numbered
    L[#L + 1] = "```"
  end
  local comments = open_comments(buf, unit)
  if #comments > 0 then
    L[#L + 1] = ""
    L[#L + 1] = "Open review comments on it:"
    vim.list_extend(L, comments)
  end
  if api.nvim_get_current_buf() == buf then
    local row = api.nvim_win_get_cursor(0)[1]
    if row >= unit.s and row <= unit.e then L[#L + 1] = "\nTheir cursor is on line " .. row .. "." end
  end
  L[#L + 1] = ""
  L[#L + 1] = "Student: " .. text
  return table.concat(L, "\n"), numbered
end

-- Showing it -------------------------------------------------------------------

local function view(t)
  local title = t.buf and api.nvim_buf_is_valid(t.buf) and scope.title(t.buf, (find_unit(t.buf, t.label) or {}).s or 1, t.label)
  return {
    key = t.key, label = t.label, title = title or t.label,
    msgs = t.msgs, status = t.working and "working" or "idle", error = t.error,
  }
end

local render_split -- defined below

-- Send this chat to the window and the nvim split (whichever are open).
local function show(t, open, restore)
  M.shown = t.key
  local gui = require("latex-tutor.gui")
  local ok = gui.running() and gui.chat(vim.tbl_extend("force", view(t), { open = open or nil, restore = restore }))
  if ok and open then M.window_open = true end
  render_split(t)
  return ok
end

-- The window follows the question you move to while the chat is open.
function M.follow(buf)
  if not M.window_open then return end
  local u = current_unit(buf)
  if not u then return end
  local t = thread_for(buf, u)
  if t.key ~= M.shown then show(t) end
end

-- Asking ------------------------------------------------------------------------

function M.send(buf, text, key)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  text = vim.trim(text or "")
  if text == "" then return end
  local t = key and M.threads[key]
  if not t then t = thread_for(buf, current_unit(buf)) end
  t.buf = buf
  local unit = find_unit(buf, t.label) or current_unit(buf)
  if t.working then return notify("The tutor is still answering", vim.log.levels.WARN) end

  local cfg = config.get()
  local ch = cfg.chat or {}
  local on_claude = cfg.backend ~= "codex"
  local resume = on_claude and t.session or nil
  local body, numbered = build_prompt(t, unit, text, not resume)
  -- in case the saved session is gone: the same message with the history
  local fresh = resume and build_prompt(t, unit, text, true) or nil
  local _, prefs = prompt.find_prefs(t.file)

  t.msgs[#t.msgs + 1] = { role = "you", text = text, at = os.time() }
  t.working, t.error = true, nil
  show(t)
  local job = "chat:" .. t.key
  ui.task_start(job, "💬 the tutor is answering")

  local function go(p, session)
    claude.run({
      key = job, prompt = p, system = system(prefs), schema = M.schema,
      cwd = prompt.project_root(t.file), resume = session,
      model = on_claude and ch.model or nil, effort = on_claude and ch.effort or nil,
    }, function(err, out, sid)
      if err and session and (err:lower():find("session") or err:lower():find("conversation")) then
        -- the saved session is gone (cleared, other machine): start a new one
        -- with the earlier messages included
        t.session = nil
        return go(fresh, nil)
      end
      ui.task_stop(job)
      t.working = false
      if err then
        t.error = err == "cancelled" and "Cancelled." or err
        if err == "cancelled" then table.remove(t.msgs) end -- drop the unanswered message
      else
        t.msgs[#t.msgs + 1] = { role = "tutor", text = out.reply or "", at = os.time() }
        t.sent = numbered
        if on_claude and sid then t.session = sid end
        while #t.msgs > KEEP do table.remove(t.msgs, 1) end
        save(t.file)
      end
      show(t)
      if err and err ~= "cancelled" then notify(err, vim.log.levels.ERROR) end
    end)
  end
  go(body, resume)
end

function M.cancel(key)
  local t = M.threads[key or M.shown or ""]
  if not (t and t.working) then return end
  claude.cancel("chat:" .. t.key) -- its callback is dropped, so tidy up here
  ui.task_stop("chat:" .. t.key)
  t.working = false
  local m = t.msgs[#t.msgs]
  if m and m.role == "you" then table.remove(t.msgs) end
  show(t, nil, m and m.role == "you" and m.text or nil) -- back in the box, to edit and resend
end

-- Forget an exercise's chat (and its session).
function M.clear(key)
  local t = M.threads[key or M.shown or ""]
  if not t then return end
  M.cancel(t.key)
  t.msgs, t.session, t.sent, t.error, t.working = {}, nil, nil, nil, false
  save(t.file)
  show(t)
end

-- The nvim split ---------------------------------------------------------------

local split = { buf = nil, win = nil }

render_split = function(t)
  if not (split.buf and api.nvim_buf_is_valid(split.buf)) then return end
  if split.key and split.key ~= t.key then return end
  split.key = t.key
  local L = { "# 💬 " .. scope.plain(t.label), "" }
  if #t.msgs == 0 then
    L[#L + 1] = "_Ask anything about this exercise. The tutor sees it as it reads now._"
    L[#L + 1] = ""
  end
  for _, m in ipairs(t.msgs) do
    L[#L + 1] = m.role == "you" and "**You**" or "**Tutor**"
    vim.list_extend(L, vim.split(m.text, "\n", { plain = true }))
    L[#L + 1] = ""
  end
  if t.working then L[#L + 1] = "_… the tutor is answering (x cancels)_" end
  if t.error then L[#L + 1] = "> " .. t.error end
  L[#L + 1] = ""
  L[#L + 1] = "<!-- i / <CR> ask   n new chat   x cancel   q close -->"
  vim.bo[split.buf].modifiable = true
  api.nvim_buf_set_lines(split.buf, 0, -1, false, L)
  vim.bo[split.buf].modifiable = false
  if split.win and api.nvim_win_is_valid(split.win) then
    pcall(api.nvim_win_set_cursor, split.win, { #L, 0 })
  end
end

local function open_split(src, t)
  if not (split.buf and api.nvim_buf_is_valid(split.buf)) then
    split.buf = api.nvim_create_buf(false, true)
    vim.bo[split.buf].filetype = "markdown"
    vim.bo[split.buf].bufhidden = "hide"
    pcall(api.nvim_buf_set_name, split.buf, "latex-tutor://chat")
    local o = { buffer = split.buf, nowait = true, silent = true }
    local function ask()
      vim.ui.input({ prompt = "💬 " }, function(s)
        if s and vim.trim(s) ~= "" then M.send(src, s, split.key) end
      end)
    end
    vim.keymap.set("n", "i", ask, o)
    vim.keymap.set("n", "a", ask, o)
    vim.keymap.set("n", "<CR>", ask, o)
    vim.keymap.set("n", "n", function() M.clear(split.key) end, o)
    vim.keymap.set("n", "x", function() M.cancel(split.key) end, o)
    vim.keymap.set("n", "q", function() if split.win and api.nvim_win_is_valid(split.win) then api.nvim_win_close(split.win, true) end end, o)
  end
  if not (split.win and api.nvim_win_is_valid(split.win)) then
    local cur = api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    split.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(split.win, split.buf)
    api.nvim_win_set_width(split.win, math.min(72, math.max(44, math.floor(vim.o.columns * 0.38))))
    vim.wo[split.win].wrap = true
    vim.wo[split.win].linebreak = true
    vim.wo[split.win].number = false
    vim.wo[split.win].conceallevel = 2
    api.nvim_set_current_win(cur)
  end
  split.key = t.key
  render_split(t)
end

-- Space c i / :Tutor chat [message]
function M.open(buf, text)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local t = thread_for(buf, current_unit(buf))
  if text and vim.trim(text) ~= "" then
    if not show(t, true) then open_split(buf, t) end
    return M.send(buf, text, t.key)
  end
  if show(t, true) then return end -- in the window
  open_split(buf, t)
  vim.ui.input({ prompt = "💬 Ask about " .. scope.plain(t.label) .. ": " }, function(s)
    if s and vim.trim(s) ~= "" then M.send(buf, s, t.key) end
  end)
end

-- Clicks in the window (gui.lua).
function M.action(buf, msg)
  local a = msg.action
  if a == "chat_open" then
    M.window_open = true
    local t = (msg.key and M.threads[msg.key]) or thread_for(buf, current_unit(buf))
    show(t)
  elseif a == "chat_close" then M.window_open = false
  elseif a == "chat_send" then M.send(buf, msg.text, msg.key)
  elseif a == "chat_cancel" then M.cancel(msg.key)
  elseif a == "chat_new" then M.clear(msg.key)
  end
end

return M
