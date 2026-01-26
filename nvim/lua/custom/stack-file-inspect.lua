-- Stack File Inspect
-- 3-panel view for tracing a file's evolution through the stack
-- Left: branch list, Middle: file @ parent, Right: diff

local M = {}

-- Get git root
local function get_git_root()
  local result = vim.fn.systemlist('git rev-parse --show-toplevel')[1]
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- Get repo name from git root
local function get_repo_name()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end
  return vim.fn.fnamemodify(git_root, ':t')
end

-- Read stack file to get branch list and parent relationships
local function read_stack_file()
  local repo_name = get_repo_name()
  if not repo_name then
    return {}, {}
  end

  local stack_path = vim.fn.expand('~/.local/share/stack/' .. repo_name .. '/stack')
  local file = io.open(stack_path, 'r')
  if not file then
    return {}, {}
  end

  local branches = {}
  local parents = {}
  for line in file:lines() do
    local child, parent = line:match('^([^:]+):(.+)$')
    if child and parent then
      table.insert(branches, child)
      parents[child] = parent
    end
  end
  file:close()

  return branches, parents
end

-- Get file content at a specific branch
local function get_file_at_branch(branch, filepath)
  local cmd = string.format('git show %s:"%s" 2>/dev/null', branch, filepath)
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return output
end

-- Get diff between parent and branch for a file
local function get_file_diff(parent, branch, filepath)
  local cmd = string.format('git diff -w %s..%s -- "%s" 2>/dev/null', parent, branch, filepath)
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return ''
  end
  return output
end

-- Calculate depth of branch (distance from main)
local function get_depth(branch, parents)
  local depth = 0
  local current = branch
  while current and current ~= 'main' do
    depth = depth + 1
    current = parents[current]
  end
  return depth
end

-- Collect branches that modify the file
local function collect_file_changes(filepath, branches, parents)
  local changes = {}

  for _, branch in ipairs(branches) do
    local parent = parents[branch]
    local content = get_file_at_branch(branch, filepath)
    local parent_content = parent and get_file_at_branch(parent, filepath) or nil

    -- Skip if file doesn't exist in either
    if content == nil and parent_content == nil then
      goto continue
    end

    -- Skip if content is identical
    if content == parent_content then
      goto continue
    end

    local status
    if content == nil and parent_content ~= nil then
      status = 'DELETED'
    elseif content ~= nil and parent_content == nil then
      status = 'CREATED'
    else
      status = 'modified'
    end

    -- Get diff stats
    local stats = ''
    local additions = 0
    local deletions = 0
    if parent then
      local stat_output = vim.fn.system(string.format(
        'git diff -w --stat %s..%s -- "%s" 2>/dev/null', parent, branch, filepath))
      local adds, dels = stat_output:match('(%d+) insertion'), stat_output:match('(%d+) deletion')
      additions = tonumber(adds) or 0
      deletions = tonumber(dels) or 0
      if additions > 0 or deletions > 0 then
        stats = string.format('+%d -%d', additions, deletions)
      end
    end

    table.insert(changes, {
      branch = branch,
      parent = parent,
      status = status,
      stats = stats,
      additions = additions,
      deletions = deletions,
      has_deletions = deletions > 0,
      depth = get_depth(branch, parents),
    })

    ::continue::
  end

  -- Sort by depth (earliest first)
  table.sort(changes, function(a, b)
    return a.depth < b.depth
  end)

  return changes
end

