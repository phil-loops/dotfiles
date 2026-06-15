-- :Wc [msg]  (or lowercase :wc) — write the current buffer, then git add + commit
-- JUST this file. Built for the blessing-ledger review loop: the viewer renders
-- COMMITTED content (`git diff parent...child`), so a saved-but-uncommitted edit
-- is invisible to it. `:wc` collapses save+commit so the edit shows in the viewer
-- immediately. Commits only the current file (pathspec) — never sweeps other
-- changes — and runs git in the file's own dir, so it works inside study
-- worktrees too. Message is optional; defaults to "wip".

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
  vim.notify("✦ committed " .. sha .. "  " .. msg, vim.log.levels.INFO)
end, {
  nargs = "?",
  desc = "write + git commit the current file (msg optional, default 'wip')",
})

-- lowercase `:wc` → `:Wc`, only when the whole command line is exactly `wc`
vim.cmd([[cnoreabbrev <expr> wc (getcmdtype() == ':' && getcmdline() == 'wc') ? 'Wc' : 'wc']])
