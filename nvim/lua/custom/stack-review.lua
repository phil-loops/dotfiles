-- Stack Review Coordinator
-- Main entry point for the unified stack review experience

local M = {}

local state = require('custom.stack-review-state')
local panel = require('custom.stack-review-panel')

-- Session state
local session = {
  active = false,
  diffview_open = false,
}

-- Open diffview for a specific branch's changes
local function open_branch_diff(branch)
  local info = panel.get_branch_info(branch)
  if not info then
    return
  end

  -- Close existing diffview if open
  if session.diffview_open then
    pcall(vim.cmd, 'DiffviewClose')
    session.diffview_open = false
  end

  -- Open diffview comparing parent to branch (shows only branch-specific changes)
  local parent = info.parent or 'main'
  local cmd = string.format('DiffviewOpen %s..%s', parent, info.name)
  vim.cmd(cmd)
  session.diffview_open = true
end

-- Open diff for selected file
local function open_file_diff()
  local filepath, branch = panel.get_selected()
  if not filepath or not branch then
    return
  end

  local info = panel.get_branch_info(branch)
  if not info then
    return
  end

  -- Close existing diffview if open
  if session.diffview_open then
    pcall(vim.cmd, 'DiffviewClose')
  end

  -- Open diffview comparing parent to branch, focused on file
  local parent = info.parent or 'main'
  local cmd = string.format('DiffviewOpen %s..%s -- %s', parent, info.name, filepath)
  vim.cmd(cmd)
  session.diffview_open = true
end

