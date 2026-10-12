# latex-tutor.nvim

Google-Docs-style review comments on LaTeX solutions, inside Neovim and the
live TeXpresso preview. The reviewer is Claude Code running headlessly
(`claude -p`) on your **claude.ai subscription login**, so nothing is billed
per token.

- Highlighted ranges, coloured by severity (error / rigor / improve / latex / praise).
- A numbered sign in the gutter, with the title at the end of the line.
- A floating card with the full comment, hint and thread.
- A sidebar listing every comment as a card, plus the overall verdict and summary.
- Numbered badges in the TeXpresso PDF, with titles in the margin where LaTeX
  allows. The file on disk is never modified.
- Reply threads: tell the tutor you fixed it or argue back, and it re-reads
  the current text and can close the comment.
- Your tutoring preferences come from a Markdown file, `TUTOR.md`.

## Commands and keys

### How to press the keys

- `␣` means the **Space bar**. `␣cc` is three keys pressed one after
  another: **Space**, then **c**, then **c**. Don't hold them together.
- Press them in **normal mode**. If you're typing (insert mode), press
  **Esc** first.
- Press them within about a second of each other. If you pause too long,
  Space acts on its own and moves the cursor one character.
- Don't type `_` instead of Space. In Vim, `_ce` deletes the first word of
  the line. If that happens, press **Esc**, then **u** to undo.
- Every key also has a typed form, shown in the Command column. Type it
  and press **Enter**, for example `:Tutor` then Enter. Use that if the key
  sequence feels fiddly.
- The keys only work in `.tex` files. The sidebar has its own one-letter
  keys, listed below the table; press `?` in the sidebar to see them.
- `<C-s>` means hold **Ctrl** and press **s**. `<CR>` means **Enter**.

The keys are defined only in `.tex` buffers. The prefix is `<localleader>c`,
and localleader is Space in this config.

| Key | Command | What |
|---|---|---|
| `␣cc` | `:Tutor` | Review the exercise under the cursor (`% QUESTION` / `\qs{…}` block) |
| `␣cc` (visual) | `:'<,'>Tutor` | Review the selected lines |
| `␣cf` | `:Tutor file` | Review the whole file (asks first if over 1500 lines) |
| `␣co` | `:Tutor panel` | Toggle the comment sidebar |
| `␣cn` / `␣cp` | `:Tutor next` / `prev` | Jump to the next/previous open comment (scrolls the PDF too) |
| `␣ck` | | Show the card for the comment under the cursor |
| `␣cr` | | Resolve or reopen it |
| `␣cR` | | Reply to it (`<C-s>` sends) |
| `␣cd` | | Delete it |
| `␣ca` | `:Tutor pdf` | Toggle the TeXpresso annotations |
| `␣cx` | `:Tutor cancel` | Cancel a running review |
| `␣ce` | `:Tutor prefs` | Edit the `TUTOR.md` in effect |
| `␣cq` | `:Tutor hide` / `:Tutor show` | Hide everything (sidebar, card, highlights, PDF badges) without losing comments. A review, `␣co`, `␣cn`/`␣cp` or `␣ck` brings it back |
| `␣cs` | `:Tutor progress` | Open your progress report (`q` closes it) |
| | `:Tutor clear` | Drop every comment for this file |

In the sidebar: `<CR>` jump · `r` resolve · `R` reply · `dd` delete ·
`J`/`K` next/prev card · `s` show resolved · `?` keys · `q` close.

A review takes about 30–90 s. A spinner sits in the top-right corner, and you
can keep editing; comments are re-anchored by the text they quote.

## First test (about 5 minutes)

1. Restart nvim, then open a chapter, e.g.
   `nvim ~/math/allofstats/allofstatschap5/allofstatschap5.tex`.
   TeXpresso opens as usual.
2. Run `:Tutor prefs` to check that `TUTOR.md` opens. Close it with `:q`.
3. Go to an exercise, e.g. `:16` for Q 5.8.1, and press `␣cc`. A spinner
   appears in the top-right corner. After about 30–90 s, the comments show up
   in the gutter, the sidebar and the TeXpresso PDF.
4. Press `␣cn` to step through the comments. Press `␣cR` on one, type a
   reply, and send it with `<C-s>`. Press `␣cr` to resolve a comment; its
   badge leaves the PDF.
5. Restart nvim and reopen the file. The comments should still be there.

If the PDF breaks, press `␣ca`, which sends every line back clean. If nothing
happens, run `:messages`.

## Progress tracking (private)

Every review and every resolved comment is logged to
`~/.local/share/nvim/latex-tutor/progress.jsonl`. Press `␣cs` (or run
`:Tutor progress`) to turn the log into a report. It's shown in a split and
saved as `~/.local/share/nvim/latex-tutor/progress.md`. The report covers:

- **Overall:** the number of reviews, and a score on each exercise's latest
  review. It uses the same scale as the self-study record: correct 1,
  minor 0.8, incomplete 0.5, major issues 0. It also counts comments by
  severity and how many you resolved.
- **By manual and by chapter:** the score, the mix of verdicts, and the
  number of error and rigor comments.
- **Week by week:** reviews, average score, and errors and rigor comments
  per review.
