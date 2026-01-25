-- Stack whatchanged integration for neovim
-- Provides trace functionality for viewing file evolution through the stack
-- The main review workflow is now handled by stack-review.lua

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

-- Read stack file to get branch list
local function read_stack_file()
  local repo_name = get_repo_name()
  if not repo_name then
    return {}
  end

  local stack_path = vim.fn.expand('~/.local/share/stack/' .. repo_name .. '/stack')
  local file = io.open(stack_path, 'r')
  if not file then
    return {}
  end

  local branches = {}
  for line in file:lines() do
    local child = line:match('^([^:]+):')
    if child then
      table.insert(branches, child)
    end
  end
  file:close()

  return branches
end

-- Trace file through stack - master/detail view
-- Left: list of branches, Right: diff updates as you navigate
function M.trace(filepath)
  filepath = filepath or vim.fn.expand('%:.')
  if filepath == '' then
    vim.notify('No file to trace', vim.log.levels.WARN)
    return
  end

  local branches = read_stack_file()
  if #branches == 0 then
    vim.notify('Not in a stack', vim.log.levels.WARN)
    return
  end

  -- Read stack to get parent relationships
  local stack = {}
  local repo_name = get_repo_name()
  local stack_path = vim.fn.expand('~/.local/share/stack/' .. repo_name .. '/stack')
  local file = io.open(stack_path, 'r')
  if file then
    for line in file:lines() do
      local child, parent = line:match('^([^:]+):(.+)$')
      if child and parent then
        stack[child] = parent
      end
    end
    file:close()
  end

  -- Get file content at each branch
  local function get_file_at_branch(branch)
    local cmd = string.format('git show %s:"%s" 2>/dev/null', branch, filepath)
    local output = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil
    end
    return output
  end

  -- Collect only branches that changed the file
  local changes = {}

  for _, branch in ipairs(branches) do
    local parent = stack[branch]
    local content = get_file_at_branch(branch)
    local parent_content = parent and get_file_at_branch(parent) or nil

    if content == nil and parent_content == nil then
      goto continue
    end

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
    if parent then
      local stat_output = vim.fn.system(string.format('git diff --stat %s..%s -- "%s" 2>/dev/null', parent, branch, filepath))
      local adds, dels = stat_output:match('(%d+) insertion'), stat_output:match('(%d+) deletion')
      if adds or dels then
        stats = string.format('+%s -%s', adds or '0', dels or '0')
      end
    end

    table.insert(changes, {
      branch = branch,
      parent = parent,
      status = status,
      stats = stats,
    })

    ::continue::
  end

  if #changes == 0 then
    vim.notify('File not modified in any branch', vim.log.levels.INFO)
    return
  end

  local filename = vim.fn.fnamemodify(filepath, ':t')

  -- Create the trace state
  local trace = {
    filepath = filepath,
    filename = filename,
    changes = changes,
    selected = 1,
    list_buf = nil,
    list_win = nil,
    diff_buf = nil,
    diff_win = nil,
  }

  -- Build the branch list content
  local function build_list_lines()
    local lines = {}
    table.insert(lines, ' TRACE: ' .. filename)
    table.insert(lines, ' ' .. filepath)
    table.insert(lines, string.rep('─', 35))

    for i, change in ipairs(trace.changes) do
      local marker = (i == trace.selected) and '>' or ' '
      local status_icon = ''
      if change.status == 'CREATED' then
        status_icon = ' [NEW]'
      elseif change.status == 'DELETED' then
        status_icon = ' [DEL]'
      end
      local line = string.format('%s %d. %s%s', marker, i, change.branch, status_icon)
      if change.stats ~= '' then
        line = line .. '  ' .. change.stats
      end
      table.insert(lines, line)
    end

    table.insert(lines, string.rep('─', 35))
    table.insert(lines, ' j/k  navigate')
    table.insert(lines, ' r    mark reviewed')
    table.insert(lines, ' q    close')

    return lines
  end

  -- Get diff for selected branch
  local function get_diff_lines()
    local change = trace.changes[trace.selected]
    if not change then return { 'No change selected' } end

    local lines = {}
    local header = string.format('── %s ──', change.branch)
    if change.status == 'CREATED' then
      header = header .. '  FILE CREATED'
    elseif change.status == 'DELETED' then
      header = header .. '  FILE DELETED'
    end
    table.insert(lines, header)
    table.insert(lines, '')

    if change.parent then
      local diff = vim.fn.system(string.format('git diff %s..%s -- "%s" 2>/dev/null', change.parent, change.branch, filepath))
      for _, line in ipairs(vim.split(diff, '\n')) do
        table.insert(lines, line)
      end
    else
      -- No parent = file created, show full content as additions
      local content = get_file_at_branch(change.branch)
      if content then
        table.insert(lines, '@@ -0,0 +1 @@ (new file)')
        for _, line in ipairs(vim.split(content, '\n')) do
          table.insert(lines, '+' .. line)
        end
      end
    end

    return lines
  end

  -- Render the list
  local function render_list()
    if not trace.list_buf or not vim.api.nvim_buf_is_valid(trace.list_buf) then return end
    vim.bo[trace.list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(trace.list_buf, 0, -1, false, build_list_lines())
    vim.bo[trace.list_buf].modifiable = false
  end

  -- Render the diff
  local function render_diff()
    if not trace.diff_buf or not vim.api.nvim_buf_is_valid(trace.diff_buf) then return end
    vim.bo[trace.diff_buf].modifiable = true
    vim.api.nvim_buf_set_lines(trace.diff_buf, 0, -1, false, get_diff_lines())
    vim.bo[trace.diff_buf].modifiable = false
  end

  -- Update selection and re-render
  local function update_selection(new_idx)
    if new_idx < 1 then new_idx = #trace.changes end
    if new_idx > #trace.changes then new_idx = 1 end
    trace.selected = new_idx
    render_list()
    render_diff()
    -- Keep cursor on the selected line in list
    if trace.list_win and vim.api.nvim_win_is_valid(trace.list_win) then
      pcall(vim.api.nvim_win_set_cursor, trace.list_win, { trace.selected + 3, 0 })  -- +3 for header lines
    end
  end

  -- Close the trace view (close the whole tab)
  local function close_trace()
    vim.cmd('tabclose')
  end

  -- Create buffers
  trace.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[trace.list_buf].buftype = 'nofile'
  vim.bo[trace.list_buf].bufhidden = 'wipe'
  vim.bo[trace.list_buf].swapfile = false

  trace.diff_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[trace.diff_buf].buftype = 'nofile'
  vim.bo[trace.diff_buf].bufhidden = 'wipe'
  vim.bo[trace.diff_buf].swapfile = false
  vim.bo[trace.diff_buf].filetype = 'diff'

  -- Open in a new tab to avoid messing with existing layout
  vim.cmd('tabnew')
  trace.diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(trace.diff_win, trace.diff_buf)

  -- Create list window on the left
  vim.cmd('topleft vertical 38split')
  trace.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(trace.list_win, trace.list_buf)
  vim.wo[trace.list_win].number = false
  vim.wo[trace.list_win].relativenumber = false
  vim.wo[trace.list_win].signcolumn = 'no'
  vim.wo[trace.list_win].cursorline = true
  vim.wo[trace.list_win].winfixwidth = true

  -- Initial render
  render_list()
  render_diff()

  -- Focus the list
  vim.api.nvim_set_current_win(trace.list_win)
  pcall(vim.api.nvim_win_set_cursor, trace.list_win, { 4, 0 })  -- First branch line

  -- Keymaps for list buffer
  local opts = { buffer = trace.list_buf, silent = true }

  vim.keymap.set('n', 'j', function() update_selection(trace.selected + 1) end, opts)
  vim.keymap.set('n', 'k', function() update_selection(trace.selected - 1) end, opts)
  vim.keymap.set('n', '<Down>', function() update_selection(trace.selected + 1) end, opts)
  vim.keymap.set('n', '<Up>', function() update_selection(trace.selected - 1) end, opts)
  vim.keymap.set('n', '<CR>', function() update_selection(trace.selected) end, opts)

  vim.keymap.set('n', 'q', close_trace, opts)
  vim.keymap.set('n', '<Esc>', close_trace, opts)

  vim.keymap.set('n', 'r', function()
    local state = require('custom.stack-review-state')
    local panel = require('custom.stack-review-panel')
    state.mark_reviewed(filepath, true)
    vim.notify('Reviewed: ' .. filename, vim.log.levels.INFO)
    close_trace()
    if panel.is_open() then
      panel.refresh_data()
      panel.render()
    end
  end, opts)

  vim.keymap.set('n', 'Y', function()
    vim.fn.setreg('+', filepath)
    vim.notify('Copied: ' .. filepath, vim.log.levels.INFO)
  end, opts)

  -- Also allow scrolling the diff from the list window
  vim.keymap.set('n', '<C-d>', function()
    if trace.diff_win and vim.api.nvim_win_is_valid(trace.diff_win) then
      local scroll = math.floor(vim.api.nvim_win_get_height(trace.diff_win) / 2)
      vim.api.nvim_win_call(trace.diff_win, function()
        vim.cmd('normal! ' .. scroll .. 'j')
      end)
    end
  end, opts)

  vim.keymap.set('n', '<C-u>', function()
    if trace.diff_win and vim.api.nvim_win_is_valid(trace.diff_win) then
      local scroll = math.floor(vim.api.nvim_win_get_height(trace.diff_win) / 2)
      vim.api.nvim_win_call(trace.diff_win, function()
        vim.cmd('normal! ' .. scroll .. 'k')
      end)
    end
  end, opts)
end

-- Setup commands
function M.setup()
  vim.api.nvim_create_user_command('StackTrace', function(opts)
    M.trace(opts.args ~= '' and opts.args or nil)
  end, { desc = 'Trace file evolution through stack', nargs = '?' })
end

return M
