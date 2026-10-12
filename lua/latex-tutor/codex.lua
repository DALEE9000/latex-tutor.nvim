-- OpenAI Codex CLI backend (`codex exec`), with the same interface as
-- claude.run. Sign in with `codex login` (ChatGPT account) to use your
-- ChatGPT plan. OPENAI_API_KEY is removed for the child process so a stray
-- key in your environment can't switch it to metered API billing.
--
-- Differences from the Claude backend:
-- * Structured output uses OpenAI's strict JSON-schema mode, which wants every
--   property listed as required; optional ones become nullable (strict()).
-- * There's no system-prompt flag, so the system text leads the prompt.
-- * Sessions aren't resumed. Replies already carry the whole thread in the
--   prompt, so nothing is lost.

local config = require("latex-tutor.config")
local M = {}

-- OpenAI strict mode: every object lists all its properties as required and
-- forbids extra ones. Properties that were optional may be null instead.
function M.strict(schema)
  if type(schema) ~= "table" then return schema end
  local s = vim.deepcopy(schema)
  if s.type == "object" and s.properties then
    local req = {}
    for _, k in ipairs(s.required or {}) do req[k] = true end
    local all = {}
    for k, p in pairs(s.properties) do
      p = M.strict(p)
      if not req[k] then
        p.type = type(p.type) == "table" and p.type or { p.type, "null" }
        if p.enum then
          p.enum = vim.deepcopy(p.enum)
          table.insert(p.enum, vim.NIL)
        end
      end
      s.properties[k] = p
      all[#all + 1] = k
    end
    table.sort(all)
    s.required = all
    s.additionalProperties = false
  elseif s.type == "array" and s.items then
    s.items = M.strict(s.items)
  end
  return s
end

-- jobs: the shared table from claude.lua, so running()/cancel() work for both.
function M.run(opts, on_done, jobs)
  local cfg = config.get()
  local cx = cfg.codex or {}
  local cmd_name = cx.cmd or "codex"
  if vim.fn.executable(cmd_name) == 0 then
    on_done("`" .. cmd_name .. "` not found on PATH (install the Codex CLI, then run `codex login`)")
    return
  end
  local schema_file = vim.fn.tempname() .. ".json"
  local out_file = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ vim.json.encode(M.strict(opts.schema)) }, schema_file)
  local cmd = {
    "env", "-u", "OPENAI_API_KEY",
    cmd_name, "exec",
    "--skip-git-repo-check",
    "--sandbox", "read-only",   -- it may read your project, never write
    "--color", "never",
    "--output-schema", schema_file,
    "--output-last-message", out_file,
  }
  if opts.cwd then vim.list_extend(cmd, { "--cd", opts.cwd }) end
  local model = opts.model or cx.model
  if model then vim.list_extend(cmd, { "--model", model }) end
  local effort = opts.effort or cx.effort
  if effort then vim.list_extend(cmd, { "-c", "model_reasoning_effort=" .. effort }) end
  cmd[#cmd + 1] = "-" -- the prompt comes on stdin

  local stdin = (opts.system and (opts.system .. "\n\n---\n\n") or "") .. (opts.prompt or "")
  local job
  local ok, res_or_err = pcall(vim.system, cmd, {
    stdin = stdin, cwd = opts.cwd, text = true, timeout = cfg.timeout_ms,
  }, function(res)
    vim.schedule(function()
      local function cleanup() pcall(os.remove, schema_file); pcall(os.remove, out_file) end
      if jobs[opts.key] ~= job then cleanup(); return end -- cancelled or superseded
      jobs[opts.key] = nil
      if res.signal ~= 0 and res.code ~= 0 then
        cleanup()
        on_done(res.signal == 15 and "cancelled" or ("codex exited on signal " .. res.signal))
        return
      end
      local f = io.open(out_file, "r")
      local text = f and f:read("*a") or ""
      if f then f:close() end
      cleanup()
      local okj, out = pcall(vim.json.decode, text:match("%b{}") or "", { luanil = { object = true, array = true } })
      if not okj or type(out) ~= "table" then
        local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
        on_done("codex failed: " .. (msg ~= "" and msg:sub(-400) or ("exit " .. res.code)))
        return
      end
      on_done(nil, out, nil)
    end)
  end)
  if not ok then
    on_done("could not start codex: " .. tostring(res_or_err))
    return
  end
  job = res_or_err
  jobs[opts.key] = job
end

return M
