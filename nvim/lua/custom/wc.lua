-- :Wc [msg]  (or lowercase :wc) — write the current buffer, then git add + commit
-- JUST this file. Built for the blessing-ledger review loop: the viewer renders
-- COMMITTED content (`git diff parent...child`), so a saved-but-uncommitted edit
-- is invisible to it. `:wc` collapses save+commit so the edit shows in the viewer
-- immediately. Commits only the current file (pathspec) — never sweeps other
-- changes — and runs git in the file's own dir, so it works inside study
-- worktrees too. Message is optional; defaults to "wip".
--
-- After a successful commit it also flips focus back to the viewer so the
-- save→commit→see-it loop is one command.
--
-- Two gotchas drive the implementation:
--   1. We only refocus when :wc runs in the warm "review-nvim" that stack-open
--      drives (the hover+o → edit → :wc loop) — identified by its listen socket,
--      not by enumerating Chrome's tabs. So :wc in your normal editing nvim never
--      yanks you to the browser, and we need no Apple events to decide that.
--   2. Raising Chrome uses `open -a` (LaunchServices), NOT AppleScript `activate`.
--      Under a detached tmux server (parented by launchd) macOS denies Apple events
--      to other apps with -1743 ("Not authorized to send Apple events"), so the old
--      `tell application "Google Chrome"` silently failed and focus never moved.
--      `open -a` needs no Automation permission and works from inside tmux.

local BROWSER = "Google Chrome"                    -- the browser hosting the viewer
-- substrings of the viewer URL, tried in priority order. :5174 = the Solid dev viewer
-- (preferred during the migration); :62333 = the vanilla server, and also where the Solid
-- app lands after the cutover — so this keeps working through and past the migration.
local VIEWER_MATCHES = { ":5174", ":62333" }
local REVIEW_SOCK = "/tmp/stack-review-nvim.sock"  -- STACK_OPEN_SOCK: the warm review-nvim's socket

-- True only in the review-nvim stack-open opens files into. Gating on the listen
-- socket (not Chrome's tabs) keeps the decision permission-free.
local function in_review_loop()
  if vim.v.servername == REVIEW_SOCK then
    return true
  end
  return vim.tbl_contains(vim.fn.serverlist(), REVIEW_SOCK)
end

-- Raise the viewer's browser. Returns true if we refocused, false otherwise.
-- No-ops outside the review loop or when the browser isn't running (never launches it).
local function refocus_viewer()
  if not in_review_loop() then
    return false
  end
  vim.fn.system({ "pgrep", "-x", BROWSER })
  if vim.v.shell_error ~= 0 then -- browser not running → don't launch it
    return false
  end
  -- Best-effort: select the viewer tab when Automation IS available (e.g. not under
  -- a detached tmux). Harmless -1743 no-op when it isn't — `open -a` below still raises.
  -- Try each needle in priority order; stop at the first viewer tab we can select.
  for _, needle in ipairs(VIEWER_MATCHES) do
    local out = vim.fn.system({
      "osascript",
      "-e", "on run argv",
      "-e", "set needle to item 1 of argv",
      "-e", 'tell application "' .. BROWSER .. '"',
      "-e", "repeat with w in windows",
      "-e", "set i to 0",
      "-e", "repeat with t in (tabs of w)",
      "-e", "set i to i + 1",
      "-e", "if (URL of t contains needle) then",
      "-e", "set active tab index of w to i",
      "-e", "set index of w to 1",
      "-e", 'return "1"',
      "-e", "end if",
      "-e", "end repeat",
      "-e", "end repeat",
      "-e", 'return ""',
      "-e", "end tell",
      "-e", "end run",
      needle,
    })
    if (out or ""):match("1") then
      break
    end
  end
  -- Guaranteed: raise the browser window via LaunchServices (no Apple-event permission).
  vim.fn.system({ "open", "-a", BROWSER })
  return vim.v.shell_error == 0
end

vim.api.nvim_create_user_command("Wc", function(opts)
  if vim.bo.buftype ~= "" then
    vim.notify("Wc: not a file buffer", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent write")
  local file = vim.fn.expand("%:p")
  local dir = vim.fn.fnamemodify(file, ":h")
  local msg = opts.args ~= "" and opts.args or "wip"

  vim.fn.system({ "git", "-C", dir, "add", "--", file })
  local out = vim.fn.system({ "git", "-C", dir, "commit", "-m", msg, "--", file })
  if vim.v.shell_error ~= 0 then
    vim.notify("Wc: " .. vim.trim(out), vim.log.levels.WARN) -- e.g. "nothing to commit"
    return
  end

  local sha = vim.trim(vim.fn.system({ "git", "-C", dir, "rev-parse", "--short", "HEAD" }))
  -- notify first (we're about to lose focus to the browser), then flip back to the viewer
  local back = refocus_viewer() and "  ↩ viewer" or ""
  vim.notify("✦ committed " .. sha .. "  " .. msg .. back, vim.log.levels.INFO)
end, {
  nargs = "?",
  desc = "write + git commit the current file, then refocus the viewer tab (msg optional, default 'wip')",
})

-- lowercase `:wc` → `:Wc`, only when the whole command line is exactly `wc`
vim.cmd([[cnoreabbrev <expr> wc (getcmdtype() == ':' && getcmdline() == 'wc') ? 'Wc' : 'wc']])
