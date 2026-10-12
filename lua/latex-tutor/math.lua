-- Ask the tutor to evaluate / derive: select some LaTeX (a sum, an integral,
-- an expression), optionally say what you want ("integrate by parts",
-- "closed form", "simplify"), and get back the result, the key steps, an
-- independent check, and LaTeX in your document's style that you can insert
-- below the selection. Runs on your subscription like reviews.

local api = vim.api
local config = require("latex-tutor.config")
local claude = require("latex-tutor.claude")
local prompt = require("latex-tutor.prompt")
local ui = require("latex-tutor.ui")
local M = { last = nil }

local ns = api.nvim_create_namespace("latex-tutor-math")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "result", "steps", "latex", "check", "confidence" },
  properties = {
    result = { type = "string", description = "The answer as one LaTeX math expression (no $ delimiters)" },
    steps = {
      type = "array",
      description = "The key steps, in order; 2-8 of them",
      items = {
        type = "object", additionalProperties = false, required = { "math" },
        properties = {
          math = { type = "string", description = "One LaTeX math line (no $ delimiters)" },
          note = { type = "string", description = "Optional short reason, plain text with $..$ math" },
        },
      },
    },
    latex = { type = "string", description = "Ready-to-insert LaTeX lines in the document's own style and macros" },
    check = { type = "string", description = "How the result was verified independently (plain text with $..$ math)" },
    confidence = { type = "string", enum = { "high", "medium", "low" } },
    caveat = { type = "string", description = "Assumptions or conditions (convergence, domain); empty if none" },
  },
}

local SYSTEM = [[
You are a careful computer-algebra assistant inside the user's LaTeX editor.
Evaluate, simplify or derive exactly what they selected (and what they ask
for, if they say).

Rules:
- Be exact. Keep symbolic constants; give a closed form when one exists, and
  say so plainly when it doesn't.
- Verify independently before answering, and say how in `check`: e.g.
  differentiate an antiderivative, substitute back, try n = 1, 2, 3 in a sum,
  check a limiting case, or a numeric spot check.
- State conditions in `caveat` (convergence, |x| < 1, a > 0, branch choices).
- `steps`: only the key steps, each one LaTeX math line.
- `latex`: lines the user can paste right below their selection. Match the
  document: its macros (\E, \var, ...), its environments (align* with &= if
  that's what it uses), its spacing. Continue their derivation; don't repeat
  what they already wrote, and never rewrite their text.
- If the selection is ambiguous or wrong as written, say so in `caveat` and
  answer the most likely intended reading.
]]

-- Selected text (or the current line) and where it ends.
local function grab(buf, visual)
  if visual then
    local vpos, cpos = vim.fn.getpos("v"), vim.fn.getpos(".")
    local mode = vim.fn.mode()
    local ok, lines = pcall(vim.fn.getregion, vpos, cpos, { type = mode })
    local a, b = vpos[2], cpos[2]
    if a > b then a, b = b, a end
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    if not ok then lines = api.nvim_buf_get_lines(buf, a - 1, b, false) end
    return table.concat(lines, "\n"), a, b
  end
  local r = api.nvim_win_get_cursor(0)[1]
  return api.nvim_buf_get_lines(buf, r - 1, r, false)[1] or "", r, r
end

local function build_prompt(buf, text, s, e, ask)
  local n = api.nvim_buf_line_count(buf)
  local ctx = api.nvim_buf_get_lines(buf, math.max(0, s - 16), math.min(n, e + 6), false)
  return table.concat({
    "File: " .. vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":~"),
    "",
    "Selected (lines " .. s .. "-" .. e .. "):",
    "```latex", text, "```",
    "",
    "Request: " .. ((ask and ask ~= "") and ask or "evaluate / simplify this (closed form if possible)"),
    "",
    "Surrounding text, for notation only:",
    "```latex", table.concat(ctx, "\n"), "```",
    "",
    "The project's header*.tex files define its macros; read them if a macro is unclear.",
  }, "\n")
end

