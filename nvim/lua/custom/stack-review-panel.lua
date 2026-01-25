-- Stack Review Panel
-- UI panel for displaying branches and files during stack review

local M = {}
local state = require('custom.stack-review-state')

-- Panel state
local panel = {
  buf = nil,
  win = nil,
  width = 40,
  branches = {},       -- ordered list of branch names with changes
  branch_files = {},   -- branch -> list of files
  file_info = {},      -- file -> { final_branch, reviewed, ... }
  expanded = {},       -- branch -> bool (is expanded)
  cursor_branch = nil, -- currently selected branch
  cursor_file = nil,   -- currently selected file
  cursor_line = 1,     -- current line in panel
  hide_reviewed = true, -- hide reviewed files by default
  unsubscribe = nil,   -- function to unsubscribe from cache updates
  loading = false,     -- whether we're waiting for cache
}

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace('stack_review_panel')

-- Highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, 'StackReviewHeader', { fg = '#61afef', bold = true })
  vim.api.nvim_set_hl(0, 'StackReviewBranch', { fg = '#e5c07b' })
  vim.api.nvim_set_hl(0, 'StackReviewBranchActive', { fg = '#e5c07b', bold = true })
  vim.api.nvim_set_hl(0, 'StackReviewFile', { fg = '#abb2bf' })
  vim.api.nvim_set_hl(0, 'StackReviewFileReviewed', { fg = '#98c379' })
  vim.api.nvim_set_hl(0, 'StackReviewFilePending', { fg = '#e06c75' })
  vim.api.nvim_set_hl(0, 'StackReviewFinal', { fg = '#c678dd' })
  vim.api.nvim_set_hl(0, 'StackReviewLater', { fg = '#5c6370', italic = true })
  vim.api.nvim_set_hl(0, 'StackReviewNew', { fg = '#98c379', bold = true })
  vim.api.nvim_set_hl(0, 'StackReviewProgress', { fg = '#56b6c2' })
  vim.api.nvim_set_hl(0, 'StackReviewNote', { fg = '#d19a66', italic = true })
end

-- Load data from state (returns true if data available, false if loading)
function M.refresh_data()
  local changes, err = state.get_changed_files_by_branch()

  -- Check if we're still computing
  if not changes then
    panel.loading = state.is_computing()
    if panel.loading then
      panel.files = {}
      panel.file_info = {}
      return false
    end
    -- Not computing and no data - might be an error
    panel.files = {}
    panel.file_info = {}
    return false
  end

  panel.loading = false
  panel.file_info = changes.file_info
  panel.files = {}

  -- Build flat file list (deduped)
  for filepath, info in pairs(changes.file_info) do
    local branch_count = #info.branches
    local is_new = info.introduced_in ~= nil
    -- Quick scan = only appears in 1 branch (no evolution to trace)
    local is_quick_scan = branch_count == 1
    table.insert(panel.files, {
      path = filepath,
      branches = info.branches,
      branch_count = branch_count,
      is_new = is_new,
      is_quick_scan = is_quick_scan,
      first_branch = info.first_branch,
      final_branch = info.final_branch,
      introduced_in = info.introduced_in,
      reviewed = state.is_reviewed(filepath),
      note = state.get_note(filepath),
    })
  end

  -- Sort: Files that evolve (2+ branches) first, then quick scan (1 branch) at the end
  table.sort(panel.files, function(a, b)
    -- Quick scan goes to the bottom
    if a.is_quick_scan ~= b.is_quick_scan then
      return not a.is_quick_scan
    end
    -- Then sort alphabetically by filename
    return a.path < b.path
  end)

  return true
end

