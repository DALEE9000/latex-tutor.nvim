-- Draw: TikZ from a description, or from a photo / scan of a hand-drawn
-- sketch. The tutor writes the TikZ in your document's style; it is then
-- compiled with your own preamble (gui/draw.py). A compile error goes back to
-- the tutor to fix (up to draw.max_fixes times). With a sketch, the render is
-- compared with the sketch once and corrected (draw.self_check). You can
-- refine it in words ("make the arrows dashed") and insert it at the line you
-- were on. Nothing is written to your files until you insert.

local api = vim.api
local config = require("latex-tutor.config")
local claude = require("latex-tutor.claude")
local prompt = require("latex-tutor.prompt")
local ui = require("latex-tutor.ui")
local M = { cur = nil }

local ns = api.nvim_create_namespace("latex-tutor-draw")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
M.dir = (vim.env.XDG_CACHE_HOME or (vim.uv.os_homedir() .. "/.cache")) .. "/latex-tutor/draw"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "latex-tutor" })
end

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "tikz", "libraries", "summary" },
  properties = {
    tikz = { type = "string", description = "The complete LaTeX to insert: a tikzpicture, wrapped the way this document places its figures (e.g. in a center environment)" },
    libraries = { type = "array", items = { type = "string" }, description = "TikZ libraries the drawing uses, e.g. arrows.meta, calc, positioning" },
    summary = { type = "string", description = "One line: what the drawing shows" },
    notes = { type = "string", description = "Parts of the sketch or description that were ambiguous and what you chose; empty if none" },
    matches = { type = "boolean", description = "Self-check only: true if the render already matches the sketch and the tikz is unchanged" },
  },
}

local SYSTEM = [[
You draw diagrams in TikZ for the user's LaTeX document: from their
description, or from a photo or scan of their hand-drawn sketch.

Faithfulness:
- A sketch is the specification. Keep its topology, relative positions and
  proportions, labels, arrow directions, line styles (solid, dashed, dotted)
  and any shading. Clean up the hand-drawing: wobbly lines become straight
  lines, circles and smooth curves, and near-alignments become exact.
- Don't add elements that aren't in the sketch or the description (no extra
  axes, labels or decoration). If a part is ambiguous, pick the most likely
  reading and say so in `notes`.
- Read handwritten labels as LaTeX math in the document's notation and
  macros. A label you can't read becomes a "?" node, mentioned in `notes`.

Code:
- Match the document: its TikZ libraries and \tikzset styles, its colours,
  its macros, and how it places figures (look at the surrounding text).
- Clean, editable code: named coordinates and nodes, styles in the
  tikzpicture options, a short comment before each main part, a sensible
  scale (roughly 6-12 cm wide).
- List every TikZ library you use in `libraries` (it will be loaded for you).
- The code must compile with pdflatex. No \usepackage lines in `tikz`.
]]

