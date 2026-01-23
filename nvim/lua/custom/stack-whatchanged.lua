-- Stack whatchanged integration for neovim
-- Shows files changed since last review, integrates with telescope

local M = {}

-- Parse output of `loops stack whatchanged --files`
local function parse_whatchanged()
  local output = vim.fn.systemlist('loops stack whatchanged --files 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return nil, 'Not in a stack or no baseline set'
  end

  local results = {
    last_reviewed = nil,
    branches = {},
    all_files = {},
  }

  local current_branch = nil

  for _, line in ipairs(output) do
    -- Parse "Last reviewed: <timestamp>"
    local timestamp = line:match('^Last reviewed: (.+)$')
    if timestamp then
      results.last_reviewed = timestamp
    end

    -- Parse "branch-name: oldsha -> newsha"
    local branch = line:match('^([%w%-_/]+): %w+ %-> %w+$')
    if branch then
      current_branch = branch
      results.branches[branch] = {}
    end

    -- Parse "  filename" (indented file under a branch)
    local file = line:match('^  ([%S]+)$')
    if file and current_branch then
      table.insert(results.branches[current_branch], file)
      results.all_files[file] = results.all_files[file] or {}
      table.insert(results.all_files[file], current_branch)
    end
  end

  return results
end

-- Get diff for a specific file
local function get_file_diff(filepath)
  local cmd = string.format('loops stack whatchanged --show "%s" 2>/dev/null', filepath)
  local output = vim.fn.system(cmd)
  return output
end

-- Open telescope picker with changed files
function M.telescope_picker()
  local ok, telescope = pcall(require, 'telescope')
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

  -- Build entries: file + which branches it changed in
  local entries = {}
  for file, branches in pairs(results.all_files) do
    table.insert(entries, {
      file = file,
      branches = branches,
      display = string.format('%s  (%s)', file, table.concat(branches, ', ')),
    })
  end

  -- Sort by filename
  table.sort(entries, function(a, b)
    return a.file < b.file
  end)

  pickers.new({}, {
    prompt_title = 'Stack Changed Files (' .. (results.last_reviewed or 'unknown') .. ')',
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
        local diff = get_file_diff(entry.value.file)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(diff, '\n'))
        vim.bo[self.state.bufnr].filetype = 'diff'
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

      -- <C-d> to open diffview for this file
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

-- Acknowledge changes
function M.ack()
  local output = vim.fn.system('loops stack whatchanged --ack 2>&1')
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
