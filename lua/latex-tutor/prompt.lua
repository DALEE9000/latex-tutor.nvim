-- Prompt text, JSON schemas, tutoring-preference lookup, project root.

local api = vim.api
local config = require("latex-tutor.config")
local M = {}

M.review_schema = {
  type = "object",
  properties = {
    verdict = { type = "string", enum = { "correct", "minor_issues", "major_issues", "incomplete" } },
    summary = { type = "string", description = "2-5 sentences of overall feedback on this attempt." },
    comments = {
      type = "array",
      items = {
        type = "object",
        properties = {
          line = { type = "integer", description = "Line number (as numbered in the prompt) where the issue starts." },
          end_line = { type = "integer", description = "Last line of the issue if it spans several lines." },
          quote = { type = "string", description = "Short fragment copied character-for-character from `line` that pinpoints the issue." },
          severity = { type = "string", enum = config.severity_order },
          title = { type = "string", description = "At most ~60 characters, plain text." },
          body = { type = "string", description = "The explanation. Markdown; inline math as $...$." },
          hint = { type = "string", description = "A nudge toward the fix without giving it away." },
          fix = { type = "string", description = "The corrected version, only if the preferences allow giving it." },
          confidence = { type = "string", enum = { "high", "medium", "low" } },
        },
        required = { "line", "quote", "severity", "title", "body", "confidence" },
      },
    },
  },
  required = { "verdict", "summary", "comments" },
}

M.reply_schema = {
  type = "object",
  properties = {
    reply = { type = "string", description = "Your reply to the student. Markdown." },
    resolved = { type = "boolean", description = "True only if the issue is now fixed or the comment was mistaken." },
  },
  required = { "reply", "resolved" },
}

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Nearest TUTOR.md walking up from the file, else the global one.
function M.find_prefs(file)
  local cfg = config.get()
  local found = vim.fs.find(cfg.prefs_filename, {
    upward = true,
    path = vim.fs.dirname(file),
    stop = vim.fs.dirname(vim.uv.os_homedir()),
    type = "file",
  })[1]
  local path = found or vim.fn.expand(cfg.global_prefs)
  return path, read(path)
end

-- Directory Claude runs in: the manual root (holds header*.tex), a git root,
-- or the file's own directory.
function M.project_root(file)
  local d = vim.fs.dirname(file)
  local hit = vim.fs.find(function(name) return name:match("^header.*%.tex$") ~= nil end,
    { upward = true, path = d, stop = vim.uv.os_homedir(), type = "file" })[1]
  if hit then return vim.fs.dirname(hit) end
  local git = vim.fs.find(".git", { upward = true, path = d, stop = vim.uv.os_homedir() })[1]
  return git and vim.fs.dirname(git) or d
end

function M.numbered(buf, s, e)
  local lines = api.nvim_buf_get_lines(buf, s - 1, e, false)
  local w = #tostring(e)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = string.format("%" .. w .. "d│ %s", s + i - 1, l)
  end
  return table.concat(out, "\n")
end

function M.system(prefs)
  local cfg = config.get()
  return table.concat({
    "You are a demanding, honest tutor reviewing a self-taught student's LaTeX solution to a math or physics textbook exercise.",
    "This is a read-only review: never edit, create or delete files. You may Read/Grep the project to look up macro definitions or an exercise the student cites.",
    "",
    "How to review:",
    "- Redo every calculation and every step yourself before judging it. Check limiting cases and substitute answers back where possible.",
    "- Comment only where something is wrong, unjustified, or meaningfully improvable. Do not pad. A fully correct solution can get zero comments (plus one 'praise' at most).",
    "- Severity: error = mathematically/physically wrong (wrong value, sign, factor, false claim, wrong event modelled); rigor = gap, unjustified step, misapplied or unnamed theorem, proof by example, circular argument; improve = correct but clearer/better route or a missing self-check; latex = typesetting or notation only; praise = something genuinely well done.",
    "- Anchor each comment at the line number shown before the │ where the problem starts. `quote` must be copied exactly from that line (without the number prefix): the shortest fragment that identifies the spot.",
    "- Say how confident you are. If you're unsure whether something is wrong, say so instead of asserting it.",
    string.format("- At most %d comments, most important first.", cfg.max_comments),
    "",
    "The student's tutoring preferences follow. They override the defaults above on tone, hints vs. answers, and focus.",
    "",
    "<tutoring_preferences>",
    prefs or "(none given)",
    "</tutoring_preferences>",
  }, "\n")
end

function M.review(buf, unit, root)
  local file = api.nvim_buf_get_name(buf)
  local rel = vim.fs.relpath and vim.fs.relpath(root, file) or file
  return table.concat({
    string.format("File: %s (project root: %s)", rel or file, root),
    string.format("Review %s, lines %d–%d. The problem statement is usually included (\\qs{number}{statement}); the solution follows it.", unit.label, unit.s, unit.e),
    "",
    M.numbered(buf, unit.s, unit.e),
  }, "\n")
end

function M.reply(buf, c, text, ctx_s, ctx_e)
  local lines = {
    string.format("The student replied to your review comment #%d (%s, line %d): \"%s\"", c.n,
      config.sev(c.severity).label, c.row + 1, c.title),
    "Your original comment:",
    c.body,
  }
  if #c.thread > 1 then
    lines[#lines + 1] = "\nEarlier in this thread:"
    for i = 1, #c.thread - 1 do
      local t = c.thread[i]
      lines[#lines + 1] = (t.role == "you" and "Student: " or "Tutor: ") .. t.text
    end
  end
  vim.list_extend(lines, {
    "",
    string.format("Current text of lines %d–%d (the student may have edited it since your comment):", ctx_s, ctx_e),
    M.numbered(buf, ctx_s, ctx_e),
    "",
    "Student's reply:",
    text,
    "",
    "Answer as their tutor, concisely, following the tutoring preferences. Set resolved=true only if the current text now fixes the issue or the student showed your comment was mistaken (admit it plainly if so).",
  })
  return table.concat(lines, "\n")
end

return M