-- The text before \begin{document}: from this buffer, or a minimal one.
local function preamble(buf)
  local out = {}
  for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, math.min(api.nvim_buf_line_count(buf), 800), false)) do
    if l:match("^%s*\\begin{document}") then return table.concat(out, "\n") end
    out[#out + 1] = l
  end
  return "\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n\\usepackage{tikz}"
end

-- TikZ-related lines of the project's headers, so the tutor knows what is
-- already set up (libraries, styles, colours).
local function tikz_setup(proot)
  local out = {}
  for _, h in ipairs(vim.fn.globpath(proot, "header*.tex", false, true)) do
    for _, l in ipairs(vim.fn.readfile(h)) do
      if (l:find("tikz") or l:find("pgf") or l:find("definecolor") or l:find("colorlet")) and #out < 60 then
        out[#out + 1] = l
      end
    end
  end
  return table.concat(out, "\n")
end

local function loaded_libraries(proot, buf)
  local have = {}
  local text = table.concat(vim.split(preamble(buf), "\n"), "\n")
  for _, h in ipairs(vim.fn.globpath(proot, "header*.tex", false, true)) do
    text = text .. "\n" .. table.concat(vim.fn.readfile(h), "\n")
  end
  for list in text:gmatch("\\usetikzlibrary%s*{([^}]*)}") do
    for lib in list:gmatch("[^,%s]+") do have[lib] = true end
  end
  return have
end

-- What the window shows (gui.lua sends it as a "draw" event).
local function push(r, open)
  local gui = require("latex-tutor.gui")
  if not gui.running() then return false end
  local o = r and r.out or {}
  return gui.draw({
    open = open or nil,
    status = r and r.status or "idle",
    step = r and r.step or nil,
    desc = r and r.desc or "",
    image = r and r.image and vim.fs.basename(r.image) or nil,
    preview = r and r.preview and vim.fs.basename(r.preview) or nil,
    tikz = o.tikz, summary = o.summary, notes = o.notes,
    error = r and r.error or nil,
    line = r and r.line or nil,
    missing = r and r.missing or nil,
  })
end

-- Compile the current code with the document's preamble.
local function build(r, cb)
  vim.fn.mkdir(M.dir, "p")
  local job = M.dir .. "/job-" .. r.id .. ".json"
  vim.fn.writefile({ vim.json.encode({
    src = r.file, preamble = r.preamble, tikz = r.out.tikz, libraries = r.out.libraries or {},
    out = M.dir, engine = config.get().gui.engine,
  }) }, job)
  vim.system({ config.get().gui.python, root .. "/gui/draw.py", "build", job }, { text = true }, function(res)
    vim.schedule(function()
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      cb(ok and type(data) == "table" and data or { ok = false, error = vim.trim(res.stderr or "draw.py failed") })
    end)
  end)
end

local function code_block(r)
  return table.concat({ "```latex", r.out.tikz or "", "```", "Libraries: " .. table.concat(r.out.libraries or {}, ", ") }, "\n")
end

local function first_prompt(r)
  local n = api.nvim_buf_line_count(r.buf)
  local ctx = api.nvim_buf_get_lines(r.buf, math.max(0, r.line - 20), math.min(n, r.line + 8), false)
  local L = {
    "File: " .. vim.fn.fnamemodify(r.file, ":~") .. " (the drawing goes below line " .. r.line .. ")",
    "",
    "Request: " .. (r.desc ~= "" and r.desc or "Draw the sketch in the attached image."),
  }
  if r.image then
    L[#L + 1] = ""
    L[#L + 1] = "Sketch: " .. r.image .. " is a photo or scan of the user's hand drawing."
      .. (config.get().backend == "codex" and " It is attached." or " Look at it with the Read tool.")
    if r.desc ~= "" then L[#L + 1] = "Their words above explain or adjust the sketch." end
  end
  vim.list_extend(L, {
    "",
    "TikZ setup the document already loads (from its header):",
    "```latex", r.setup ~= "" and r.setup or "% (only \\usepackage{tikz})", "```",
    "",
    "Surrounding text, for notation and how figures are placed:",
    "```latex", table.concat(ctx, "\n"), "```",
  })
  return table.concat(L, "\n")
end

local function fix_prompt(r, res)
  return table.concat({
    "Your TikZ does not compile with the document's preamble:",
    "",
    "Error: " .. (res.error or "?") .. (res.line and (" (line " .. res.line .. " of your code)") or ""),
    res.context and ("```\n" .. res.context .. "\n```") or "",
    "",
    "The code was:",
    code_block(r),
    "",
    "Return the corrected drawing, unchanged otherwise.",
  }, "\n")
end

local function check_prompt(r)
  return table.concat({
    "Here is your TikZ compiled: " .. r.preview .. ". Compare it with the sketch " .. r.image
      .. (config.get().backend == "codex" and " (both attached)." or " (look at both with the Read tool)."),
    "Fix anything that doesn't match the sketch: missing or extra elements, labels, arrow",
    "directions, line styles, proportions, overlapping text. If it already matches, set",
    "`matches` to true and return the same code.",
    "",
    "The code was:",
    code_block(r),
  }, "\n")
end

local function refine_prompt(r, ask)
  return table.concat({
    "Change the drawing: " .. ask,
    "",
    "The current code:",
    code_block(r),
    "",
    "Keep everything else as it is.",
  }, "\n")
end

local function finish(r, status, err)
  r.status, r.error, r.step = status, err, nil
  ui.task_stop(r.key)
  if status == "done" then
    local have = loaded_libraries(r.proot, r.buf)
    r.missing = vim.tbl_filter(function(l) return not have[l] end, r.out.libraries or {})
    if #r.missing == 0 then r.missing = nil end
  end
  local shown = push(r)
  if status ~= "done" then
    notify(err or "Draw failed", vim.log.levels.ERROR)
  elseif shown then
    notify("✎ " .. (r.out.summary or "Drawing ready") .. "  ·  in the Tutor window")
  else
    M.float(r)
  end
end

-- One tutor call, then build; fixes compile errors and runs the self-check.
local function step(r, text, phase, images)
  local cfg = config.get().draw or {}
  r.status, r.step = "working", phase
  push(r)
  claude.run({
    key = r.key,
    prompt = text,
    system = SYSTEM,
    schema = M.schema,
    cwd = r.proot,
    resume = config.get().backend ~= "codex" and r.session or nil,
    model = cfg.model,
    add_dirs = { M.dir },
    images = images,
  }, function(err, out, sid)
    if err then return finish(r, "error", err) end
    r.session = sid or r.session
    if phase == "Checking it against your sketch" and out.matches and r.out then
      return finish(r, "done")
    end
    if type(out.tikz) ~= "string" or vim.trim(out.tikz) == "" then
      return finish(r, "error", "The tutor returned no TikZ")
    end
    r.out = out
    r.step = "Compiling"
    push(r)
    build(r, function(res)
      if res.ok then
        r.preview, r.error = res.png, nil
        if r.image and not r.checked and cfg.self_check ~= false and res.png then
          r.checked = true
          return step(r, check_prompt(r), "Checking it against your sketch", { r.image, res.png })
        end
        return finish(r, "done")
      end
      r.fixes = (r.fixes or 0) + 1
      if r.fixes <= (cfg.max_fixes or 2) then
        r.error = res.error
        return step(r, fix_prompt(r, res), "Fixing a compile error (" .. r.fixes .. ")", nil)
      end
      finish(r, "error", "Still doesn't compile: " .. (res.error or "?"))
    end)
  end)
end

local function cursor_line(buf)
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and api.nvim_win_get_cursor(win)[1] or api.nvim_buf_line_count(buf)
end

-- opts: desc (words), image (path to a photo / scan)
function M.start(buf, opts)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local desc = vim.trim(opts.desc or "")
  if desc == "" and not opts.image then return notify("Describe the diagram or add a picture of it", vim.log.levels.WARN) end
  local key = "draw:" .. buf
  if claude.running(key) then return notify("Still drawing the last one", vim.log.levels.WARN) end
  if config.get().backend ~= "codex" and opts.image and not vim.tbl_contains(config.get().tools, "Read") then
    return notify("Reading a sketch needs the Read tool (config.tools)", vim.log.levels.ERROR)
  end
  local file = api.nvim_buf_get_name(buf)
  local line = opts.line or cursor_line(buf)
  local r = {
    id = tostring(vim.uv.hrtime()), key = key, buf = buf, file = file, line = line,
    mark = api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {}),
    desc = desc, image = opts.image, proot = prompt.project_root(file),
    preamble = preamble(buf), fixes = 0,
  }
  r.setup = tikz_setup(r.proot)
  M.cur = r
  ui.task_start(key, "✎ drawing")
  step(r, first_prompt(r), r.image and "Reading your sketch" or "Drawing", r.image and { r.image } or nil)
end

function M.refine(ask)
  local r = M.cur
  if not (r and r.out) or vim.trim(ask or "") == "" then return end
  if claude.running(r.key) then return notify("Still drawing", vim.log.levels.WARN) end
  r.fixes, r.checked = 0, true -- a refinement isn't re-checked against the sketch
  ui.task_start(r.key, "✎ refining")
  step(r, refine_prompt(r, ask), "Refining: " .. ask, nil)
end

function M.cancel()
  local r = M.cur
  if r and claude.cancel(r.key) then finish(r, "error", "Cancelled") end
end

-- A picture from nvim (:Tutor draw path): copied next to the window's
-- uploads so the window can show it.
function M.import(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(path) == 0 then return nil, "No such file: " .. path end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if not vim.tbl_contains({ "png", "jpg", "jpeg", "webp", "gif", "pdf" }, ext) then
    return nil, "Use a PNG, JPEG, WebP, GIF or PDF"
  end
  vim.fn.mkdir(M.dir, "p")
  local dest = M.dir .. "/import-" .. vim.fn.sha256(path .. vim.fn.getftime(path)):sub(1, 12) .. "." .. ext
  vim.uv.fs_copyfile(path, dest)
  return dest
end

-- Upload names from the window are plain file names inside M.dir.
function M.upload_path(name)
  if type(name) ~= "string" or not name:match("^[%w%-_]+%.%w+$") then return nil end
  local p = M.dir .. "/" .. name
  return vim.fn.filereadable(p) == 1 and p or nil
end

function M.insert(r)
  r = r or M.cur
  if not (r and r.out and api.nvim_buf_is_valid(r.buf)) then return end
  local pos = api.nvim_buf_get_extmark_by_id(r.buf, ns, r.mark, {})
  local row = pos[1] and (pos[1] + 1) or r.line
  local lines = vim.split((r.out.tikz or ""):gsub("^%s*\n", ""):gsub("%s+$", ""), "\n", { plain = true })
  if r.missing then
    -- \usetikzlibrary also works in the body, so the header stays untouched
    table.insert(lines, 1, "\\usetikzlibrary{" .. table.concat(r.missing, ",") .. "} % for the drawing below")
  end
  api.nvim_buf_set_lines(r.buf, row, row, false, lines)
  notify(string.format("Inserted the drawing (%d lines) below line %d (u undoes it)", #lines, row))
end

function M.yank(r)
  r = r or M.cur
  if not (r and r.out) then return end
  vim.fn.setreg('"', r.out.tikz or "")
  pcall(vim.fn.setreg, "+", r.out.tikz or "")
  notify("TikZ copied")
end

-- Without the window: the code in a float.
function M.float(r)
  local o = r.out
  local L = { "  " .. (o.summary or "") }
  if o.notes and o.notes ~= "" then L[#L + 1] = "  ! " .. o.notes end
  if r.missing then L[#L + 1] = "  + loads \\usetikzlibrary{" .. table.concat(r.missing, ",") .. "} when inserted" end
  L[#L + 1] = "  (it compiles with your preamble; open the Tutor window, Space c g, to see it)"
  L[#L + 1] = ""
  for _, l in ipairs(vim.split(o.tikz or "", "\n", { plain = true })) do L[#L + 1] = "  " .. l end
  L[#L + 1] = ""
  L[#L + 1] = "  i / <CR> insert below   r refine   y copy   q close"
  local fb = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(fb, 0, -1, false, L)
  vim.bo[fb].filetype = "tex"
  vim.bo[fb].modifiable = false
  local width = math.min(100, math.max(50, vim.o.columns - 10))
  local win = api.nvim_open_win(fb, true, {
    relative = "editor", row = 2, col = math.floor((vim.o.columns - width) / 2), width = width,
    height = math.min(#L, math.max(8, vim.o.lines - 8)), style = "minimal", border = "rounded",
    title = " ✎ TikZ ", title_pos = "left",
  })
  local function close() if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end end
  local o2 = { buffer = fb, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, o2)
  vim.keymap.set("n", "<Esc>", close, o2)
  vim.keymap.set("n", "i", function() close(); M.insert(r) end, o2)
  vim.keymap.set("n", "<CR>", function() close(); M.insert(r) end, o2)
  vim.keymap.set("n", "y", function() M.yank(r) end, o2)
  vim.keymap.set("n", "r", function()
    close()
    vim.ui.input({ prompt = "✎ What should change? " }, function(a) if a then M.refine(a) end end)
  end, o2)
end

-- Space c t / :Tutor draw [path]
function M.open(buf, path)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if path and vim.trim(path) ~= "" then
    local img, err = M.import(vim.trim(path))
    if not img then return notify(err, vim.log.levels.ERROR) end
    local gui = require("latex-tutor.gui")
    if gui.running() then
      -- show it in the window, where you can add words before drawing
      M.pending = { buf = buf, image = img, line = cursor_line(buf) }
      return push({ status = "idle", desc = "", image = img, line = M.pending.line }, true)
    end
    return vim.ui.input({ prompt = "✎ Anything to add about the sketch? (Enter = no) " }, function(d)
      if d ~= nil then M.start(buf, { desc = d, image = img }) end
    end)
  end
  if push(M.cur and M.cur.buf == buf and M.cur or { status = "idle", desc = "", line = cursor_line(buf) }, true) then
    return
  end
  vim.ui.input({ prompt = "✎ Describe the diagram: " }, function(d)
    if d and vim.trim(d) ~= "" then M.start(buf, { desc = d }) end
  end)
end

-- Clicks in the window (gui.lua).
function M.action(buf, msg)
  local a = msg.action
  if a == "draw" then
    local img = msg.image and M.upload_path(msg.image) or nil
    local line = M.pending and M.pending.buf == buf and M.pending.line or nil
    M.pending = nil
    M.start(buf, { desc = msg.text or "", image = img, line = line })
  elseif a == "draw_refine" then M.refine(msg.text)
  elseif a == "draw_insert" then M.insert()
  elseif a == "draw_cancel" then M.cancel()
  end
end

return M
