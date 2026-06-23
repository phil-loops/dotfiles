-- :SteerSubmit — hand your working edits to the headless-Claude "steer" conversation.
--
-- Pairs with `steer-open`: that script opens a real branch file in nvim and sets
--   g:steer_branch  the branch being steered
--   g:steer_wt      the worktree root (where the file lives, for diffing)
--   g:steer_turn    the file `steer-chat --watch` polls in the left pane
-- :SteerSubmit writes the buffer, diffs it against the branch tip, and drops
-- "here's where I'm taking <path>: <diff>" (plus any `:SteerSubmit <note>`) into the
-- turn file — the left pane then streams Claude's reply. You steer by editing real
-- code with full LSP/formatting; no copy-paste. This is the headless path: it never
-- touches your interactive Claude session (cf. `:Submit`, which does).
--
-- M.start() builds the two-window layout inside this single nvim: a left :terminal
-- running g:steer_chat_cmd (the conversation, streamed natively) beside the code.

local M = {}

local function relpath(file, wt)
  wt = (wt or ""):gsub("/+$", "")
  if wt ~= "" then
    local stripped = file:gsub("^" .. vim.pesc(wt) .. "/", "")
    if stripped ~= file then return stripped end
  end
  return vim.fn.fnamemodify(file, ":t")
end

local function steer_submit(opts)
  local turn = vim.g.steer_turn
  if not turn or turn == "" then
    vim.notify("SteerSubmit: not a steer session (open via the viewer's ◆ steer button)", vim.log.levels.WARN)
    return
  end
  if vim.bo.buftype ~= "" then
    vim.notify("SteerSubmit: not a file buffer", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent write")

  local wt = vim.g.steer_wt or ""
  local file = vim.fn.expand("%:p")
  local rel = relpath(file, wt)

  -- the steering signal: your uncommitted edits to this file vs the branch tip
  local diff = ""
  if wt ~= "" then
    diff = vim.fn.system({ "git", "-C", wt, "diff", "--", rel })
    if vim.v.shell_error ~= 0 then diff = "" end
  end

  local parts = {}
  local note = opts.args ~= "" and opts.args or ""
  if note ~= "" then table.insert(parts, note) end
  if vim.trim(diff) ~= "" then
    table.insert(parts, "Here's the change I'm working on in `" .. rel .. "`:\n\n```diff\n" .. diff .. "```")
  else
    -- no diff (a fresh sketch / scratch buffer) → send the buffer content instead
    local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    if vim.trim(body) ~= "" then
      table.insert(parts, "Here's my sketch for `" .. rel .. "`:\n\n```ts\n" .. body .. "\n```")
    end
  end
  if #parts == 0 then
    vim.notify("SteerSubmit: nothing to send (no edits, no note)", vim.log.levels.WARN)
    return
  end

  local f, err = io.open(turn, "w")
  if not f then
    vim.notify("SteerSubmit: can't write turn file: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end
  f:write(table.concat(parts, "\n\n"))
  f:close()
  vim.notify("◆ submitted — Claude is replying in the left pane", vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("SteerSubmit", steer_submit,
  { nargs = "?", desc = "hand your working diff (+ optional note) to the steer conversation" })

-- :SteerQuit — close the workspace cleanly: stop the chat terminal job(s) so nvim can
-- exit without the "job still running" prompt, then quit. (The conversation survives in
-- the session sidecar, so relaunching the same branch resumes it.)
function M.quit()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, jid = pcall(function() return vim.b[b].terminal_job_id end)
    if ok and jid then pcall(vim.fn.jobstop, jid) end
  end
  vim.cmd("qall!")
end
vim.api.nvim_create_user_command("SteerQuit", function() M.quit() end,
  { desc = "stop the steer chat job and quit the workspace (no prompt)" })

-- lowercase shortcuts, only when the whole command line matches exactly:
--   :steer → :SteerSubmit    :sq → :SteerQuit
vim.cmd([[cnoreabbrev <expr> steer (getcmdtype() == ':' && getcmdline() == 'steer') ? 'SteerSubmit' : 'steer']])
vim.cmd([[cnoreabbrev <expr> sq (getcmdtype() == ':' && getcmdline() == 'sq') ? 'SteerQuit' : 'sq']])

-- Build the workspace inside this nvim: a left :terminal running the headless-claude
-- conversation beside the code buffer nvim already opened. Called via -c by steer-open.
function M.start()
  local cmd = vim.g.steer_chat_cmd
  if not cmd or cmd == "" then return end
  vim.cmd("topleft vsplit")                 -- new window on the left, now focused
  vim.cmd("terminal " .. cmd)               -- run steer-chat --watch in it (streams natively)
  vim.opt_local.number = false
  vim.opt_local.relativenumber = false
  pcall(vim.cmd, "vertical resize " .. math.floor(vim.o.columns * 0.5))
  vim.cmd("wincmd l")                        -- back to the code window on the right
end

return M