-- Extract clean file path from various buffer name formats
local function extract_filepath(raw_path)
  -- Debug: uncomment to see what path we're getting
  -- vim.notify('Raw path: ' .. (raw_path or 'nil'), vim.log.levels.INFO)

  -- Handle empty or special buffers
  if raw_path == '' or raw_path:match('^diffview://') or raw_path:match('^%[') then
    return nil
  end

  -- Handle fugitive paths: "fugitive:///path/.git//abc123:lib/goals/access.ts"
  local fugitive_path = raw_path:match('fugitive://.-%.git//%x+:(.+)$')
  if fugitive_path then
    return fugitive_path
  end

  -- Handle diffview file paths: might have .git//hash: prefix
  local git_path = raw_path:match('%.git//%x+:(.+)$')
  if git_path then
    return git_path
  end

  -- Handle absolute paths - make relative to git root
  if raw_path:match('^/') then
    local git_root = vim.fn.systemlist('git rev-parse --show-toplevel')[1]
    if git_root and raw_path:find(git_root, 1, true) then
      return raw_path:sub(#git_root + 2)  -- +2 for trailing slash
    end
  end

  -- Already a relative path
  return raw_path
end

-- Main inspect function
function M.inspect(filepath)
  local raw = filepath or vim.fn.expand('%:.')

  -- Try to extract from current buffer first
  filepath = extract_filepath(raw)

  -- If that didn't work, try to get it from diffview
  if not filepath and pcall(require, 'diffview.lib') then
    local ok, lib = pcall(require, 'diffview.lib')
    if ok then
      local view = lib.get_current_view()
      if view then
        local file = view:infer_cur_file()
        if file and file.path then
          filepath = file.path
        end
      end
    end
  end

  if not filepath or filepath == '' then
    vim.notify('No file to inspect', vim.log.levels.WARN)
    return
  end

  local branches, parents = read_stack_file()
  if #branches == 0 then
    vim.notify('Not in a stack', vim.log.levels.WARN)
    return
  end

  local changes = collect_file_changes(filepath, branches, parents)
  if #changes == 0 then
    vim.notify('File not modified in any branch', vim.log.levels.INFO)
    return
  end

  local filename = vim.fn.fnamemodify(filepath, ':t')
  local filetype = vim.filetype.match({ filename = filepath }) or ''

  -- Create inspect state
  local inspect = {
    filepath = filepath,
    filename = filename,
    filetype = filetype,
    changes = changes,
    selected = 1,
    list_buf = nil,
    list_win = nil,
    parent_buf = nil,
    parent_win = nil,
    diff_buf = nil,
    diff_win = nil,
  }

  -- Build branch list content
  local function build_list_lines()
    local lines = {}
    local line_info = {}  -- track which lines have deletions for highlighting

    table.insert(lines, ' INSPECT: ' .. filename)
    table.insert(lines, ' ' .. filepath)
    table.insert(lines, string.rep('─', 30))

    for i, change in ipairs(inspect.changes) do
      local marker = (i == inspect.selected) and '▸' or ' '
      local prefix = ''
      local status_icon = ''

      -- Show warning for branches with deletions (needs review)
      if change.has_deletions then
        prefix = '⚠️'
      elseif change.status == 'CREATED' then
        prefix = '✨'
        status_icon = ' [NEW]'
      elseif change.status == 'DELETED' then
        prefix = '🗑️'
        status_icon = ' [DEL]'
      else
        prefix = '  '  -- spacing for alignment
      end

      local line = string.format('%s%s %s%s', prefix, marker, change.branch, status_icon)
      if change.stats ~= '' then
        line = line .. '  ' .. change.stats
      end
      table.insert(lines, line)
      line_info[#lines] = { has_deletions = change.has_deletions, is_selected = (i == inspect.selected) }
    end

    table.insert(lines, string.rep('─', 30))
    table.insert(lines, ' <Tab>/<S-Tab> navigate')
    table.insert(lines, ' r  mark reviewed')
    table.insert(lines, ' q  close')

    return lines, line_info
  end

  -- Render the branch list
  local function render_list()
    if not inspect.list_buf or not vim.api.nvim_buf_is_valid(inspect.list_buf) then
      return
    end
    local lines, line_info = build_list_lines()

    vim.bo[inspect.list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(inspect.list_buf, 0, -1, false, lines)
    vim.bo[inspect.list_buf].modifiable = false

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace('stack_file_inspect')
    vim.api.nvim_buf_clear_namespace(inspect.list_buf, ns, 0, -1)

    -- Header highlight
    vim.api.nvim_buf_add_highlight(inspect.list_buf, ns, 'Title', 0, 0, -1)
    vim.api.nvim_buf_add_highlight(inspect.list_buf, ns, 'Comment', 1, 0, -1)

    -- Highlight branch lines based on deletion status
    for line_num, info in pairs(line_info) do
      if info.has_deletions then
        -- Branches with deletions get warning highlight
        vim.api.nvim_buf_add_highlight(inspect.list_buf, ns, 'WarningMsg', line_num - 1, 0, -1)
      elseif info.is_selected then
        vim.api.nvim_buf_add_highlight(inspect.list_buf, ns, 'CursorLine', line_num - 1, 0, -1)
      end
    end
  end

  -- Render the parent file content
  local function render_parent()
    if not inspect.parent_buf or not vim.api.nvim_buf_is_valid(inspect.parent_buf) then
      return
    end

    local change = inspect.changes[inspect.selected]
    if not change then
      return
    end

    -- Show file content at parent branch (empty if file doesn't exist)
    local content = ''
    if change.parent then
      content = get_file_at_branch(change.parent, filepath) or ''
    end

    local lines = vim.split(content, '\n')

    vim.bo[inspect.parent_buf].modifiable = true
    vim.api.nvim_buf_set_lines(inspect.parent_buf, 0, -1, false, lines)
    vim.bo[inspect.parent_buf].modifiable = false

    -- Set filetype for syntax highlighting
    if filetype ~= '' then
      vim.bo[inspect.parent_buf].filetype = filetype
    end
  end

  -- Render the current branch file (for side-by-side diff)
  local function render_diff()
    if not inspect.diff_buf or not vim.api.nvim_buf_is_valid(inspect.diff_buf) then
      return
    end

    local change = inspect.changes[inspect.selected]
    if not change then
      return
    end

    -- Show file content at the current branch (not raw diff)
    local content = get_file_at_branch(change.branch, filepath) or ''
    local lines = vim.split(content, '\n')

    vim.bo[inspect.diff_buf].modifiable = true
    vim.api.nvim_buf_set_lines(inspect.diff_buf, 0, -1, false, lines)
    vim.bo[inspect.diff_buf].modifiable = false

    -- Set filetype for syntax highlighting
    if filetype ~= '' then
      vim.bo[inspect.diff_buf].filetype = filetype
    end
  end

  -- Enable diff mode on parent and current branch windows
  local function enable_diff_mode()
    local change = inspect.changes[inspect.selected]
    if not change then return end

    -- Disable diff first to reset state
    if inspect.parent_win and vim.api.nvim_win_is_valid(inspect.parent_win) then
      vim.api.nvim_win_call(inspect.parent_win, function()
        vim.cmd('diffoff')
      end)
    end
    if inspect.diff_win and vim.api.nvim_win_is_valid(inspect.diff_win) then
      vim.api.nvim_win_call(inspect.diff_win, function()
        vim.cmd('diffoff')
      end)
    end

    -- Set winbar labels to show which branch is which
    local parent_label = change.parent and ('BEFORE: ' .. change.parent:gsub('goals%-v1%-', '')) or '(file not created yet)'
    local current_label = 'AFTER: ' .. change.branch:gsub('goals%-v1%-', '')

    if inspect.parent_win and vim.api.nvim_win_is_valid(inspect.parent_win) then
      vim.wo[inspect.parent_win].winbar = ' ' .. parent_label
    end
    if inspect.diff_win and vim.api.nvim_win_is_valid(inspect.diff_win) then
      vim.wo[inspect.diff_win].winbar = ' ' .. current_label
    end

    -- Enable diff mode on both windows
    vim.defer_fn(function()
      if inspect.parent_win and vim.api.nvim_win_is_valid(inspect.parent_win) then
        vim.api.nvim_win_call(inspect.parent_win, function()
          vim.cmd('diffthis')
        end)
      end
      if inspect.diff_win and vim.api.nvim_win_is_valid(inspect.diff_win) then
        vim.api.nvim_win_call(inspect.diff_win, function()
          vim.cmd('diffthis')
        end)
      end
    end, 10)
  end

  -- Update selection
  local function update_selection(new_idx)
    if new_idx < 1 then
      new_idx = #inspect.changes
    end
    if new_idx > #inspect.changes then
      new_idx = 1
    end
    inspect.selected = new_idx
    render_list()
    render_parent()
    render_diff()
    enable_diff_mode()
  end

  -- Close the inspect view
  local function close_inspect()
    vim.cmd('tabclose')
  end

  -- Create buffers
  inspect.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[inspect.list_buf].buftype = 'nofile'
  vim.bo[inspect.list_buf].bufhidden = 'wipe'
  vim.bo[inspect.list_buf].swapfile = false

  inspect.parent_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[inspect.parent_buf].buftype = 'nofile'
  vim.bo[inspect.parent_buf].bufhidden = 'wipe'
  vim.bo[inspect.parent_buf].swapfile = false

  inspect.diff_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[inspect.diff_buf].buftype = 'nofile'
  vim.bo[inspect.diff_buf].bufhidden = 'wipe'
  vim.bo[inspect.diff_buf].swapfile = false
  vim.bo[inspect.diff_buf].filetype = 'diff'

  -- Create layout in new tab
  vim.cmd('tabnew')

  -- Start with diff on the right
  inspect.diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(inspect.diff_win, inspect.diff_buf)

  -- Create parent window in the middle
  vim.cmd('leftabove vsplit')
  inspect.parent_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(inspect.parent_win, inspect.parent_buf)

  -- Create list window on the left (narrowest)
  vim.cmd('leftabove 32vsplit')
  inspect.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(inspect.list_win, inspect.list_buf)

  -- Window options
  vim.wo[inspect.list_win].number = false
  vim.wo[inspect.list_win].relativenumber = false
  vim.wo[inspect.list_win].signcolumn = 'no'
  vim.wo[inspect.list_win].cursorline = true
  vim.wo[inspect.list_win].winfixwidth = true
  vim.wo[inspect.list_win].wrap = false

  vim.wo[inspect.parent_win].number = true
  vim.wo[inspect.parent_win].signcolumn = 'no'
  vim.wo[inspect.parent_win].wrap = false
  vim.wo[inspect.parent_win].scrollbind = false  -- Will be set by diffthis

  vim.wo[inspect.diff_win].number = true
  vim.wo[inspect.diff_win].signcolumn = 'no'
  vim.wo[inspect.diff_win].wrap = false
  vim.wo[inspect.diff_win].scrollbind = false  -- Will be set by diffthis

  -- Initial render
  render_list()
  render_parent()
  render_diff()
  enable_diff_mode()

  -- Focus the list
  vim.api.nvim_set_current_win(inspect.list_win)

  -- Keymaps for navigation (work from any window in the tab)
  local function setup_keymaps(buf)
    local opts = { buffer = buf, silent = true }

    vim.keymap.set('n', '<Tab>', function()
      update_selection(inspect.selected + 1)
    end, opts)

    vim.keymap.set('n', '<S-Tab>', function()
      update_selection(inspect.selected - 1)
    end, opts)

    vim.keymap.set('n', 'j', function()
      update_selection(inspect.selected + 1)
    end, opts)

    vim.keymap.set('n', 'k', function()
      update_selection(inspect.selected - 1)
    end, opts)

    vim.keymap.set('n', 'q', close_inspect, opts)
    vim.keymap.set('n', '<Esc>', close_inspect, opts)

    vim.keymap.set('n', 'r', function()
      local state = require('custom.stack-review-state')
      local panel = require('custom.stack-review-panel')
      state.mark_reviewed(filepath, true)
      vim.notify('Reviewed: ' .. filename, vim.log.levels.INFO)
      close_inspect()
      if panel.is_open() then
        panel.refresh_data()
        panel.render()
      end
    end, opts)

    -- Scroll parent window
    vim.keymap.set('n', '<C-d>', function()
      if inspect.parent_win and vim.api.nvim_win_is_valid(inspect.parent_win) then
        vim.api.nvim_win_call(inspect.parent_win, function()
          vim.cmd('normal! ' .. math.floor(vim.api.nvim_win_get_height(inspect.parent_win) / 2) .. 'j')
        end)
      end
    end, opts)

    vim.keymap.set('n', '<C-u>', function()
      if inspect.parent_win and vim.api.nvim_win_is_valid(inspect.parent_win) then
        vim.api.nvim_win_call(inspect.parent_win, function()
          vim.cmd('normal! ' .. math.floor(vim.api.nvim_win_get_height(inspect.parent_win) / 2) .. 'k')
        end)
      end
    end, opts)
  end

  -- Set up keymaps on all buffers
  setup_keymaps(inspect.list_buf)
  setup_keymaps(inspect.parent_buf)
  setup_keymaps(inspect.diff_buf)
end

-- List files that have deletions downstream (drift files)
function M.list_drift_files()
  local branches, parents = read_stack_file()
  if #branches == 0 then
    vim.notify('Not in a stack', vim.log.levels.WARN)
    return
  end

  -- Get all files that changed in any branch
  local all_files = {}
  for _, branch in ipairs(branches) do
    local parent = parents[branch]
    if parent then
      local cmd = string.format('git diff --name-only %s..%s 2>/dev/null', parent, branch)
      local output = vim.fn.systemlist(cmd)
      for _, filepath in ipairs(output) do
        if filepath ~= '' then
          all_files[filepath] = true
        end
      end
    end
  end

  -- Check each file for drift (deletions in later branches)
  local drift_files = {}
  for filepath, _ in pairs(all_files) do
    local changes = collect_file_changes(filepath, branches, parents)
    for _, change in ipairs(changes) do
      if change.has_deletions then
        table.insert(drift_files, {
          path = filepath,
          branch = change.branch,
          deletions = change.deletions,
        })
        break  -- Only need to know it has drift, not all instances
      end
    end
  end

  if #drift_files == 0 then
    vim.notify('No files with downstream drift', vim.log.levels.INFO)
    return
  end

  -- Sort by deletions (most first)
  table.sort(drift_files, function(a, b)
    return a.deletions > b.deletions
  end)

  -- Display in quickfix
  local qf_items = {}
  for _, f in ipairs(drift_files) do
    table.insert(qf_items, {
      filename = f.path,
      text = string.format('⚠️ -%d lines in %s', f.deletions, f.branch),
    })
  end

  vim.fn.setqflist(qf_items)
  vim.cmd('copen')
  vim.notify(string.format('%d files with drift', #drift_files), vim.log.levels.INFO)
end

-- Setup function
function M.setup()
  -- Global keymap for inspect file
  vim.keymap.set('n', '<leader>if', function()
    M.inspect()
  end, { desc = 'Stack: Inspect file evolution' })

  -- Commands
  vim.api.nvim_create_user_command('StackInspect', function(opts)
    M.inspect(opts.args ~= '' and opts.args or nil)
  end, { desc = 'Inspect file evolution through stack', nargs = '?' })

  vim.api.nvim_create_user_command('StackDriftFiles', function()
    M.list_drift_files()
  end, { desc = 'List files with downstream drift (deletions)' })
end

return M
