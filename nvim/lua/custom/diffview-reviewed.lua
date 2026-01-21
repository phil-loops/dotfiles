-- Lightweight "Mark as Reviewed" plugin for diffview.nvim
-- Tracks which files have been reviewed in the current diffview session

local M = {}

-- Configuration
M.opts = {
  icon = '✓',
  hl = 'DiffviewReviewed',
}

-- State: reviewed[git_root][base_ref][filepath] = true
local reviewed = {}

-- Track which git roots we've loaded state for
local loaded_roots = {}

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace('diffview_reviewed')

-- Get git root directory
local function get_git_root()
  local result = vim.fn.systemlist('git rev-parse --show-toplevel')[1]
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- Get the persistence file path
local function get_persistence_path()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end
  return git_root .. '/.git/diffview-reviewed.json'
end

-- Load reviewed state from file for a specific git root
local function load_state_for_root(git_root)
  if not git_root or loaded_roots[git_root] then
    return
  end

  local path = git_root .. '/.git/diffview-reviewed.json'
  local file = io.open(path, 'r')
  if not file then
    loaded_roots[git_root] = true
    return
  end

  local content = file:read('*all')
  file:close()

  if content and content ~= '' then
    local ok, data = pcall(vim.json.decode, content)
    if ok and data and data[git_root] then
      reviewed[git_root] = data[git_root]
    end
  end

  loaded_roots[git_root] = true
end

-- Save reviewed state to file for a specific git root
local function save_state_for_root(git_root)
  if not git_root then
    return
  end

  local path = git_root .. '/.git/diffview-reviewed.json'
  local file = io.open(path, 'w')
  if not file then
    return
  end

  -- Save only this git root's data
  local data = { [git_root] = reviewed[git_root] }
  local ok, json = pcall(vim.json.encode, data)
  if ok then
    file:write(json)
  end
  file:close()
end

-- Get the current diffview and base ref
local function get_view_info()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return nil, nil
  end

  local view = lib.get_current_view()
  if not view then
    return nil, nil
  end

  local git_root = get_git_root()
  if not git_root then
    return nil, nil
  end

  -- Ensure state is loaded for this git root
  load_state_for_root(git_root)

  -- Get base ref from the view (e.g., "main", "HEAD", etc.)
  local base_ref = 'unknown'
  if view.adapter and view.adapter.ctx and view.adapter.ctx.left then
    base_ref = tostring(view.adapter.ctx.left)
  elseif view.left and view.left.rev then
    base_ref = tostring(view.left.rev)
  end

  return git_root, base_ref
end

-- Get all files in the current diffview
local function get_diffview_files()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return {}
  end

  local view = lib.get_current_view()
  if not view then
    return {}
  end

  local files = {}
  if view.panel and view.panel.files then
    -- Try to get files from different possible structures
    local file_list = view.panel.files
    if type(file_list) == 'table' then
      -- Could be a flat list or grouped by section
      if file_list.working and type(file_list.working) == 'table' then
        for _, f in ipairs(file_list.working) do
          if f.path then
            table.insert(files, f.path)
          end
        end
      end
      if file_list.staged and type(file_list.staged) == 'table' then
        for _, f in ipairs(file_list.staged) do
          if f.path then
            table.insert(files, f.path)
          end
        end
      end
      -- Also try direct iteration for diff views
      for _, f in ipairs(file_list) do
        if type(f) == 'table' and f.path then
          table.insert(files, f.path)
        end
      end
    end
  end

  return files
end

-- Get the currently selected file in the diffview panel
local function get_current_file()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return nil
  end

  local view = lib.get_current_view()
  if not view then
    return nil
  end

  -- Try to infer the current file
  if view.panel and view.panel.cur_file then
    local cur = view.panel.cur_file
    if type(cur) == 'table' and cur.path then
      return cur.path
    end
  end

  -- Try to get from current item
  if view.panel and view.panel.cur_item then
    local item = view.panel.cur_item
    if type(item) == 'table' then
      if item.path then
        return item.path
      end
      if item.file and item.file.path then
        return item.file.path
      end
    end
  end

  -- Try infer_cur_file method
  if view.infer_cur_file then
    local file = view:infer_cur_file()
    if file and file.path then
      return file.path
    end
  end

  return nil
end

-- Check if a file is reviewed
function M.is_reviewed(filepath)
  if not filepath then
    return false
  end

  local git_root, base_ref = get_view_info()
  if not git_root then
    return false
  end

  reviewed[git_root] = reviewed[git_root] or {}
  reviewed[git_root][base_ref] = reviewed[git_root][base_ref] or {}

  return reviewed[git_root][base_ref][filepath] == true
end