-- Insert the proposed LaTeX below the selection (one undo step).
function M.insert(r)
  r = r or M.last
  if not (r and api.nvim_buf_is_valid(r.buf)) then return end
  local pos = api.nvim_buf_get_extmark_by_id(r.buf, ns, r.mark, {})
  local row = pos[1] and (pos[1] + 1) or r.e
  -- drop blank lines around it, but keep the first line's indentation
  local txt = (r.out.latex or ""):gsub("^%s*\n", ""):gsub("%s+$", "")
  local lines = vim.split(txt, "\n", { plain = true })
  if #lines == 0 or lines[1] == "" then return notify("Nothing to insert") end
  api.nvim_buf_set_lines(r.buf, row, row, false, lines)
  notify(string.format("Inserted %d line%s below line %d (u undoes it)", #lines, #lines == 1 and "" or "s", row))
end

function M.yank(r)
  r = r or M.last
  if not r then return end
  vim.fn.setreg('"', r.out.latex or "")
  pcall(vim.fn.setreg, "+", r.out.latex or "")
  notify("LaTeX copied")
end

-- A float in nvim (works with or without the Tutor window).
local function show_float(r)
  local o = r.out
  local L = { "  = " .. (o.result or ""), "" }
  for i, s in ipairs(o.steps or {}) do
    L[#L + 1] = string.format("  %d. %s", i, s.math or "")
    if s.note and s.note ~= "" then L[#L + 1] = "     " .. s.note end
  end
  L[#L + 1] = ""
  L[#L + 1] = "  ✓ " .. (o.check or "") .. "  (" .. (o.confidence or "?") .. " confidence)"
  if o.caveat and o.caveat ~= "" then L[#L + 1] = "  ! " .. o.caveat end
  L[#L + 1] = ""
  L[#L + 1] = "  ── LaTeX to insert ──"
  for _, l in ipairs(vim.split(o.latex or "", "\n", { plain = true })) do L[#L + 1] = "  " .. l end
  L[#L + 1] = ""
  L[#L + 1] = "  i / <CR> insert below   y copy   q close"
  local fb = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(fb, 0, -1, false, L)
  vim.bo[fb].filetype = "tex"
  vim.bo[fb].modifiable = false
  local width = math.min(100, math.max(50, vim.o.columns - 10))
  local win = api.nvim_open_win(fb, true, {
    relative = "cursor", row = 1, col = 0, width = width,
    height = math.min(#L, math.max(8, vim.o.lines - 8)), style = "minimal", border = "rounded",
    title = " Σ " .. (r.ask ~= "" and r.ask or "evaluate") .. " ", title_pos = "left",
  })
  vim.wo[win].wrap = true
  local function close() if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end end
  local o2 = { buffer = fb, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, o2)
  vim.keymap.set("n", "<Esc>", close, o2)
  vim.keymap.set("n", "i", function() close(); M.insert(r) end, o2)
  vim.keymap.set("n", "<CR>", function() close(); M.insert(r) end, o2)
  vim.keymap.set("n", "y", function() M.yank(r) end, o2)
end

function M.ask(buf, visual, ask_text)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local text, s, e = grab(buf, visual)
  if vim.trim(text) == "" then return notify("Select some LaTeX first", vim.log.levels.WARN) end
  local function go(ask)
    if ask == nil then return end -- <Esc> in the prompt
    local key = "math:" .. buf
    if claude.running(key) then return notify("Still working on the last one", vim.log.levels.WARN) end
    local mark = api.nvim_buf_set_extmark(buf, ns, e - 1, 0, {})
    local cfg = config.get().math or {}
    ui.task_start(key, "Σ " .. (ask ~= "" and ask or "evaluating"))
    claude.run({
      key = key,
      prompt = build_prompt(buf, text, s, e, ask),
      system = SYSTEM,
      schema = M.schema,
      cwd = prompt.project_root(api.nvim_buf_get_name(buf)),
      model = require("latex-tutor.models").math_model(),
      effort = config.get().backend ~= "codex" and cfg.effort or nil,
    }, function(err, out)
      ui.task_stop(key)
      if err then return notify(err, vim.log.levels.ERROR) end
      local r = { buf = buf, mark = mark, s = s, e = e, ask = ask, text = text, out = out }
      M.last = r
      local gui = require("latex-tutor.gui")
      if gui.running() and gui.show_math(r) then
        notify("Σ " .. (out.result or "") .. "  ·  answer in the Tutor window")
      else
        show_float(r)
      end
    end)
  end
  if ask_text ~= nil then return go(ask_text) end
  vim.ui.input({ prompt = "Σ What should I do? (Enter = evaluate / simplify): " }, go)
end

return M
