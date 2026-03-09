-- Stack Review - branch navigation for git-town stacks
-- Pre-opens all diffview tabs in background for instant ]b/[b
local M = {}
local churn = require("custom.stack-churn")
local blessed = require("custom.stack-blessed")
local bindings = require("custom.review-bindings")

-- State
local chain = {}      -- { {branch="...", parent="..."}, ... }
local current_idx = 1
local panel_buf = nil
local panel_win = nil
local churns = {}          -- ChurnHunk[]
local churn_by_branch = {} -- branch -> count
local tab_by_idx = {}      -- chain index -> tabpage handle
local warming = false      -- true while background tabs are being opened

local function refresh_all()
  bindings.refresh_diffview_panel(chain[current_idx] and chain[current_idx].branch or "")
end

local function update_panel()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then return end

  -- Warm tip cache in a single git call
  local branch_names = {}
  for _, item in ipairs(chain) do
    table.insert(branch_names, item.branch)
  end
  blessed.warm_tips(branch_names)

  local lines = {}
  local summaries = {}
  for i, item in ipairs(chain) do
    local marker = (i == current_idx) and " ◀" or ""
    local prefix = (i == current_idx) and "▶ " or "  "
    local short_name = item.branch:gsub("goals%-v%d+%-", "")

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

    -- Show loading indicator for tabs not yet ready
    local ready = tab_by_idx[i] and vim.api.nvim_tabpage_is_valid(tab_by_idx[i])
    local loading_mark = ""
    if not ready and item.parent and item.parent ~= "" then
      loading_mark = " …"
    end

    local suffix = ""
    local cc = churn_by_branch[item.branch] or 0
    if cc > 0 then
      suffix = string.format(" ~%d", cc)
    end

    table.insert(lines, string.format("%s%s%s%s%s%s%s", prefix, bicon, short_name, bcount, suffix, loading_mark, marker))
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

local function open_review(idx)
  if idx < 1 or idx > #chain then return false end

  local item = chain[idx]
  if not item.parent or item.parent == "" then
    vim.notify("No parent to diff against", vim.log.levels.WARN)
    return false
  end

  current_idx = idx

  local target_tab = tab_by_idx[idx]
  if target_tab and vim.api.nvim_tabpage_is_valid(target_tab) then
    -- Instant switch
    vim.api.nvim_set_current_tabpage(target_tab)
    panel_win = nil
    panel_buf = nil
    vim.defer_fn(function()
      M.open_panel()
      refresh_all()
    end, 50)
  else
    -- Not ready yet — open it now (blocking)
    pcall(vim.cmd, "DiffviewClose")
    vim.cmd("DiffviewOpen " .. item.parent .. ".." .. item.branch)
    tab_by_idx[idx] = vim.api.nvim_get_current_tabpage()
    panel_win = nil
    panel_buf = nil
    vim.defer_fn(function()
      M.open_panel()
      refresh_all()
    end, 150)
  end

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

-- Background-open remaining tabs one at a time, returning to the user's tab after each
local function warm_remaining_tabs(start_idx)
  warming = true
  local to_open = {}
  for i, item in ipairs(chain) do
    if i ~= start_idx and item.parent and item.parent ~= "" and not tab_by_idx[i] then
      table.insert(to_open, i)
    end
  end

  local opened = 0
  local function open_next()
    opened = opened + 1
    if opened > #to_open then
      warming = false
      -- Return to the user's branch
      local user_tab = tab_by_idx[current_idx]
      if user_tab and vim.api.nvim_tabpage_is_valid(user_tab) then
        vim.api.nvim_set_current_tabpage(user_tab)
      end
      update_panel()
      return
    end

    local idx = to_open[opened]
    -- Skip if user already navigated here (they triggered a blocking open)
    if tab_by_idx[idx] then
      vim.defer_fn(open_next, 10)
      return
    end

    local item = chain[idx]
    local user_tab = tab_by_idx[current_idx]

    -- Open the diffview (creates a new tab)
    vim.cmd("DiffviewOpen " .. item.parent .. ".." .. item.branch)
    tab_by_idx[idx] = vim.api.nvim_get_current_tabpage()

    -- Immediately switch back to the user's tab
    if user_tab and vim.api.nvim_tabpage_is_valid(user_tab) then
      vim.api.nvim_set_current_tabpage(user_tab)
    end

    update_panel()

    -- Small delay before opening next to avoid freezing the UI
    vim.defer_fn(open_next, 200)
  end

  open_next()
end

function M.open_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    update_panel()
    return
  end

  local file_panel_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("DiffviewFilePanel") then
      file_panel_win = win
      break
    end
  end

  if not file_panel_win then
    vim.notify("Diffview panel not found", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(file_panel_win)

  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(panel_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(panel_buf, "bufhidden", "wipe")

  local height = math.min(#chain + 2, 20)
  vim.cmd("aboveleft " .. height .. "split")
  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_option(panel_win, "number", true)
  vim.api.nvim_win_set_option(panel_win, "relativenumber", false)
  vim.api.nvim_win_set_option(panel_win, "cursorline", true)
  vim.api.nvim_win_set_option(panel_win, "winfixheight", true)

  local opts = { buffer = panel_buf, silent = true }
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    open_review(line)
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

  update_panel()
  vim.cmd("wincmd l")
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
    open_review(current_idx + 1)
  else
    vim.notify("Last branch", vim.log.levels.INFO)
  end
end

function M.prev_branch()
  if current_idx > 1 then
    open_review(current_idx - 1)
  else
    vim.notify("First branch", vim.log.levels.INFO)
  end
end

function M.setup(data)
  chain = data.chain or {}
  current_idx = data.start_idx or 1
  tab_by_idx = {}

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
  vim.keymap.set("n", "<leader>sp", M.toggle_panel, { desc = "Toggle stack panel" })
  vim.keymap.set("n", "<leader>E", M.focus_panel, { desc = "Focus branch panel" })

  vim.keymap.set("n", "<leader>sc", function()
    churn.show(churns)
  end, { desc = "Show stack churn" })

  local function get_all_unreviewed()
    local results = {}
    for ci, item in ipairs(chain) do
      if not item.parent or item.parent == "" then goto continue end
      local diff_lines = vim.fn.systemlist(string.format("git diff --name-only %s..%s 2>/dev/null", item.parent, item.branch))
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
                open_review(target_idx)
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
  ]b / [b       next/prev branch (instant after warmup)
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
    local main_branch = vim.fn.system("git config git-town.main-branch 2>/dev/null"):gsub("%s+$", "")
    if main_branch == "" then main_branch = "main" end

    local config_lines = vim.fn.systemlist("git config --local --list 2>/dev/null | grep 'git-town-branch.*\\.parent='")
    local parents_map = {}
    local children_map = {}
    for _, line in ipairs(config_lines) do
      local branch, parent = line:match("git%-town%-branch%.(.+)%.parent=(.+)")
      if branch and parent then
        parents_map[branch] = parent
        if not children_map[parent] then children_map[parent] = {} end
        table.insert(children_map[parent], branch)
      end
    end

    local cur_branch = chain[current_idx] and chain[current_idx].branch or
      vim.fn.system("git branch --show-current 2>/dev/null"):gsub("%s+$", "")
    local ancestors = {}
    local walk = cur_branch
    while walk and walk ~= main_branch do
      table.insert(ancestors, 1, walk)
      walk = parents_map[walk]
    end
    table.insert(ancestors, 1, main_branch)

    local function find_descendants(b, result)
      for _, child in ipairs(children_map[b] or {}) do
        table.insert(result, child)
        find_descendants(child, result)
      end
    end
    local descendants = {}
    find_descendants(cur_branch, descendants)

    local new_chain = {}
    local all_branches = {}
    for _, b in ipairs(ancestors) do table.insert(all_branches, b) end
    for _, b in ipairs(descendants) do table.insert(all_branches, b) end

    for i, b in ipairs(all_branches) do
      local p = (i == 1) and "" or all_branches[i - 1]
      table.insert(new_chain, { branch = b, parent = p })
    end

    local new_idx = 1
    for i, item in ipairs(new_chain) do
      if item.branch == cur_branch then
        new_idx = i
        break
      end
    end

    -- Close all existing tabs
    for _, tab in pairs(tab_by_idx) do
      if tab and vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, "DiffviewClose")
      end
    end

    chain = new_chain
    current_idx = new_idx
    tab_by_idx = {}

    blessed.invalidate()
    blessed.load()
    blessed.warm_file_counts(chain)
    blessed.warm_tips(vim.tbl_map(function(item) return item.branch end, chain))

    churns = churn.analyze(chain)
    churn_by_branch = churn.by_branch(churns)

    -- Open current branch, then warm the rest in background
    local item = chain[current_idx]
    if item and item.parent and item.parent ~= "" then
      vim.cmd("DiffviewOpen " .. item.parent .. ".." .. item.branch)
      tab_by_idx[current_idx] = vim.api.nvim_get_current_tabpage()
      panel_win = nil
      panel_buf = nil
      vim.defer_fn(function()
        M.open_panel()
        refresh_all()
        warm_remaining_tabs(current_idx)
      end, 200)
    end

    vim.notify(string.format("Refreshed (%d branches)", #chain), vim.log.levels.INFO)
  end, { desc = "Refresh stack review" })

  -- Cache the initial tab (opened by the shell script)
  tab_by_idx[current_idx] = vim.api.nvim_get_current_tabpage()

  -- Open panel, then start warming remaining tabs in background
  vim.defer_fn(function()
    M.open_panel()
    warm_remaining_tabs(current_idx)
  end, 200)
end

return M
