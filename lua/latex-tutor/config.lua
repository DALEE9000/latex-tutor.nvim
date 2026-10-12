-- Defaults and user options for latex-tutor.

local M = {}

M.defaults = {
  -- The Claude Code CLI. Runs under your claude.ai subscription login; the
  -- plugin strips ANTHROPIC_API_KEY from its environment so a stray key can
  -- never switch it to metered API billing.
  claude_cmd = "claude",
  model = "opus",          -- any `claude --model` alias or full id
  effort = nil,            -- nil = CLI default; or "low".."max"
  -- Read-only tools Claude may use to look up your header macros or an
  -- earlier exercise you cite ("see exercise 3.8.8"). {} disables tools.
  tools = { "Read", "Grep", "Glob" },
  timeout_ms = 15 * 60 * 1000,

  -- Tutoring preferences: the nearest TUTOR.md walking up from the .tex
  -- file wins; otherwise this global one.
  prefs_filename = "TUTOR.md",
  global_prefs = "~/.config/latex-tutor/TUTOR.md",

  max_comments = 15,
  -- true: re-reviewing a question replaces all of that question's earlier
  -- comments; false: its resolved comments are kept.
  fresh_review = true,
  max_lines = 1500,        -- ask before sending a range longer than this

  -- A "unit" (exercise) starts on any line matching one of these. Runs of
  -- adjacent marker lines (`% QUESTION 3` then `\qs{...}`) count as one start.
  unit_patterns = {
    "^%s*%%+%s*QUESTION",
    "^%s*\\qs%s*{",
    "^%s*\\begin{exercise",
    "^%s*\\begin{problem",
    "^%s*\\begin{question",
  },
  section_patterns = { "^%s*\\chapter", "^%s*\\section", "^%s*\\subsection" },

  keymaps = {
    prefix = "<localleader>c",
    review = "c",          -- exercise under cursor (visual: selection)
    review_file = "f",
    panel = "o",
    next = "n",
    prev = "p",
    card = "k",
    resolve = "r",
    reply = "R",
    delete = "d",
    pdf = "a",
    cancel = "x",
    prefs = "e",
    hide = "q",            -- hide / show everything (comments are kept)
    progress = "s",        -- progress report
    check = "v",           -- ask the tutor whether your edits fix the open comments
    gui = "g",             -- open the Tutor window (PDF + comment cards)
  },

  panel = { width = 54, auto_open = true }, -- auto_open is skipped while the GUI window is open
  gui = {
    python = "python3",
    port = 0,              -- 0 = any free port
    engine = "pdflatex",   -- builds into ~/.cache/latex-tutor/build/, never next to your files
    window_size = "1440,920",
    live = true,           -- rebuild from your unsaved text as you type (false = on save only)
    live_delay = 150,      -- ms after you stop typing
    open_on_review = true, -- Space c c also opens the window (false = terminal sidebar only)
    open_cmd = nil,        -- override: a command list (URL appended) or function(url)
  },
  card = { auto = true, max_width = 84 }, -- auto: pop up when cursor lands on a comment (panel closed)
  virtual_text = "active", -- end-of-line title: "active" (comment under the cursor), "all", or false
  auto_resolve = true,     -- let the tutor close a thread when your reply/fix settles it

  texpresso = {
    annotate = true,       -- numbered badges in the live PDF
    margin_notes = true,   -- plus the comment title in the margin, where LaTeX allows
    sync_on_jump = true,   -- scroll the PDF when jumping to a comment
  },
}

-- Severity → display. rgb is for the LaTeX badge.
M.severities = {
  error   = { label = "Error",   hex = "#ff6e5e", tint = "#3b2224", rgb = "0.80,0.16,0.16" },
  rigor   = { label = "Rigor",   hex = "#ffb454", tint = "#3a3020", rgb = "0.86,0.47,0.04" },
  improve = { label = "Improve", hex = "#5ea1ff", tint = "#1f2b3e", rgb = "0.16,0.40,0.80" },
  latex   = { label = "LaTeX",   hex = "#c58cff", tint = "#2e2240", rgb = "0.52,0.25,0.80" },
  praise  = { label = "Nice",    hex = "#5eff9c", tint = "#1f3a2a", rgb = "0.12,0.55,0.30" },
}
M.severity_order = { "error", "rigor", "improve", "latex", "praise" }

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

function M.get()
  return M.options
end

function M.sev(name)
  return M.severities[name] or M.severities.improve
end

-- "error" -> "LatexTutorError"
function M.group(name)
  name = M.severities[name] and name or "improve"
  return "LatexTutor" .. name:sub(1, 1):upper() .. name:sub(2)
end

return M
