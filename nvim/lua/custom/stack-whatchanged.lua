-- Stack whatchanged integration for neovim
-- Shows files changed since last review, integrates with telescope

local M = {}

-- Cache for parsed data
local cache = {
  data = nil,
  time = 0,
}

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
  if not git_root then return nil end
  return vim.fn.fnamemodify(git_root, ':t')
end

-- Read and parse the ack file directly (no node needed)
local function read_ack_file()
  local repo_name = get_repo_name()
  if not repo_name then return nil end

  local ack_path = vim.fn.expand('~/.local/share/stack/' .. repo_name .. '/ack')
  local file = io.open(ack_path, 'r')
  if not file then return nil end

  local content = file:read('*all')
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok then return nil end

  return data
end

-- Read stack file to get branch list
local function read_stack_file()
  local repo_name = get_repo_name()
  if not repo_name then return {} end

  local stack_path = vim.fn.expand('~/.local/share/stack/' .. repo_name .. '/stack')
  local file = io.open(stack_path, 'r')
  if not file then return {} end

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

-- Get current hash for a branch
local function get_branch_hash(branch)
  local result = vim.fn.systemlist('git rev-parse ' .. branch .. ' 2>/dev/null')[1]
  if vim.v.shell_error ~= 0 then return nil end
  return result
end

-- Get changed files between two commits
local function get_changed_files(old_hash, new_hash)
  local cmd = string.format('git diff --name-only %s..%s 2>/dev/null', old_hash, new_hash)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return {} end
  return output
end

-- Get diff for a file between old and new hash
local function get_file_diff(filepath, old_hash, new_hash)
  local cmd = string.format('git diff %s..%s -- "%s" 2>/dev/null', old_hash, new_hash, filepath)
  local output = vim.fn.system(cmd)
  return output
end

-- Parse whatchanged (reads files directly, no node)
local function parse_whatchanged()
  -- Use cache if fresh (within 2 seconds)
  local now = vim.loop.now()
  if cache.data and (now - cache.time) < 2000 then
    return cache.data
  end

  local ack = read_ack_file()
  if not ack then
    return nil, 'No baseline set. Run :StackAck first'
  end

  local branches = read_stack_file()
  if #branches == 0 then
    return nil, 'Not in a stack'
  end

  local results = {
    last_reviewed = ack.timestamp,
    branches = {},
    all_files = {},
    -- Store hashes for diff lookup
    hashes = {},
  }

  for _, branch in ipairs(branches) do
    local old_hash = ack.branches[branch]
    if old_hash then
      local new_hash = get_branch_hash(branch)
      if new_hash and old_hash ~= new_hash and not new_hash:find('^' .. old_hash) and not old_hash:find('^' .. new_hash:sub(1,8)) then
        local files = get_changed_files(old_hash, new_hash)
        if #files > 0 then
          results.branches[branch] = files
          results.hashes[branch] = { old = old_hash, new = new_hash }
          for _, file in ipairs(files) do
            results.all_files[file] = results.all_files[file] or { branches = {}, hashes = {} }
            table.insert(results.all_files[file].branches, branch)
            results.all_files[file].hashes[branch] = { old = old_hash, new = new_hash }
          end
        end
      end
    end
  end

  cache.data = results
  cache.time = now
  return results
end

-- Open telescope picker with changed files
function M.telescope_picker()
  local ok, _ = pcall(require, 'telescope')
  if not ok then
    vim.notify('Telescope not available', vim.log.levels.ERROR)
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')

  local results, err = parse_whatchanged()
  if not results then
    vim.notify(err or 'Failed to parse whatchanged', vim.log.levels.WARN)
    return
  end

  if vim.tbl_isempty(results.all_files) then
    vim.notify('No changes since last review', vim.log.levels.INFO)
    return
  end

  -- Build entries
  local entries = {}
  for file, info in pairs(results.all_files) do
    table.insert(entries, {
      file = file,
      branches = info.branches,
      hashes = info.hashes,
      display = string.format('%s  (%d branches)', file, #info.branches),
    })
  end

  table.sort(entries, function(a, b)
    return a.file < b.file
  end)

  pickers.new({}, {
    prompt_title = 'Stack Changed (' .. (results.last_reviewed or '?') .. ')',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.file,
          path = entry.file,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = 'Diff',
      define_preview = function(self, entry, status)
        -- Get diff from first branch that changed this file
        local first_branch = entry.value.branches[1]
        local hashes = entry.value.hashes[first_branch]
        if hashes then
          local diff = get_file_diff(entry.value.file, hashes.old, hashes.new)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(diff, '\n'))
          vim.bo[self.state.bufnr].filetype = 'diff'
        end
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          vim.cmd('edit ' .. vim.fn.fnameescape(selection.value.file))
        end
      end)

      map('i', '<C-d>', function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          vim.cmd('DiffviewFileHistory ' .. vim.fn.fnameescape(selection.value.file))
        end
      end)

      map('n', '<C-d>', function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          vim.cmd('DiffviewFileHistory ' .. vim.fn.fnameescape(selection.value.file))
        end
      end)

      return true
    end,
  }):find()
end

-- Acknowledge changes (still needs node for writing)
function M.ack()
  local git_root = get_git_root()
  if not git_root then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    return
  end
  local cmd = string.format(
    'cd "%s" && node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts whatchanged --ack 2>&1',
    git_root
  )
  local output = vim.fn.system(cmd)
  cache.data = nil -- Clear cache
  vim.notify(vim.trim(output), vim.log.levels.INFO)
end

-- Show quick summary
function M.summary()
  local results, err = parse_whatchanged()
  if not results then
    vim.notify(err or 'Failed to parse', vim.log.levels.WARN)
    return
  end

  local file_count = vim.tbl_count(results.all_files)
  local branch_count = vim.tbl_count(results.branches)

  if file_count == 0 then
    vim.notify('No changes since last review', vim.log.levels.INFO)
  else
    vim.notify(
      string.format('%d files changed across %d branches', file_count, branch_count),
      vim.log.levels.INFO
    )
  end
end

-- Setup commands
function M.setup()
  vim.api.nvim_create_user_command('StackChanged', function()
    M.telescope_picker()
  end, { desc = 'Show stack changed files in telescope' })

  vim.api.nvim_create_user_command('StackAck', function()
    M.ack()
  end, { desc = 'Acknowledge stack changes' })

  vim.api.nvim_create_user_command('StackSummary', function()
    M.summary()
  end, { desc = 'Show stack change summary' })
end

return M