-- Set up keymaps for the review session
local function setup_keymaps()
  local opts = { silent = true }

  -- Global keymaps for review session (leader-s prefix)
  vim.keymap.set('n', '<leader>sr', function()
    if panel.is_open() then
      panel.toggle_reviewed()
    end
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Toggle reviewed' }))

  vim.keymap.set('n', '<leader>sn', function()
    if panel.is_open() then
      panel.add_note()
    end
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Add note' }))

  vim.keymap.set('n', '<leader>st', function()
    local filepath = panel.get_selected()
    if filepath then
      -- Use the trace function from stack-whatchanged
      local stack_whatchanged = require('custom.stack-whatchanged')
      vim.cmd('tabnew')
      stack_whatchanged.trace(filepath)
    end
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Trace file' }))

  vim.keymap.set('n', '<leader>ss', function()
    M.show_progress()
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Show progress' }))

  vim.keymap.set('n', '<leader>sa', function()
    M.complete()
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Complete (ack)' }))

  vim.keymap.set('n', '<leader>sq', function()
    M.quit()
  end, vim.tbl_extend('force', opts, { desc = 'Stack Review: Quit (preserve)' }))

  -- Panel-specific keymaps (CR to trace file through stack)
  if panel.get_buf() then
    vim.keymap.set('n', '<CR>', function()
      local filepath = panel.get_selected()
      if filepath then
        local stack_whatchanged = require('custom.stack-whatchanged')
        stack_whatchanged.trace(filepath)
      end
    end, { buffer = panel.get_buf(), silent = true, desc = 'Trace file' })

    vim.keymap.set('n', 'd', function()
      open_file_diff()
    end, { buffer = panel.get_buf(), silent = true, desc = 'View diff' })

    vim.keymap.set('n', 'q', function()
      M.quit()
    end, { buffer = panel.get_buf(), silent = true, desc = 'Quit review' })

    vim.keymap.set('n', 'a', function()
      M.complete()
    end, { buffer = panel.get_buf(), silent = true, desc = 'Complete review' })

    vim.keymap.set('n', 't', function()
      local filepath = panel.get_selected()
      if filepath then
        local stack_whatchanged = require('custom.stack-whatchanged')
        vim.cmd('tabnew')
        stack_whatchanged.trace(filepath)
      end
    end, { buffer = panel.get_buf(), silent = true, desc = 'Trace file' })
  end
end

-- Show progress summary
function M.show_progress()
  local progress = state.get_progress()
  local changes = state.get_changed_files_by_branch()

  local lines = {
    'Stack Review Progress',
    string.format('━━━━━━━━━━━━━━━━━━━━━'),
    '',
    string.format('Files: %d/%d reviewed (%d%%)', progress.reviewed, progress.total, progress.percent),
    '',
  }

  if changes and changes.ordered_branches then
    table.insert(lines, 'Branches with changes:')
    for _, branch in ipairs(changes.ordered_branches) do
      local branch_info = changes.branches[branch]
      local file_count = branch_info and #branch_info.files or 0
      local reviewed_count = 0
      if branch_info then
        for _, filepath in ipairs(branch_info.files) do
          if state.is_reviewed(filepath) then
            reviewed_count = reviewed_count + 1
          end
        end
      end
      local icon = (reviewed_count == file_count) and '+' or '.'
      table.insert(lines, string.format('  %s %s (%d/%d)', icon, branch, reviewed_count, file_count))
    end
  end

  -- Display in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = 50
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = (vim.o.lines - height) / 2,
    col = (vim.o.columns - width) / 2,
    style = 'minimal',
    border = 'rounded',
    title = ' Progress ',
    title_pos = 'center',
  })

  vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set('n', '<Esc>', function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
end

-- Start or resume review session
function M.open()
  -- If panel is already open, just focus it
  if panel.is_open() then
    panel.focus()
    return
  end

  -- Reset session state (in case it's stale from previous vim session)
  session.active = false
  session.diffview_open = false

  -- Check for existing session
  local has_session = state.has_active_session()

  if has_session then
    -- Resume existing session
    state.load()
    vim.notify('Resuming stack review session', vim.log.levels.INFO)
  else
    -- Check if there are any changes to review
    local changes = state.get_changed_files_by_branch()

    -- If no state yet, try starting a new review
    if not changes then
      local new_state, err = state.start_review()
      if not new_state then
        vim.notify(err or 'Failed to start review', vim.log.levels.WARN)
        return
      end
      changes = state.get_changed_files_by_branch()
    end

    if not changes or vim.tbl_isempty(changes.file_info) then
      vim.notify('No changes to review', vim.log.levels.INFO)
      return
    end

    vim.notify('Starting stack review session', vim.log.levels.INFO)
  end

  -- Open the panel
  panel.open()
  session.active = true

  -- Set up keymaps
  setup_keymaps()
end

-- Quit without completing (preserves state)
function M.quit()
  if session.diffview_open then
    pcall(vim.cmd, 'DiffviewClose')
    session.diffview_open = false
  end

  panel.close()
  session.active = false

  vim.notify('Review session paused (progress saved)', vim.log.levels.INFO)
end

-- Complete review (ack changes)
function M.complete()
  local progress = state.get_progress()

  if progress.reviewed < progress.total then
    -- Prompt for confirmation
    local msg = string.format(
      'Only %d/%d files reviewed. Complete anyway?',
      progress.reviewed,
      progress.total
    )
    vim.ui.select({ 'No, continue reviewing', 'Yes, complete review' }, {
      prompt = msg,
    }, function(choice)
      if choice == 'Yes, complete review' then
        M.force_complete()
      end
    end)
  else
    M.force_complete()
  end
end

-- Force complete review
function M.force_complete()
  local ok, err = state.force_complete()
  if not ok then
    vim.notify(err or 'Failed to complete review', vim.log.levels.ERROR)
    return
  end

  if session.diffview_open then
    pcall(vim.cmd, 'DiffviewClose')
    session.diffview_open = false
  end

  panel.close()
  session.active = false

  vim.notify('Review completed! Baseline updated.', vim.log.levels.INFO)
end

-- Cancel/reset review (discard state)
function M.cancel()
  state.cancel_review()

  if session.diffview_open then
    pcall(vim.cmd, 'DiffviewClose')
    session.diffview_open = false
  end

  if panel.is_open() then
    panel.close()
  end
  session.active = false

  vim.notify('Review state cleared', vim.log.levels.INFO)
end

-- Toggle reviewed for current file (can be called from anywhere)
function M.toggle_reviewed()
  if panel.is_open() then
    return panel.toggle_reviewed()
  end

  -- If not in panel, try to mark current buffer's file
  local filepath = vim.fn.expand('%:.')
  if filepath == '' then
    vim.notify('No file to mark', vim.log.levels.WARN)
    return false
  end

  -- Check if this file is part of the review
  local changes = state.get_changed_files_by_branch()
  if not changes or not changes.file_info[filepath] then
    vim.notify('File not part of current review', vim.log.levels.WARN)
    return false
  end

  local currently_reviewed = state.is_reviewed(filepath)
  state.mark_reviewed(filepath, not currently_reviewed)

  local status = (not currently_reviewed) and 'reviewed' or 'unreviewed'
  vim.notify(string.format('%s: %s', vim.fn.fnamemodify(filepath, ':t'), status), vim.log.levels.INFO)

  if panel.is_open() then
    panel.refresh_data()
    panel.render()
  end

  return true
end

-- Check if review is active
function M.is_active()
  return session.active
end

-- Setup function (creates commands)
function M.setup()
  vim.api.nvim_create_user_command('StackReview', function()
    M.open()
  end, { desc = 'Open/resume stack review' })

  vim.api.nvim_create_user_command('StackReviewQuit', function()
    M.quit()
  end, { desc = 'Quit stack review (preserves progress)' })

  vim.api.nvim_create_user_command('StackReviewComplete', function()
    M.complete()
  end, { desc = 'Complete stack review' })

  vim.api.nvim_create_user_command('StackReviewReset', function()
    M.cancel()
  end, { desc = 'Reset stack review (clear all state)' })

  vim.api.nvim_create_user_command('StackReviewProgress', function()
    M.show_progress()
  end, { desc = 'Show review progress' })

  vim.api.nvim_create_user_command('StackReviewRefresh', function()
    state.refresh_cache()
    vim.notify('Refreshing stack review cache...', vim.log.levels.INFO)
  end, { desc = 'Force refresh cache' })

  -- Auto-refresh cache after git operations
  local refresh_group = vim.api.nvim_create_augroup('StackReviewRefresh', { clear = true })

  -- Refresh when returning to nvim after shell commands (likely git operations)
  vim.api.nvim_create_autocmd('FocusGained', {
    group = refresh_group,
    callback = function()
      -- Only refresh if we have an active session
      if state.has_active_session() then
        state.refresh_async()
      end
    end,
  })

  -- Refresh after fugitive operations
  vim.api.nvim_create_autocmd('User', {
    group = refresh_group,
    pattern = 'FugitiveChanged',
    callback = function()
      if state.has_active_session() then
        state.refresh_async()
      end
    end,
  })

  -- Pre-warm cache when entering a git repo with active session
  vim.api.nvim_create_autocmd('DirChanged', {
    group = refresh_group,
    callback = function()
      -- Check if there's an active session and pre-warm cache
      vim.defer_fn(function()
        if state.has_active_session() and not state.has_cache() then
          state.refresh_async()
        end
      end, 100)
    end,
  })
end

return M
