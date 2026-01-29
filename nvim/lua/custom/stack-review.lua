-- Stack Review - branch navigation for git-town stacks
local M = {}
local churn = require("custom.stack-churn")
local blessed = require("custom.stack-blessed")

-- State
local chain = {}      -- { {branch="...", parent="..."}, ... }
local current_idx = 1
local panel_buf = nil
local panel_win = nil
local churns = {}          -- ChurnHunk[]
local churn_by_branch = {} -- branch -> count

local function update_panel()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then return end

  -- Warm tip cache in a single git call
  local branch_names = {}
  for _, item in ipairs(chain) do
    table.insert(branch_names, item.branch)
  end
  blessed.warm_tips(branch_names)

  local lines = {}
  local summaries = {} -- cache per-branch summary for reuse in highlights
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

    local suffix = ""
    local cc = churn_by_branch[item.branch] or 0
    if cc > 0 then
      suffix = string.format(" ~%d", cc)
    end

    table.insert(lines, string.format("%s%s%s%s%s%s", prefix, bicon, short_name, bcount, suffix, marker))
  end

  vim.api.nvim_buf_set_option(panel_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_buf, "modifiable", false)

  -- Apply highlights for blessed status (reuse cached summaries)
  local ns = vim.api.nvim_create_namespace("stack_blessed")
  vim.api.nvim_buf_clear_namespace(panel_buf, ns, 0, -1)
  for i, _ in ipairs(chain) do
    local bsum = summaries[i]
    local col = 2 -- after "▶ " or "  " prefix
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
  pcall(vim.cmd, "DiffviewClose")
  vim.cmd("DiffviewOpen " .. item.parent .. ".." .. item.branch)

  local bsum = blessed.summary(item.branch, item.parent or "")
  local extra = ""
  if bsum.status == "clean" then
    extra = string.format(" [%d/%d ✓]", bsum.reviewed, bsum.total)
  elseif bsum.status == "partial" or bsum.status == "stale" then
    extra = string.format(" [%d/%d reviewed, %d stale]", bsum.reviewed, bsum.total, bsum.stale_count)
  end
  vim.notify(string.format("Reviewing: %s (%d/%d)%s", item.branch, idx, #chain, extra), vim.log.levels.INFO)

  -- Reopen panel after diffview loads
  vim.defer_fn(function()
    M.open_panel()
  end, 150)

  return true
end

function M.open_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    update_panel()
    return
  end

  -- Find diffview file panel
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
  vim.api.nvim_win_set_option(panel_win, "number", false)
  vim.api.nvim_win_set_option(panel_win, "relativenumber", false)
  vim.api.nvim_win_set_option(panel_win, "cursorline", true)
  vim.api.nvim_win_set_option(panel_win, "winfixheight", true)

  -- Panel keymaps
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

  -- Blessed state keymaps
  vim.keymap.set("n", "x", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local item = chain[line]
    if item and item.parent then
      blessed.bless_branch(item.branch, item.parent)
      update_panel()
      refresh_diffview_panel()
    end
  end, opts)

  vim.keymap.set("n", "X", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local item = chain[line]
    if item then
      blessed.unbless_branch(item.branch)
      vim.notify("Unblessed " .. item.branch, vim.log.levels.INFO)
      update_panel()
      refresh_diffview_panel()
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

  -- Load blessed state and warm caches
  blessed.load()
  blessed.warm_file_counts(chain)

  -- Run churn analysis
  churns = churn.analyze(chain)
  churn_by_branch = churn.by_branch(churns)

  if #churns > 0 then
    vim.notify(string.format("Churn detected: %d hunks across %d branches (press <leader>sc to view)",
      #churns, vim.tbl_count(churn_by_branch)), vim.log.levels.WARN)
  end

  -- Global keymaps
  vim.keymap.set("n", "]b", M.next_branch, { desc = "Next branch in stack" })
  vim.keymap.set("n", "[b", M.prev_branch, { desc = "Prev branch in stack" })
  vim.keymap.set("n", "<leader>sp", M.toggle_panel, { desc = "Toggle stack panel" })
  vim.keymap.set("n", "<leader>E", M.focus_panel, { desc = "Focus branch panel" })

  vim.keymap.set("n", "<leader>sc", function()
    churn.show(churns)
  end, { desc = "Show stack churn" })

  -- Get the filepath of the currently focused file in diffview
  local function get_diffview_filepath()
    local ok, lib = pcall(require, "diffview.lib")
    if not ok then return nil end
    local view = lib.get_current_view()
    if not view or not view.panel or not view.panel.cur_file then return nil end
    return view.panel.cur_file.path
  end

  -- Refresh blessed indicators in diffview's file panel
  local function refresh_diffview_panel()
    local ok, lib = pcall(require, "diffview.lib")
    if not ok then return end
    local view = lib.get_current_view()
    if not view or not view.panel then return end
    -- Re-populate blessed_status on file entries
    local branch = view.rev_arg and view.rev_arg:match("%.%.(.+)$")
    if branch then
      for _, file in view.files:iter() do
        file.blessed_status = blessed.file_status(branch, file.path)
      end
    end
    view.panel:render()
    view.panel:redraw()
  end

  vim.keymap.set("n", "go", function()
    local item = chain[current_idx]
    if not item then return end

    local filepath = get_diffview_filepath()
    if not filepath then
      vim.notify("Focus a file first", vim.log.levels.WARN)
      return
    end

    -- Checkout the branch so LSP sees the right code
    local cur_branch = vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null"):gsub("%s+$", "")
    if cur_branch ~= item.branch then
      vim.fn.system("git checkout " .. item.branch .. " 2>/dev/null")
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to checkout " .. item.branch, vim.log.levels.ERROR)
        return
      end
    end

    -- Open the real file in a new tab so LSP works
    local cwd = vim.fn.getcwd()
    local fullpath = cwd .. "/" .. filepath
    vim.cmd("tabedit " .. vim.fn.fnameescape(fullpath))
  end, { desc = "Open file in new tab (with LSP)" })

  vim.keymap.set("n", "gd", function()
    local item = chain[current_idx]
    if not item then return end

    local filepath = get_diffview_filepath()
    if not filepath then
      vim.notify("Focus a file first", vim.log.levels.WARN)
      return
    end

    local bsha = blessed.get_sha(item.branch, filepath)
    if not bsha then
      vim.notify("File not blessed yet", vim.log.levels.WARN)
      return
    end

    local fs = blessed.file_status(item.branch, filepath)
    if fs == "clean" then
      vim.notify("File unchanged since blessing", vim.log.levels.INFO)
      return
    end

    -- Open side-by-side diff: blessed version vs current branch version
    vim.cmd("tabnew")

    -- Left: file at blessed blob hash (content hash, not commit SHA)
    local left_content = vim.fn.systemlist(string.format("git cat-file blob %s 2>/dev/null", bsha))
    local left_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_content)
    vim.api.nvim_buf_set_option(left_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(left_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(left_buf, "bufhidden", "wipe")
    local ext = filepath:match("%.(%w+)$") or ""
    if ext ~= "" then vim.api.nvim_buf_set_option(left_buf, "filetype", ext) end
    vim.api.nvim_buf_set_name(left_buf, string.format("%s (blessed %s)", filepath, bsha:sub(1, 8)))
    vim.cmd("diffthis")

    -- Right: file at current branch tip
    vim.cmd("vsplit")
    local right_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, right_buf)
    local right_content = vim.fn.systemlist(string.format("git show %s:%s 2>/dev/null", item.branch, filepath))
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_content)
    vim.api.nvim_buf_set_option(right_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(right_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(right_buf, "bufhidden", "wipe")
    if ext ~= "" then vim.api.nvim_buf_set_option(right_buf, "filetype", ext) end
    vim.api.nvim_buf_set_name(right_buf, string.format("%s @ %s (current)", filepath, item.branch))
    vim.cmd("diffthis")

    -- q closes the tab from either buffer
    for _, b in ipairs({ left_buf, right_buf }) do
      vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = b, desc = "Close delta tab" })
    end
  end, { desc = "Show delta since blessed" })

  vim.keymap.set("n", "<leader>sb", function()
    local item = chain[current_idx]
    if not item then return end

    -- If in a diffview diff buffer, bless just that file
    local filepath = get_diffview_filepath()
    if filepath then
      blessed.bless_file(item.branch, filepath)
      update_panel()
      refresh_diffview_panel()
      return
    end

    -- Otherwise bless all files on the branch
    if item.parent then
      blessed.bless_branch(item.branch, item.parent)
      update_panel()
      refresh_diffview_panel()
    end
  end, { desc = "Bless current file or branch" })

  vim.keymap.set("n", "<leader>sB", function()
    local item = chain[current_idx]
    if item and item.parent then
      blessed.bless_branch(item.branch, item.parent)
      update_panel()
      refresh_diffview_panel()
    end
  end, { desc = "Bless all files on current branch" })

  -- Jump to next/prev unblessed or stale file in the diffview panel
  local function jump_unreviewed(direction)
    local item = chain[current_idx]
    if not item then return end

    local ok, lib = pcall(require, "diffview.lib")
    if not ok then return end
    local view = lib.get_current_view()
    if not view or not view.panel then return end

    local files = view.panel:ordered_file_list()
    if not files or #files == 0 then return end

    -- Find current file index
    local cur_idx = 0
    local cur_file = view.panel.cur_file
    if cur_file then
      for i, f in ipairs(files) do
        if f == cur_file then
          cur_idx = i
          break
        end
      end
    end

    -- Search in direction, wrapping around
    local len = #files
    for offset = 1, len do
      local i
      if direction == "next" then
        i = (cur_idx + offset - 1) % len + 1
      else
        i = (cur_idx - offset - 1) % len + 1
      end
      local f = files[i]
      local status = blessed.file_status(item.branch, f.path)
      if status ~= "clean" then
        view:set_file(f, false, true)
        local label = status == "stale" and "stale" or "unreviewed"
        vim.notify(string.format("[%d/%d] %s (%s)", i, len, f.path, label), vim.log.levels.INFO)
        return
      end
    end
    vim.notify("All files reviewed", vim.log.levels.INFO)
  end

  vim.keymap.set("n", "]u", function() jump_unreviewed("next") end, { desc = "Next unreviewed file" })
  vim.keymap.set("n", "[u", function() jump_unreviewed("prev") end, { desc = "Prev unreviewed file" })

  vim.keymap.set("n", "gr", function()
    blessed.invalidate()
    blessed.load()
    blessed.warm_file_counts(chain)
    blessed.warm_tips(vim.tbl_map(function(item) return item.branch end, chain))
    open_review(current_idx)
    vim.notify("Refreshed", vim.log.levels.INFO)
  end, { desc = "Refresh stack review" })

  vim.keymap.set("n", "gy", function()
    local item = chain[current_idx]
    if not item then return end

    local filepath = get_diffview_filepath()
    if filepath then
      local ref = item.branch .. ":" .. filepath
      vim.fn.setreg("+", ref)
      vim.notify("Copied: " .. ref, vim.log.levels.INFO)
    else
      vim.fn.setreg("+", item.branch)
      vim.notify("Copied: " .. item.branch, vim.log.levels.INFO)
    end
  end, { desc = "Copy branch:file ref to clipboard" })

  vim.keymap.set("n", "g?", function()
    vim.notify([[
Stack Review Keybindings:
  ]b / [b       next/prev branch
  ]u / [u       next/prev unreviewed file
  <leader>e     focus file panel
  <leader>E     focus branch panel
  <leader>sp    toggle stack panel
  <leader>sc    show churn details
  <leader>sb    bless file (in diff) or all files (elsewhere)
  <leader>sB    bless all files on current branch
  go            open file in new tab (with LSP)
  gd            show delta since blessed (new tab)
  gy            copy branch:file ref to clipboard
  gr            refresh (after sync/rebase)

  Panel keybindings:
  <CR>          jump to branch
  j / k         move cursor
  x             bless all files on branch
  X             unbless branch
  s             show file review status
  q             quit

  Blessed = "I reviewed this file's content" (survives rebases)
  ✓ = all clean  · = partially reviewed  ! = stale files
]], vim.log.levels.INFO)
  end, { desc = "Stack review help" })

  -- Open panel after a short delay
  vim.defer_fn(M.open_panel, 200)
end

return M
