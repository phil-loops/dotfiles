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

-- Trace file through stack - one scrollable buffer with all diffs
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

    table.insert(changes, {
      branch = branch,
      parent = parent,
      status = status,
    })

    ::continue::
  end

  if #changes == 0 then
    vim.notify('File not modified in any branch', vim.log.levels.INFO)
    return
  end

  -- Build one buffer with ALL diffs concatenated
  local lines = {}
  local filename = vim.fn.fnamemodify(filepath, ':t')
  local sep = string.rep('=', 70)

  table.insert(lines, sep)
  table.insert(lines, string.format('  FILE HISTORY: %s', filepath))
  table.insert(lines, string.format('  %d changes  |  Y = copy path  |  r = reviewed  |  q = close', #changes))
  table.insert(lines, sep)
  table.insert(lines, '')

  for i, change in ipairs(changes) do
    -- Section header
    local header = string.format('[ %d/%d ] %s', i, #changes, change.branch)
    if change.status == 'CREATED' then
      header = header .. '  ** FILE CREATED **'
    elseif change.status == 'DELETED' then
      header = header .. '  ** FILE DELETED **'
    end

    table.insert(lines, string.rep('-', 70))
    table.insert(lines, header)
    table.insert(lines, string.rep('-', 70))

    -- Get the diff
    if change.parent then
      local diff = vim.fn.system(string.format('git diff %s..%s -- "%s" 2>/dev/null', change.parent, change.branch, filepath))
      -- Skip the diff header lines (a/b paths), keep the interesting part
      local diff_lines = vim.split(diff, '\n')
      local in_content = false
      for _, line in ipairs(diff_lines) do
        if line:match('^@@') then
          in_content = true
        end
        if in_content then
          table.insert(lines, line)
        end
      end
    else
      -- No parent = file created, show the content
      local content = get_file_at_branch(change.branch)
      if content then
        for _, line in ipairs(vim.split(content, '\n')) do
          table.insert(lines, '+ ' .. line)
        end
      end
    end

    table.insert(lines, '')
  end

  table.insert(lines, sep)
  table.insert(lines, '  END OF HISTORY')
  table.insert(lines, sep)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'diff'

  -- Open in a new tab for full screen scrolling
  vim.cmd('tabnew')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- Keymaps
  local opts = { buffer = buf, silent = true }

  vim.keymap.set('n', 'q', function()
    vim.cmd('tabclose')
  end, opts)

  vim.keymap.set('n', 'r', function()
    local state = require('custom.stack-review-state')
    local panel = require('custom.stack-review-panel')
    state.mark_reviewed(filepath, true)
    vim.notify('Reviewed: ' .. filename, vim.log.levels.INFO)
    vim.cmd('tabclose')
    if panel.is_open() then
      panel.refresh_data()
      panel.render()
    end
  end, opts)

  -- Yank filepath to clipboard
  vim.keymap.set('n', 'Y', function()
    vim.fn.setreg('+', filepath)
    vim.notify('Copied: ' .. filepath, vim.log.levels.INFO)
  end, opts)
end

-- Setup commands
function M.setup()
  vim.api.nvim_create_user_command('StackTrace', function(opts)
    M.trace(opts.args ~= '' and opts.args or nil)
  end, { desc = 'Trace file evolution through stack', nargs = '?' })
end

return M
