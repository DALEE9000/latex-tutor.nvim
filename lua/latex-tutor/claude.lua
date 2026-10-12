-- Runs the Claude Code CLI headlessly (`claude -p`). Authentication is your
-- claude.ai login, so usage counts against your subscription. API-key env
-- vars are removed for the child process so it can never fall back to
-- metered API billing. (Don't add --bare: it forces API-key auth.)

local config = require("latex-tutor.config")
local M = {}

M.jobs = {} -- key -> vim.SystemObj

function M.running(key)
  return M.jobs[key] ~= nil
end

function M.cancel(key)
  local j = M.jobs[key]
  if j then
    j:kill(15)
    M.jobs[key] = nil
    return true
  end
  return false
end

-- opts: key, prompt (sent on stdin), system, schema, cwd, resume (session id),
--       model / effort (override the config for this call)
-- on_done(err, structured, session_id)
function M.run(opts, on_done)
  local cfg = config.get()
  if cfg.backend == "codex" then
    return require("latex-tutor.codex").run(opts, on_done, M.jobs)
  end
  if vim.fn.executable(cfg.claude_cmd) == 0 then
    on_done("`" .. cfg.claude_cmd .. "` not found on PATH")
    return
  end
  local cmd = {
    "env", "-u", "ANTHROPIC_API_KEY", "-u", "ANTHROPIC_AUTH_TOKEN",
    cfg.claude_cmd, "-p",
    "--output-format", "json",
    "--json-schema", vim.json.encode(opts.schema),
    "--tools", table.concat(cfg.tools, ","),
  }
  if #cfg.tools > 0 then
    vim.list_extend(cmd, { "--allowedTools", table.concat(cfg.tools, ",") })
  end
  local model, effort = opts.model or cfg.model, opts.effort or cfg.effort
  if model then vim.list_extend(cmd, { "--model", model }) end
  if effort then vim.list_extend(cmd, { "--effort", effort }) end
  if opts.resume then vim.list_extend(cmd, { "--resume", opts.resume }) end
  if opts.system then vim.list_extend(cmd, { "--append-system-prompt", opts.system }) end

  local job
  local ok, res_or_err = pcall(vim.system, cmd, {
    stdin = opts.prompt,
    cwd = opts.cwd,
    text = true,
    timeout = cfg.timeout_ms,
  }, function(res)
    vim.schedule(function()
      if M.jobs[opts.key] ~= job then return end -- cancelled or superseded
      M.jobs[opts.key] = nil
      if res.signal ~= 0 and res.code ~= 0 then
        on_done(res.signal == 15 and "cancelled" or ("claude exited on signal " .. res.signal))
        return
      end
      local okj, data = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      if not okj or type(data) ~= "table" then
        local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
        on_done("claude failed: " .. (msg ~= "" and msg:sub(1, 400) or ("exit " .. res.code)))
        return
      end
      if data.is_error then
        on_done("claude: " .. tostring(data.result or data.subtype or "error"), nil, data.session_id)
        return
      end
      local out = data.structured_output
      if type(out) ~= "table" and type(data.result) == "string" then
        local okr, parsed = pcall(vim.json.decode, data.result:match("%b{}") or "")
        if okr then out = parsed end
      end
      if type(out) ~= "table" then
        on_done("claude returned no structured output", nil, data.session_id)
        return
      end
      on_done(nil, out, data.session_id)
    end)
  end)
  if not ok then
    on_done("could not start claude: " .. tostring(res_or_err))
    return
  end
  job = res_or_err
  M.jobs[opts.key] = job
end

return M