-- Toggle reviewed state for the current file
function M.toggle()
  local filepath = get_current_file()
  if not filepath then
    vim.notify('No file selected in diffview', vim.log.levels.WARN)
    return
  end

  local git_root, base_ref = get_view_info()
  if not git_root then
    vim.notify('Not in a git repository', vim.log.levels.WARN)
    return
  end

  -- Initialize nested tables if needed
  reviewed[git_root] = reviewed[git_root] or {}
  reviewed[git_root][base_ref] = reviewed[git_root][base_ref] or {}

  -- Toggle the state
  if reviewed[git_root][base_ref][filepath] then
    reviewed[git_root][base_ref][filepath] = nil
    vim.notify('Unmarked: ' .. filepath, vim.log.levels.INFO)
  else
    reviewed[git_root][base_ref][filepath] = true
    vim.notify('Reviewed: ' .. filepath, vim.log.levels.INFO)
  end

  -- Save and refresh
  save_state_for_root(git_root)
  M.refresh_indicators()
end

-- Clear all reviewed files for current view
function M.clear()
  local git_root, base_ref = get_view_info()
  if not git_root then
    return
  end

  if reviewed[git_root] and reviewed[git_root][base_ref] then
    reviewed[git_root][base_ref] = {}
    save_state_for_root(git_root)
    M.refresh_indicators()
    vim.notify('Cleared all reviewed files', vim.log.levels.INFO)
  end
end

-- Force reload state from disk (useful if changed externally)
function M.reload()
  local git_root = get_git_root()
  if not git_root then
    return
  end

  -- Clear cached state to force reload
  loaded_roots[git_root] = nil
  reviewed[git_root] = nil
  load_state_for_root(git_root)
  M.refresh_indicators()
  vim.notify('Reloaded review state', vim.log.levels.INFO)
end

-- Get stats for current view
function M.get_stats()
  local git_root, base_ref = get_view_info()
  if not git_root then
    return { reviewed = 0, total = 0 }
  end

  local files = get_diffview_files()
  local reviewed_count = 0

  reviewed[git_root] = reviewed[git_root] or {}
  reviewed[git_root][base_ref] = reviewed[git_root][base_ref] or {}

  for _, filepath in ipairs(files) do
    if reviewed[git_root][base_ref][filepath] then
      reviewed_count = reviewed_count + 1
    end
  end

  return {
    reviewed = reviewed_count,
    total = #files,
  }
end

-- Find the panel buffer
local function find_panel_buf()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    if ft == 'DiffviewFiles' then
      return buf
    end
  end
  return nil
end

-- Refresh visual indicators in the file panel
function M.refresh_indicators()
  local buf = find_panel_buf()
  if not buf then
    return
  end

  local git_root, base_ref = get_view_info()
  if not git_root then
    return
  end

  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Get all lines in the buffer
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  reviewed[git_root] = reviewed[git_root] or {}
  reviewed[git_root][base_ref] = reviewed[git_root][base_ref] or {}

  -- For each line, check if it contains a reviewed file
  for i, line in ipairs(lines) do
    -- Try to extract filepath from the line
    -- Diffview shows files with icons and status, so we look for common patterns
    for filepath, _ in pairs(reviewed[git_root][base_ref]) do
      -- Check if this line contains the filepath (at the end or as component)
      local fname = vim.fn.fnamemodify(filepath, ':t')
      if line:find(fname, 1, true) then
        -- Add virtual text indicator
        vim.api.nvim_buf_set_extmark(buf, ns_id, i - 1, 0, {
          virt_text = { { ' ' .. M.opts.icon, M.opts.hl } },
          virt_text_pos = 'eol',
        })
        break
      end
    end
  end
end

-- Setup function
function M.setup(opts)
  M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})

  -- Create highlight group if it doesn't exist
  vim.api.nvim_set_hl(0, 'DiffviewReviewed', { fg = '#98c379', bold = true })

  -- Set up autocommands to refresh indicators
  local augroup = vim.api.nvim_create_augroup('DiffviewReviewed', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved' }, {
    group = augroup,
    pattern = '*',
    callback = function()
      -- Only refresh if we're in a diffview context
      local ft = vim.bo.filetype
      if ft == 'DiffviewFiles' or ft == 'DiffviewFileHistory' then
        vim.defer_fn(function()
          M.refresh_indicators()
        end, 50)
      end
    end,
  })

  -- Also refresh when diffview opens
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = { 'DiffviewFiles', 'DiffviewFileHistory' },
    callback = function()
      vim.defer_fn(function()
        -- State will be loaded on-demand via get_view_info()
        M.refresh_indicators()
      end, 100)
    end,
  })
end

-- Auto-setup when module is loaded
M.setup()

return M
