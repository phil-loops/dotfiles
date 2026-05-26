-- Stack Review - branch navigation for stack-tracked branches
-- Reads stack-branch.*.parent.
-- Single diffview tab, swap range via internal API on ]b/[b
local M = {}
local churn = require("custom.stack-churn")
local blessed = require("custom.stack-blessed")
local bindings = require("custom.review-bindings")

-- Diffview internals (for range swapping)
local diffview_lib = require("diffview.lib")
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType

-- State
local chain = {}      -- { {branch="...", parent="..."}, ... }
local current_idx = 1
local panel_buf = nil
local panel_win = nil
local churns = {}          -- ChurnHunk[]
local churn_by_branch = {} -- branch -> count

-- Resolve a ref name to a GitRev(COMMIT, sha)
local function resolve_rev(name)
  local sha = vim.fn.system("git rev-parse " .. name .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 or sha == "" then return nil end
  return GitRev(RevType.COMMIT, sha)
end

-- Resolve the merge-base of two refs to a GitRev(COMMIT, sha). Three-dot
-- semantics: show only what `branch` added since it forked from `parent`, never
-- commits that landed on `parent` afterward (else a stale base floods the
-- review with upstream files that vanish on rebase).
local function resolve_merge_base(a, b)
  local sha = vim.fn.system(string.format("git merge-base %s %s 2>/dev/null", a, b)):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 or sha == "" then return nil end
  return GitRev(RevType.COMMIT, sha)
end

-- Swap the current diffview's range without closing/reopening
local function swap_diffview_range(parent, branch)
  local view = diffview_lib.get_current_view()
  if not view then return false end

  local left = resolve_merge_base(parent, branch) or resolve_rev(parent)
  local right = resolve_rev(branch)
  if not left or not right then return false end

  view:change_range(left, right, parent .. "..." .. branch)
  return true
end

-- Ensure the shared panel_buf exists
local function ensure_panel_buf()
  if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then return end
  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(panel_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(panel_buf, "bufhidden", "hide")
end

local function refresh_all()
  bindings.refresh_diffview_panel(chain[current_idx] and chain[current_idx].branch or "")
end

local function update_panel()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then return end

  local branch_names = {}
  for _, item in ipairs(chain) do
    table.insert(branch_names, item.branch)
  end
  blessed.warm_tips(branch_names)

  local lines = {}
  local summaries = {}
  for i, item in ipairs(chain) do
    local marker = (i == current_idx) and " ◀" or ""
    local indent = string.rep("  ", item.depth or 0)
    local prefix = (i == current_idx) and "▶ " or "  "
    local short_name = item.branch:gsub("goals%-v%d+%-", "")

    -- Virtual feature entry: render in a dedicated style, skip blessed lookup
    -- (the label isn't a real ref).
    if item.is_feature then
      summaries[i] = { status = "feature", reviewed = 0, total = 0, stale_count = 0, total_files = 0 }
      table.insert(lines, string.format("%s%s%s%s", indent, prefix, short_name, marker))
      goto continue
    end

    local bsum = blessed.summary(item.branch, item.parent or "")
    local total_files = blessed.file_count(item.branch)
    summaries[i] = bsum
    summaries[i].total_files = total_files

    local bicon, bcount
    if total_files == 0 then
      bicon = "  "
      bcount = ""
    elseif bsum.status == "clean" and bsum.reviewed >= total_files then
      bicon = "✓ "
      bcount = ""
    elseif bsum.stale_count > 0 then
      bicon = "! "
      bcount = string.format(" (%d/%d)", bsum.reviewed, total_files)
    elseif bsum.reviewed > 0 then
      bicon = "  "
      bcount = string.format(" (%d/%d)", bsum.reviewed, total_files)
    else
      bicon = "  "
      bcount = ""
    end

    local suffix = ""
    local cc = churn_by_branch[item.branch] or 0
    if cc > 0 then
      suffix = string.format(" ~%d", cc)
    end

    -- Leaf branches get a → arrow showing the virtual edge to the feature.
    local leaf_arrow = item.is_leaf and "  →" or ""

    table.insert(lines, string.format("%s%s%s%s%s%s%s%s", indent, prefix, bicon, short_name, bcount, suffix, leaf_arrow, marker))
    ::continue::
  end

  vim.api.nvim_buf_set_option(panel_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_buf, "modifiable", false)

  local ns = vim.api.nvim_create_namespace("stack_blessed")
  vim.api.nvim_buf_clear_namespace(panel_buf, ns, 0, -1)
  for i, _ in ipairs(chain) do
    local bsum = summaries[i]
    local col = 2
    if bsum.status == "clean" and bsum.reviewed >= (bsum.total_files or 0) then
      vim.api.nvim_buf_add_highlight(panel_buf, ns, "DiagnosticOk", i - 1, col, col + 4)
    elseif bsum.stale_count > 0 then
      vim.api.nvim_buf_add_highlight(panel_buf, ns, "DiagnosticWarn", i - 1, col, col + 2)
    end
  end

  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_set_cursor, panel_win, {current_idx, 0})
  end
end

local panel_keymaps_set = false

local function setup_panel_keymaps()
  if panel_keymaps_set then return end
  panel_keymaps_set = true

  local opts = { buffer = panel_buf, silent = true }
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    M.open_review(line)
  end, opts)
  vim.keymap.set("n", "j", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] < #chain then
      vim.api.nvim_win_set_cursor(0, {pos[1] + 1, 0})
    end
  end, opts)
  vim.keymap.set("n", "k", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] > 1 then
      vim.api.nvim_win_set_cursor(0, {pos[1] - 1, 0})
    end
  end, opts)
  vim.keymap.set("n", "q", function()
    vim.cmd("qa")
  end, opts)

  vim.keymap.set("n", "x", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local item = chain[line]
    if item and item.parent then
      blessed.bless_branch(item.branch, item.parent)
      update_panel()
      refresh_all()
    end
  end, opts)

  vim.keymap.set("n", "X", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local item = chain[line]
    if item then
      blessed.unbless_branch(item.branch)
      vim.notify("Unblessed " .. item.branch, vim.log.levels.INFO)
      update_panel()
      refresh_all()
    end
  end, opts)

  vim.keymap.set("n", "s", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local item = chain[line]
    if not item then return end
    local sum = blessed.summary(item.branch, item.parent or "")
    if sum.status == "unblessed" then
      vim.notify(item.branch .. ": no files reviewed yet", vim.log.levels.INFO)
    elseif sum.status == "clean" then
      vim.notify(string.format("%s: all %d files clean", item.branch, sum.total), vim.log.levels.INFO)
    else
      local msg = { string.format("%s: %d/%d reviewed, %d stale:", item.branch, sum.reviewed, sum.total, sum.stale_count) }
      for _, f in ipairs(sum.stale_files) do
        table.insert(msg, "  ! " .. f)
      end
      vim.notify(table.concat(msg, "\n"), vim.log.levels.WARN)
    end
  end, opts)
