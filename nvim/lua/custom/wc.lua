-- :Wc [msg]  (or lowercase :wc) — write the current buffer, then git add + commit
-- JUST this file. Built for the blessing-ledger review loop: the viewer renders
-- COMMITTED content (`git diff parent...child`), so a saved-but-uncommitted edit
-- is invisible to it. `:wc` collapses save+commit so the edit shows in the viewer
-- immediately. Commits only the current file (pathspec) — never sweeps other
-- changes — and runs git in the file's own dir, so it works inside study
-- worktrees too. Message is optional; defaults to "wip".
--
-- After a successful commit it also flips focus back to the viewer: it finds the
-- browser tab on the viewer port and raises it — so the save→commit→see-it loop
-- is one command. Self-gating: if no such tab is open it does nothing (and never
-- launches the browser), so `:wc` on an unrelated file won't yank you anywhere.

local BROWSER = "Google Chrome"   -- the browser hosting the viewer
local VIEWER_MATCH = ":62333"     -- substring of the viewer URL to find its tab

-- Raise the browser tab whose URL contains VIEWER_MATCH. Returns "true" if found
-- (and focused), "false" otherwise. Never launches the browser if it isn't running.
local function refocus_viewer()
  local out = vim.fn.system({
    "osascript",
    "-e", "on run argv",
    "-e", 'tell application "System Events" to if not (exists process "' .. BROWSER .. '") then return "false"',
    "-e", "set needle to item 1 of argv",
    "-e", 'tell application "' .. BROWSER .. '"',
    "-e", "set found to false",
    "-e", "repeat with w in windows",
    "-e", "set i to 0",
    "-e", "repeat with t in (tabs of w)",
    "-e", "set i to i + 1",
    "-e", "if (URL of t contains needle) then",
    "-e", "set active tab index of w to i",
    "-e", "set index of w to 1",
    "-e", "set found to true",
    "-e", "exit repeat",
    "-e", "end if",
    "-e", "end repeat",
    "-e", "if found then exit repeat",
    "-e", "end repeat",
    "-e", "if found then activate",
    "-e", "return (found as text)",
    "-e", "end tell",
    "-e", "end run",
    VIEWER_MATCH,
  })
  return vim.trim(out or "")
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
  local back = refocus_viewer() == "true" and "  ↩ viewer" or ""
  vim.notify("✦ committed " .. sha .. "  " .. msg .. back, vim.log.levels.INFO)
end, {
  nargs = "?",
  desc = "write + git commit the current file, then refocus the viewer tab (msg optional, default 'wip')",
})

-- lowercase `:wc` → `:Wc`, only when the whole command line is exactly `wc`
vim.cmd([[cnoreabbrev <expr> wc (getcmdtype() == ':' && getcmdline() == 'wc') ? 'Wc' : 'wc']])
