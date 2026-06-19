-- :Submit  (or lowercase :submit) — hand the current design doc back to the Claude
-- session that launched it. Pairs with the `design` script: that script opens the
-- doc in nvim and records, in a `<doc>.submit-target` sidecar, the tmux pane id of
-- the Claude session. :Submit writes the buffer, then `tmux send-keys` a re-read
-- message into that pane — so editing the doc and `:submit` feeds it straight back
-- to Claude, and we iterate. The whole co-authoring loop, no copy-paste.

vim.api.nvim_create_user_command("Submit", function(opts)
  if vim.bo.buftype ~= "" then
    vim.notify("Submit: not a file buffer", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent write")
  local file = vim.fn.expand("%:p")
  local sidecar = file .. ".submit-target"
  if vim.fn.filereadable(sidecar) ~= 1 then
    vim.notify("Submit: no " .. vim.fn.fnamemodify(sidecar, ":t") .. " — open this doc via `design`", vim.log.levels.WARN)
    return
  end
  local target = vim.trim(vim.fn.readfile(sidecar)[1] or "")
  if target == "" then
    vim.notify("Submit: empty target pane", vim.log.levels.WARN)
    return
  end
  -- optional note after :Submit <msg> rides along so you can steer the iteration
  local note = opts.args ~= "" and (" — " .. opts.args) or ""
  local msg = "design doc submitted, please re-read " .. file .. note
  vim.fn.system({ "tmux", "send-keys", "-t", target, msg, "Enter" })
  if vim.v.shell_error ~= 0 then
    vim.notify("Submit: couldn't reach pane " .. target .. " (still saved)", vim.log.levels.WARN)
    return
  end
  -- snap focus back to the Claude pane, then close nvim — the doc is handed off, so
  -- get out of the way. `dd` re-enters a fresh nvim when Claude's rewrite is ready.
  vim.fn.system({ "tmux", "select-window", "-t", target })
  vim.fn.system({ "tmux", "select-pane", "-t", target })
  vim.cmd("silent! wall") -- save any other touched buffers so qa won't block
  vim.cmd("qa")
end, { nargs = "?", desc = "hand the current design doc back to the Claude session, refocus it, and close nvim" })

-- lowercase `:submit` → `:Submit`, only when the whole command line is exactly `submit`
vim.cmd([[cnoreabbrev <expr> submit (getcmdtype() == ':' && getcmdline() == 'submit') ? 'Submit' : 'submit']])
