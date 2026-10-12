-- Which AI answers: the backend (Claude Code or OpenAI Codex CLI) and the
-- model, for reviews and for Σ. `:Tutor model` (Space c M) picks the review
-- model, `:Tutor model math` the Σ one. The choice is saved, so it survives
-- restarts, and it overrides setup() until you pick again.

local config = require("latex-tutor.config")
local M = {}

local file = vim.fn.stdpath("state") .. "/latex-tutor/settings.json"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

local function load()
  local f = io.open(file, "r")
  if not f then return {} end
  local ok, s = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
  f:close()
  return ok and type(s) == "table" and s or {}
end

local function save(s)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local f = io.open(file, "w")
  if f then f:write(vim.json.encode(s)); f:close() end
end

-- Apply the saved choice over the setup() options (called from setup).
function M.apply()
  local o, s = config.get(), load()
  o.codex = o.codex or {}
  o.math = o.math or {}
  if s.backend then o.backend = s.backend end
  if s.claude_model then o.model = s.claude_model end
  if s.claude_math_model then o.math.model = s.claude_math_model end
  if s.codex_model ~= nil then o.codex.model = s.codex_model ~= "" and s.codex_model or nil end
  if s.codex_math_model ~= nil then o.codex.math_model = s.codex_math_model ~= "" and s.codex_math_model or nil end
end

function M.backend() return config.get().backend or "claude" end

-- The model for Σ on the current backend (nil = the CLI's default).
function M.math_model()
  local o = config.get()
  if M.backend() == "codex" then return (o.codex or {}).math_model or (o.codex or {}).model end
  return (o.math or {}).model or o.model
end

local NAMES = { opus = "Opus", sonnet = "Sonnet", haiku = "Haiku", fable = "Fable" }
local function pretty(m)
  if not m then return "default" end
  return NAMES[m] or m
end

-- "Claude Opus" / "Codex gpt-5"; shown in the Tutor window and messages.
function M.label()
  local o = config.get()
  if M.backend() == "codex" then return "Codex " .. pretty((o.codex or {}).model) end
  return "Claude " .. pretty(o.model)
end

local function choices(task)
  local codex_ok = vim.fn.executable(((config.get().codex or {}).cmd) or "codex") == 1
  local note = codex_ok and "" or "  (not installed: npm i -g @openai/codex, then codex login)"
  local c = {
    { backend = "claude", model = "opus", text = "Claude · Opus — most careful" .. (task == "review" and " (default)" or "") },
    { backend = "claude", model = "sonnet", text = "Claude · Sonnet — faster" .. (task == "math" and " (default)" or "") },
    { backend = "claude", model = "haiku", text = "Claude · Haiku — fastest, lightest" },
    { backend = "claude", ask = true, text = "Claude · another model id…" },
    { backend = "codex", model = "", text = "Codex · its default model" .. note },
    { backend = "codex", ask = true, text = "Codex · another model…" .. note },
  }
  return c
end

-- task: "review" (default) or "math"
function M.pick(task)
  task = task == "math" and "math" or "review"
  local list = choices(task)
  vim.ui.select(list, {
    prompt = (task == "math" and "Σ model" or "Review model") .. " (now: " .. M.label() .. ")",
    format_item = function(c) return c.text end,
  }, function(c)
    if not c then return end
    local function set(model)
      if model == nil then return end
      local s = load()
      local switched = c.backend ~= M.backend()
      s.backend = c.backend
      local key = c.backend .. (task == "math" and "_math_model" or "_model")
      s[key] = model
      save(s)
      M.apply()
      local label = c.backend == "codex" and ("Codex " .. pretty(model ~= "" and model or nil))
        or ("Claude " .. pretty(model))
      notify((task == "math" and "Σ now uses " or "Reviews now use ") .. label
        .. (switched and (" (reviews and Σ both run on " .. (c.backend == "codex" and "Codex" or "Claude") .. " now)") or ""))
      pcall(function() require("latex-tutor.gui").push_soon() end)
    end
    if c.ask then
      vim.ui.input({ prompt = (c.backend == "codex" and "Codex" or "Claude") .. " model name: " }, function(m)
        if m and vim.trim(m) ~= "" then set(vim.trim(m)) end
      end)
    else
      set(c.model)
    end
  end)
end

return M
