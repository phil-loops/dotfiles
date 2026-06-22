-- :Submit  (or lowercase :submit) — hand the current design doc back to the Claude
-- session that launched it. Pairs with the `design` script: that script opens the
-- doc in nvim and records, in a `<doc>.submit-target` sidecar, the tmux pane id of
-- the Claude session. :Submit writes the buffer, then `tmux send-keys` a re-read
-- message into that pane — so editing the doc and `:submit` feeds it straight back
-- to Claude, and we iterate. The whole co-authoring loop, no copy-paste.
--
-- Dual surface: a buffer with a `<doc>.submit-target` sidecar is a design doc (flow
-- above). Otherwise it's code in a git worktree → `:submit` shells out to the
-- `submit` script (warm-route to a live session, else spawn a seeded split) and nvim
-- stays open for the back-and-forth. One verb, dispatched on surface.

vim.api.nvim_create_user_command("Submit", function(opts)
  if vim.bo.buftype ~= "" then
    vim.notify("Submit: not a file buffer", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent! wall") -- save the human's edits (all buffers)
  local file = vim.fn.expand("%:p")
  local sidecar = file .. ".submit-target"

  -- Surface dispatch. A `<doc>.submit-target` sidecar → the design-doc loop (below).
  -- Otherwise this is a code buffer → hand the worktree to the `submit` script
  -- (warm-route to a live session for the anchor, else spawn a seeded split). nvim
  -- stays open: the human keeps editing, the agent replies in its pane and pushes a
  -- refresh back via submit-refresh. `:submit <intent>` rides the intent along.
  if vim.fn.filereadable(sidecar) ~= 1 then
    local wt = vim.fn.systemlist({ "git", "-C", vim.fn.expand("%:p:h"), "rev-parse", "--show-toplevel" })[1]
    if vim.v.shell_error ~= 0 or not wt or wt == "" then
      vim.notify("submit: no design sidecar and not in a git worktree", vim.log.levels.WARN)
      return
    end
    local cmd = { vim.fn.expand("~/.dotfiles/scripts/submit") }
    if opts.args ~= "" then
      vim.list_extend(cmd, { "-m", opts.args })
    end
    table.insert(cmd, wt)
    local out = vim.trim(vim.fn.system(cmd))
    vim.notify("submit: " .. out, vim.v.shell_error == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
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
end, { nargs = "?", desc = "submit: design doc → hand back & close; code buffer → route the worktree to a Claude session (stay open)" })

-- lowercase `:submit` → `:Submit`, only when the whole command line is exactly `submit`
vim.cmd([[cnoreabbrev <expr> submit (getcmdtype() == ':' && getcmdline() == 'submit') ? 'Submit' : 'submit']])