-- Build the line contents for the panel
local function build_lines()
  local lines = {}
  local highlights = {}
  local line_map = {}  -- line_num -> { type = "file", file = ... }

  -- Show loading state if computing
  if panel.loading then
    table.insert(lines, '  STACK REVIEW')
    table.insert(highlights, { line = #lines, col = 0, end_col = 14, hl = 'StackReviewHeader' })
    table.insert(lines, '')
    table.insert(lines, '  Computing changes...')
    table.insert(highlights, { line = #lines, col = 0, end_col = 22, hl = 'StackReviewProgress' })
    return lines, highlights, line_map
  end

  -- Header
  local progress = state.get_progress()
  local header = string.format('  STACK REVIEW [%d/%d reviewed]', progress.reviewed, progress.total)
  table.insert(lines, header)
  table.insert(highlights, { line = #lines, col = 0, end_col = #header, hl = 'StackReviewHeader' })
  table.insert(lines, '')

  -- Files section
  table.insert(lines, '  FILES TO REVIEW')
  table.insert(highlights, { line = #lines, col = 0, end_col = 18, hl = 'StackReviewHeader' })

  local shown_separator = false
  for _, file_info in ipairs(panel.files) do
    -- Skip reviewed files if hide_reviewed is on
    if panel.hide_reviewed and file_info.reviewed then
      goto continue_file
    end

    -- Add separator before quick scan section (1 branch only)
    if file_info.is_quick_scan and not shown_separator then
      -- Check if there were any multi-branch files shown before
      local has_prior_files = false
      for _, f in ipairs(panel.files) do
        if f == file_info then break end
        if not f.is_quick_scan and not (panel.hide_reviewed and f.reviewed) then
          has_prior_files = true
          break
        end
      end
      if has_prior_files then
        table.insert(lines, '')
        table.insert(lines, '  ── quick scan (1 branch) ──')
        table.insert(highlights, { line = #lines, col = 2, end_col = 29, hl = 'StackReviewLater' })
        line_map[#lines] = { type = 'separator' }
      end
      shown_separator = true
    end

    local icon = file_info.reviewed and '+' or '.'
    local filename = vim.fn.fnamemodify(file_info.path, ':t')

    -- Build the info string
    local info
    if file_info.is_quick_scan then
      -- Show NEW if it's a new file, otherwise just show the branch name
      if file_info.is_new then
        info = 'NEW'
      else
        info = file_info.final_branch
      end
    else
      info = string.format('%d branches', file_info.branch_count)
    end

    local file_line = string.format('    %s %s  %s', icon, filename, info)
    table.insert(lines, file_line)
    line_map[#lines] = { type = 'file', file = file_info.path }

    -- Highlight filename based on reviewed status
    local file_hl = file_info.reviewed and 'StackReviewFileReviewed' or 'StackReviewFile'
    local filename_end = #file_line - #info - 2
    table.insert(highlights, { line = #lines, col = 4, end_col = filename_end, hl = file_hl })

    -- Highlight the info
    local info_hl = file_info.is_quick_scan and 'StackReviewNew' or 'StackReviewLater'
    table.insert(highlights, { line = #lines, col = #file_line - #info, end_col = #file_line, hl = info_hl })

    -- Show note if present
    if file_info.note then
      local note_line = '        "' .. file_info.note .. '"'
      table.insert(lines, note_line)
      line_map[#lines] = { type = 'note', file = file_info.path }
      table.insert(highlights, { line = #lines, col = 0, end_col = #note_line, hl = 'StackReviewNote' })
    end

    ::continue_file::
  end

  -- Help section
  table.insert(lines, '')
  table.insert(lines, '  ─────────────────────────────────')
  local hide_status = panel.hide_reviewed and '(hiding reviewed)' or '(showing all)'
  table.insert(lines, '  ' .. hide_status)
  table.insert(lines, '  j/k    navigate files')
  table.insert(lines, '  <CR>   trace file history')
  table.insert(lines, '  r      mark reviewed')
  table.insert(lines, '  h      toggle hide reviewed')
  table.insert(lines, '  a      complete review')
  table.insert(lines, '  q      quit')

  return lines, highlights, line_map
end

-- Render the panel
function M.render()
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  vim.bo[panel.buf].modifiable = true

  local lines, highlights, line_map = build_lines()
  panel.line_map = line_map

  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(panel.buf, ns_id, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(panel.buf, ns_id, hl.hl, hl.line - 1, hl.col, hl.end_col)
  end

  vim.bo[panel.buf].modifiable = false

  -- Restore cursor position
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    local line_count = vim.api.nvim_buf_line_count(panel.buf)
    if panel.cursor_line > line_count then
      panel.cursor_line = line_count
    end
    pcall(vim.api.nvim_win_set_cursor, panel.win, { panel.cursor_line, 0 })
  end
end

-- Get item at current cursor line
function M.get_current_item()
  if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(panel.win)[1]
  return panel.line_map and panel.line_map[line]
end

-- Navigate to next/prev branch
function M.next_branch()
  local current_idx = 0
  for i, branch in ipairs(panel.branches) do
    if branch == panel.cursor_branch then
      current_idx = i
      break
    end
  end

  local next_idx = current_idx + 1
  if next_idx > #panel.branches then
    next_idx = 1
  end

  panel.cursor_branch = panel.branches[next_idx]
  panel.cursor_file = nil

  -- Find line for this branch and move cursor
  M.refresh_data()
  M.render()
  M.focus_current_branch()
end

function M.prev_branch()
  local current_idx = 0
  for i, branch in ipairs(panel.branches) do
    if branch == panel.cursor_branch then
      current_idx = i
      break
    end
  end

  local prev_idx = current_idx - 1
  if prev_idx < 1 then
    prev_idx = #panel.branches
  end

  panel.cursor_branch = panel.branches[prev_idx]
  panel.cursor_file = nil

  M.refresh_data()
  M.render()
  M.focus_current_branch()
end

-- Navigate to next/prev file within current branch
function M.next_file()
  if not panel.cursor_branch then
    if #panel.branches > 0 then
      panel.cursor_branch = panel.branches[1]
    else
      return
    end
  end

  local files = panel.branch_files[panel.cursor_branch]
  if not files or #files == 0 then
    return
  end

  local current_idx = 0
  for i, f in ipairs(files) do
    if f.path == panel.cursor_file then
      current_idx = i
      break
    end
  end

  local next_idx = current_idx + 1
  if next_idx > #files then
    -- Move to first file of next branch
    M.next_branch()
    files = panel.branch_files[panel.cursor_branch]
    if files and #files > 0 then
      panel.cursor_file = files[1].path
    end
  else
    panel.cursor_file = files[next_idx].path
  end

  M.refresh_data()
  M.render()
  M.focus_current_file()
end

function M.prev_file()
  if not panel.cursor_branch then
    if #panel.branches > 0 then
      panel.cursor_branch = panel.branches[#panel.branches]
    else
      return
    end
  end

  local files = panel.branch_files[panel.cursor_branch]
  if not files or #files == 0 then
    return
  end

  local current_idx = 0
  for i, f in ipairs(files) do
    if f.path == panel.cursor_file then
      current_idx = i
      break
    end
  end

  local prev_idx = current_idx - 1
  if prev_idx < 1 then
    -- Move to last file of previous branch
    M.prev_branch()
    files = panel.branch_files[panel.cursor_branch]
    if files and #files > 0 then
      panel.cursor_file = files[#files].path
    end
  else
    panel.cursor_file = files[prev_idx].path
  end

  M.refresh_data()
  M.render()
  M.focus_current_file()
end

-- Move cursor to current branch line
function M.focus_current_branch()
  if not panel.line_map or not panel.cursor_branch then
    return
  end

  for line, item in pairs(panel.line_map) do
    if item.type == 'branch' and item.branch == panel.cursor_branch then
      panel.cursor_line = line
      if panel.win and vim.api.nvim_win_is_valid(panel.win) then
        pcall(vim.api.nvim_win_set_cursor, panel.win, { line, 0 })
      end
      return
    end
  end
end

-- Move cursor to current file line
function M.focus_current_file()
  if not panel.line_map or not panel.cursor_file then
    return
  end

  for line, item in pairs(panel.line_map) do
    if item.type == 'file' and item.file == panel.cursor_file then
      panel.cursor_line = line
      if panel.win and vim.api.nvim_win_is_valid(panel.win) then
        pcall(vim.api.nvim_win_set_cursor, panel.win, { line, 0 })
      end
      return
    end
  end
end

-- Toggle expand/collapse for branch at cursor
function M.toggle_expand()
  local item = M.get_current_item()
  if item and item.type == 'branch' then
    panel.expanded[item.branch] = not panel.expanded[item.branch]
    M.render()
  end
end

-- Toggle reviewed status for file at cursor
function M.toggle_reviewed()
  local item = M.get_current_item()
  if not item then
    return false
  end

  local filepath = nil
  if item.type == 'file' then
    filepath = item.file
  elseif item.type == 'note' then
    filepath = item.file
  end

  if not filepath then
    return false
  end

  local currently_reviewed = state.is_reviewed(filepath)
  state.mark_reviewed(filepath, not currently_reviewed)

  M.refresh_data()
  M.render()

  local status = (not currently_reviewed) and 'reviewed' or 'unreviewed'
  vim.notify(string.format('%s: %s', vim.fn.fnamemodify(filepath, ':t'), status), vim.log.levels.INFO)

  return true
end

-- Add note to file at cursor
function M.add_note()
  local item = M.get_current_item()
  if not item then
    return
  end

  local filepath = nil
  if item.type == 'file' then
    filepath = item.file
  elseif item.type == 'note' then
    filepath = item.file
  end

  if not filepath then
    return
  end

  local current_note = state.get_note(filepath) or ''
  vim.ui.input({
    prompt = 'Note for ' .. vim.fn.fnamemodify(filepath, ':t') .. ': ',
    default = current_note,
  }, function(input)
    if input == nil then
      return
    end
    if input == '' then
      state.add_note(filepath, nil)
    else
      state.add_note(filepath, input)
    end
    M.refresh_data()
    M.render()
  end)
end

-- Toggle hide/show reviewed files
function M.toggle_hide_reviewed()
  panel.hide_reviewed = not panel.hide_reviewed
  M.render()
  local status = panel.hide_reviewed and 'Hiding reviewed files' or 'Showing all files'
  vim.notify(status, vim.log.levels.INFO)
end

-- Get the file and branch at cursor (for diff viewing)
function M.get_selected()
  local item = M.get_current_item()
  if not item then
    return nil, nil
  end

  if item.type == 'file' or item.type == 'note' then
    return item.file, item.branch
  elseif item.type == 'branch' then
    -- Return first file in branch
    local files = panel.branch_files[item.branch]
    if files and #files > 0 then
      return files[1].path, item.branch
    end
    return nil, item.branch
  end

  return nil, nil
end

-- Create the panel window
function M.open()
  setup_highlights()

  -- Create buffer if needed
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    panel.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[panel.buf].buftype = 'nofile'
    vim.bo[panel.buf].bufhidden = 'hide'
    vim.bo[panel.buf].swapfile = false
    vim.bo[panel.buf].filetype = 'StackReviewPanel'
    vim.api.nvim_buf_set_name(panel.buf, 'Stack Review')
  end

  -- Create window on the left
  vim.cmd('topleft vertical ' .. panel.width .. 'split')
  panel.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel.win, panel.buf)

  -- Window options
  vim.wo[panel.win].number = false
  vim.wo[panel.win].relativenumber = false
  vim.wo[panel.win].signcolumn = 'no'
  vim.wo[panel.win].foldcolumn = '0'
  vim.wo[panel.win].wrap = false
  vim.wo[panel.win].cursorline = true
  vim.wo[panel.win].winfixwidth = true

  -- Set up keymaps for this buffer
  local opts = { buffer = panel.buf, silent = true }

  vim.keymap.set('n', ']b', function() M.next_branch() end, opts)
  vim.keymap.set('n', '[b', function() M.prev_branch() end, opts)
  vim.keymap.set('n', ']f', function() M.next_file() end, opts)
  vim.keymap.set('n', '[f', function() M.prev_file() end, opts)
  vim.keymap.set('n', '<Tab>', function() M.toggle_expand() end, opts)
  vim.keymap.set('n', 'r', function() M.toggle_reviewed() end, opts)
  vim.keymap.set('n', 'n', function() M.add_note() end, opts)
  vim.keymap.set('n', 'h', function() M.toggle_hide_reviewed() end, opts)
  vim.keymap.set('n', 'R', function()
    state.refresh_cache()
    panel.loading = true
    M.render()
  end, vim.tbl_extend('force', opts, { desc = 'Force refresh' }))

  -- Subscribe to cache updates for async re-render
  if panel.unsubscribe then
    panel.unsubscribe()
  end
  panel.unsubscribe = state.on_cache_update(function()
    if M.is_open() then
      -- Save current position
      local prev_branch = panel.cursor_branch
      local prev_file = panel.cursor_file

      M.refresh_data()

      -- Restore position if still valid, otherwise default to first branch
      if prev_branch and panel.branch_files[prev_branch] then
        panel.cursor_branch = prev_branch
        panel.cursor_file = prev_file
      elseif panel.branches[1] then
        panel.cursor_branch = panel.branches[1]
        panel.cursor_file = nil
      end

      M.render()

      -- Recalculate cursor line from branch/file position
      if panel.cursor_file then
        M.focus_current_file()
      elseif panel.cursor_branch then
        M.focus_current_branch()
      end
    end
  end)

  -- Load data and render
  M.refresh_data()

  -- Always start at first branch (no position restoration - keeps it simple)
  panel.cursor_branch = panel.branches[1] or nil
  panel.cursor_file = nil

  M.render()

  return panel.win, panel.buf
end

-- Close the panel
function M.close()
  -- Unsubscribe from cache updates
  if panel.unsubscribe then
    panel.unsubscribe()
    panel.unsubscribe = nil
  end

  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end
  panel.win = nil
end

-- Check if panel is open
function M.is_open()
  return panel.win and vim.api.nvim_win_is_valid(panel.win)
end

-- Get panel window
function M.get_win()
  return panel.win
end

-- Get panel buffer
function M.get_buf()
  return panel.buf
end

-- Focus the panel window
function M.focus()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_set_current_win(panel.win)
  end
end

-- Get all branches with changes
function M.get_branches()
  return panel.branches
end

-- Get changes info for a branch
function M.get_branch_info(branch)
  local changes = state.get_changed_files_by_branch()
  if changes and changes.branches then
    return changes.branches[branch]
  end
  return nil
end

return M