- **Changed on re-review:** exercises whose verdict changed after you fixed
  them and reviewed them again.
- **Recent errors and rigor issues you fixed:** the patterns that keep
  coming back.

This data is private because it lives outside every git repo. Your manuals
are public GitHub repos, and a log kept inside them could be committed by
mistake even with a `.gitignore`, for example by `git add -f`. A folder
outside every repo can't be committed at all. The plugin's own `.gitignore`
also excludes `progress*` as a backstop.

Two private files can still end up in a repo:

- **A per-manual `TUTOR.md`.** If you put one inside a manual's repo, keep it
  out of git by adding it to `.git/info/exclude` in that repo. That file is a
  local-only ignore list that never gets pushed.
- **Saved comments.** They live in `~/.local/state/nvim/latex-tutor/`, which
  is also outside every repo.

To start over, delete `progress.jsonl`.

## Tutoring preferences (`TUTOR.md`)

The nearest `TUTOR.md`, walking up from the `.tex` file, wins. That lets one
manual (say, the physics ones) have its own. Otherwise
`~/.config/latex-tutor/TUTOR.md` is used. Write it in plain prose: tone, hint
versus full answer, what to focus on, and what to ignore. It overrides the
built-in reviewer defaults.

## Install / rebuild

The plugin is loaded by `~/.config/nvim/lua/plugins/latex-tutor.lua`:

```lua
return {
  dir = vim.fn.expand("~/latex-tutor.nvim"),
  name = "latex-tutor",
  lazy = false,
  config = function()
    require("latex-tutor").setup({ model = "opus" }) -- options: lua/latex-tutor/config.lua
  end,
}
```

There's no build step. After editing the plugin, restart nvim or run
`:Lazy reload latex-tutor`.

Requirements: Neovim ≥ 0.10 and the `claude` CLI logged in with your claude.ai
account. Check with `claude auth status`, which should show
`"authMethod": "claude.ai"`.

## How it works

- **Subscription, not API.** The plugin runs
  `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --output-format json --json-schema …`.
  With the API-key variables removed, the CLI can only use your OAuth login.
  `--bare` is deliberately *not* used, because it forces API-key auth. The
  `total_cost_usd` field in the CLI's JSON is an estimate and isn't charged on
  a subscription. Reviews do count toward your plan's usage limits.
- **Structured output.** `--json-schema` makes Claude return
  `{verdict, summary, comments:[{line, quote, severity, title, body, hint, fix, confidence}]}`.
  Each comment is anchored by searching for its `quote` near `line`. If the
  quote isn't found, the plugin falls back to highlighting the whole line.
- **Context.** Claude gets the exercise with line numbers, plus your
  preferences. It runs in the manual root (the directory holding `header*.tex`)
  with read-only `Read/Grep/Glob`, so it can look up your macros or an exercise
  you cite. The usual `CLAUDE.md` files load as well.
- **Positions** live in extmarks, so comments move with your edits. State is
  saved to `~/.local/state/nvim/latex-tutor/`, never next to your `.tex`
  files.
- **TeXpresso.** TeXpresso renders whatever text nvim sends it. For each
  commented line, the plugin sends an annotated copy (`change-lines`, with the
  same line count) carrying a self-defining `\tutormarkN{rgb}{n}{title}` macro.
  The `.tex` file and the nvim buffer are never changed. Resolving a comment
  sends the original line back. A scanner keeps badges out of preambles,
  verbatim/TikZ/lstlisting blocks, moving arguments (`\section{}`, `\caption{}`),
  key-value groups (`\tikzset{…}`) and lists before their first `\item`. A
  badge that can't go on its own line moves to the nearest safe line above it.
  Margin notes are suppressed inside boxes, minipages and floats. This was
  checked by badging every safe line of every chapter in `~/math` and
  `~/physics` and compiling each with pdflatex. All 19 chapters compiled.
  `texpresso.lua` is not modified; the plugin only calls `send()` and wraps
  `reload()`/`launch()`.
- If the preview ever misbehaves, press `␣ca` to switch annotations off. That
  sends every annotated line back verbatim.

## Files

```
lua/latex-tutor/
  init.lua     commands, keymaps, review/reply flow, autocmds
  config.lua   defaults + severities
  claude.lua   headless claude runner (subscription auth)
  prompt.lua   system prompt, JSON schemas, TUTOR.md lookup
  scope.lua    exercise / selection / file ranges
  store.lua    comments, extmark sync, quote re-anchoring, persistence
  ui.lua       highlights, signs, card, spinner, reply composer
  panel.lua    sidebar
  pdf.lua      TeXpresso annotation bridge
  progress.lua private progress log + report
```

## Where things are saved

| What | Where | In git? |
|---|---|---|
| Plugin code | `~/latex-tutor.nvim/` | Local repo only (not pushed) |
| Plugin loader | `~/.config/nvim/lua/plugins/latex-tutor.lua` | |
| Tutoring preferences | `~/.config/latex-tutor/TUTOR.md` | No |
| Comments per file | `~/.local/state/nvim/latex-tutor/*.json` | No |
| Progress log / report | `~/.local/share/nvim/latex-tutor/progress.{jsonl,md}` | No |