end

-- Find the diffview file-panel window in the current tabpage (if any)
local function find_diffview_file_panel_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match("DiffviewFilePanel") then
      return win
    end
  end
  return nil
end

function M.open_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    update_panel()
    return
  end

  local file_panel_win = find_diffview_file_panel_win()

  if not file_panel_win then
    vim.notify("Diffview panel not found", vim.log.levels.WARN)
    return
  end

  ensure_panel_buf()
  setup_panel_keymaps()

  vim.api.nvim_set_current_win(file_panel_win)

  local height = math.min(#chain + 2, 20)
  vim.cmd("aboveleft " .. height .. "split")
  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_option(panel_win, "number", true)
  vim.api.nvim_win_set_option(panel_win, "relativenumber", false)
  vim.api.nvim_win_set_option(panel_win, "cursorline", true)
  vim.api.nvim_win_set_option(panel_win, "winfixheight", true)

  update_panel()
  vim.cmd("wincmd l")
end

function M.open_review(idx)
  if idx < 1 or idx > #chain then return false end

  local item = chain[idx]
  if not item.parent or item.parent == "" then
    vim.notify("No parent to diff against", vim.log.levels.WARN)
    return false
  end

  current_idx = idx

  -- Virtual feature entry: build integration ref on demand, then diff main..ref.
  -- Integration may fail (overlapping leaves) — surface the bash error to the
  -- user and bail without swapping the diff.
  local diff_right = item.branch
  if item.is_feature and item.project_name then
    local result = vim.fn.system("loops stack integrate " .. vim.fn.shellescape(item.project_name) .. " 2>&1")
    local rc = vim.v.shell_error
    if rc ~= 0 then
      vim.notify("Integration failed:\n" .. result, vim.log.levels.WARN)
      return false
    end
    diff_right = vim.trim(result)
    if diff_right == "" then
      vim.notify("stack-integrate returned empty ref", vim.log.levels.ERROR)
      return false
    end
  end

  -- Swap the diffview range in-place (no tab close/reopen)
  local ok = swap_diffview_range(item.parent, diff_right)
  if not ok then
    vim.notify("Failed to swap diffview range", vim.log.levels.ERROR)
    return false
  end

  update_panel()
  refresh_all()

  -- Hop into the diffview file panel so its keymaps (<tab> = next file) work,
  -- regardless of where we triggered the review from. If diffview launched
  -- on a single-file range, the panel may not have been rendered — toggle it
  -- open in that case so subsequent swaps to multi-file branches are navigable.
  local fp_win = find_diffview_file_panel_win()
  if not fp_win then
    pcall(vim.cmd, "DiffviewToggleFiles")
    fp_win = find_diffview_file_panel_win()
  end
  if fp_win then vim.api.nvim_set_current_win(fp_win) end

  local bsum = blessed.summary(item.branch, item.parent or "")
  local extra = ""
  if bsum.status == "clean" then
    extra = string.format(" [%d/%d ✓]", bsum.reviewed, bsum.total)
  elseif bsum.status == "partial" or bsum.status == "stale" then
    extra = string.format(" [%d/%d reviewed, %d stale]", bsum.reviewed, bsum.total, bsum.stale_count)
  end
  vim.notify(string.format("Reviewing: %s (%d/%d)%s", item.branch, idx, #chain, extra), vim.log.levels.INFO)

  return true
end

function M.focus_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_set_current_win(panel_win)
  else
    M.open_panel()
    if panel_win and vim.api.nvim_win_is_valid(panel_win) then
      vim.api.nvim_set_current_win(panel_win)
    end
  end
end

function M.close_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_win_close(panel_win, true)
    panel_win = nil
  end
end

function M.toggle_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    M.close_panel()
  else
    M.open_panel()
  end
end

function M.next_branch()
  if current_idx < #chain then
    M.open_review(current_idx + 1)
  else
    vim.notify("Last branch", vim.log.levels.INFO)
  end
end

function M.prev_branch()
  if current_idx > 1 then
    M.open_review(current_idx - 1)
  else
    vim.notify("First branch", vim.log.levels.INFO)
  end
end

function M.checkout_current()
  local item = chain[current_idx]
  if not item then
    vim.notify("No branch selected", vim.log.levels.WARN)
    return
  end
  vim.fn.system("git checkout " .. item.branch)
  vim.notify("Checked out " .. item.branch, vim.log.levels.INFO)
end

function M.setup(data)
  chain = data.chain or {}
  current_idx = data.start_idx or 1
  M._target = data.target  -- project name or branch, for gr refresh

  blessed.load()
  blessed.warm_file_counts(chain)

  churns = churn.analyze(chain)
  churn_by_branch = churn.by_branch(churns)

  if #churns > 0 then
    vim.notify(string.format("Churn detected: %d hunks across %d branches (press <leader>sc to view)",
      #churns, vim.tbl_count(churn_by_branch)), vim.log.levels.WARN)
  end

  vim.keymap.set("n", "]b", M.next_branch, { desc = "Next branch in stack" })
  vim.keymap.set("n", "[b", M.prev_branch, { desc = "Prev branch in stack" })
  vim.keymap.set("n", "<leader>>", M.next_branch, { desc = "Next branch in stack" })
  vim.keymap.set("n", "<leader><", M.prev_branch, { desc = "Prev branch in stack" })
  vim.keymap.set("n", "<leader>sp", M.toggle_panel, { desc = "Toggle stack panel" })
  vim.keymap.set("n", "<leader>E", M.focus_panel, { desc = "Focus branch panel" })

  vim.keymap.set("n", "<leader>gc", M.checkout_current, { desc = "[G]it [C]heckout current branch" })

  vim.keymap.set("n", "<leader>sc", function()
    churn.show(churns)
  end, { desc = "Show stack churn" })

  local function get_all_unreviewed()
    local results = {}
    for ci, item in ipairs(chain) do
      if not item.parent or item.parent == "" then goto continue end
      local diff_lines = vim.fn.systemlist(string.format("git diff --name-only %s...%s 2>/dev/null", item.parent, item.branch))
      if vim.v.shell_error == 0 and diff_lines then
        local known = {}
        for _, fp in ipairs(blessed.file_list(item.branch)) do
          known[fp] = true
        end
        for _, fp in ipairs(diff_lines) do
          local status = known[fp] and blessed.file_status(item.branch, fp) or "unblessed"
          if status ~= "clean" then
            local entry = { branch = item.branch, filepath = fp, status = status }
            if ci ~= current_idx then
              local target_idx = ci
              entry.switch_to = function(callback)
                M.open_review(target_idx)
                vim.defer_fn(function()
                  if callback then callback() end
                end, 100)
              end
            end
            table.insert(results, entry)
          end
        end
      end
      ::continue::
    end
    return results
  end

  bindings.setup({
    get_branch = function() return chain[current_idx] and chain[current_idx].branch or "" end,
    get_base = function() return chain[current_idx] and chain[current_idx].parent or "" end,
    get_unreviewed = get_all_unreviewed,
    on_blessed = function()
      update_panel()
      refresh_all()
    end,
    help_text = [[
Stack Review Keybindings:
  <leader>> / <leader><  next/prev branch (also ]b / [b)
  ]u / [u       next/prev unreviewed file
  <leader>e     focus file panel
  <leader>E     focus branch panel
  <leader>sp    toggle stack panel
  <leader>sc    show churn details
  <leader>sb    bless current file
  <leader>sB    bless all files on current branch
  go            open file in new tab (with LSP)
  gd            show delta since blessed (new tab)
  gy            copy branch:file ref to clipboard
  gr            refresh (after sync/rebase)
  g?            show this help

  Panel keybindings:
  <CR>          jump to branch
  j / k         move cursor
  x             bless all files on branch
  X             unbless branch
  s             show file review status
  q             quit

  Blessed = "I reviewed this file's content" (survives rebases)
  ✓ = all clean  · = partially reviewed  ! = stale files
]],
  })

  vim.keymap.set("n", "gr", function()
    -- Re-derive the chain by shelling out to stack-review --print-chain, which
    -- handles project vs single-branch mode identically to the initial launch
    -- (real parents, depth, is_leaf, virtual feature node).
    local target = M._target or (chain[current_idx] and chain[current_idx].branch) or ""
    if target == "" then
      vim.notify("gr: no refresh target", vim.log.levels.WARN)
      return
    end
    local cmd = string.format("loops stack review --print-chain %s 2>&1", vim.fn.shellescape(target))
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      vim.notify("gr: refresh failed:\n" .. out, vim.log.levels.ERROR)
      return
    end

    -- The output is a lua table literal; eval it.
    local loader, err = loadstring("return " .. out)
    if not loader then
      vim.notify("gr: failed to parse chain: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local ok, new_chain = pcall(loader)
    if not ok or type(new_chain) ~= "table" then
      vim.notify("gr: chain payload invalid", vim.log.levels.ERROR)
      return
    end

    -- Preserve cursor position by branch name where possible.
    local prev_branch = chain[current_idx] and chain[current_idx].branch or ""
    chain = new_chain
    current_idx = 1
    for i, item in ipairs(chain) do
      if item.branch == prev_branch then current_idx = i; break end
    end

    blessed.invalidate()
    blessed.load()
    blessed.warm_file_counts(chain)
    blessed.warm_tips(vim.tbl_map(function(item) return item.branch end, chain))

    churns = churn.analyze(chain)
    churn_by_branch = churn.by_branch(churns)

    -- Swap range on existing view (skip virtual feature entries).
    local item = chain[current_idx]
    if item and item.parent and item.parent ~= "" and not item.is_feature then
      swap_diffview_range(item.parent, item.branch)
    end

    update_panel()
    refresh_all()
    vim.notify(string.format("Refreshed (%d entries)", #chain), vim.log.levels.INFO)
  end, { desc = "Refresh stack review" })

  -- Open panel on the initial diffview tab (already opened by shell script)
  vim.defer_fn(function()
    M.open_panel()
  end, 200)
end

return M
