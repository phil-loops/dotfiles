-- Stack Navigator
-- Visual floating window for navigating git branch stacks
-- Uses git-town for stack management

local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  branches = {},      -- ordered list of branch names
  parents = {},       -- branch -> parent mapping
  current_idx = 1,    -- which branch we're on
  cursor_idx = 1,     -- which line the cursor is on
}

-- Read git-town lineage from git config
local function get_git_town_lineage()
  local output = vim.fn.systemlist('git config --local --list 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return {}, {}
  end

  local parents = {}
  local main_branch = 'main'

  for _, line in ipairs(output) do
    -- git-town-branch.<branch>.parent=<parent>
    local branch, parent = line:match('^git%-town%-branch%.(.+)%.parent=(.+)$')
    if branch and parent then
      parents[branch] = parent
    end
    -- git-town.main-branch=main
    local main = line:match('^git%-town%.main%-branch=(.+)$')
    if main then
      main_branch = main
    end
  end

  return parents, main_branch
end

-- Build ordered branch list from lineage (root to leaf)
local function build_branch_chain(parents, main_branch)
  -- Find all branches in the current stack (ancestors + descendants of current branch)
  local current = vim.fn.system('git branch --show-current 2>/dev/null'):gsub('%s+$', '')

  -- Build ancestor chain (current -> ... -> main)
  local ancestors = {}
  local branch = current
  while branch and branch ~= main_branch and parents[branch] do
    table.insert(ancestors, 1, branch)  -- prepend
    branch = parents[branch]
  end

  -- Add main at the start if we have ancestors
  if #ancestors > 0 then
    table.insert(ancestors, 1, main_branch)
  elseif current ~= main_branch then
    -- Current branch has no parent tracked - might be standalone
    return { current }, 1
  else
    return { main_branch }, 1
  end

  -- Find descendants of current branch
  local descendants = {}
  local children = {}  -- parent -> list of children

  for child, parent in pairs(parents) do
    children[parent] = children[parent] or {}
    table.insert(children[parent], child)
  end

  -- BFS from current to find all descendants
  local queue = { current }
  while #queue > 0 do
    local node = table.remove(queue, 1)
    if children[node] then
      for _, child in ipairs(children[node]) do
        table.insert(descendants, child)
        table.insert(queue, child)
      end
    end
  end

  -- Combine: ancestors (includes main and current) + descendants
  local all_branches = ancestors
  for _, desc in ipairs(descendants) do
    table.insert(all_branches, desc)
  end

  -- Find current index
  local current_idx = 1
  for i, b in ipairs(all_branches) do
    if b == current then
      current_idx = i
      break
    end
  end

  return all_branches, current_idx
end

-- Parse git-town branch output for display
local function parse_stack_info()
  local parents, main_branch = get_git_town_lineage()
  if vim.tbl_isempty(parents) then
    return nil
  end

  local branches, current_idx = build_branch_chain(parents, main_branch)

  return {
    branches = branches,
    parents = parents,
    current_idx = current_idx,
  }
end

-- Render the stack view
local function render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local lines = {}
  local highlights = {}

  for i, branch in ipairs(state.branches) do
    local prefix = '  '
    local suffix = ''
    local hl = nil

    -- Current branch marker
    if i == state.current_idx then
      prefix = '● '
      hl = 'Title'
      suffix = '  ← you'
    else
      prefix = '○ '
    end

    -- Indent based on depth (visual tree)
    local indent = string.rep('  ', i - 1)
    local line = indent .. prefix .. branch .. suffix
    table.insert(lines, line)

    if hl then
      table.insert(highlights, { line = i, hl = hl })
    end
  end

  -- Footer
  table.insert(lines, '')
  table.insert(lines, ' [j/k] navigate  [enter] goto  [q] quit')
  table.insert(highlights, { line = #lines, hl = 'Comment' })

  vim.api.nvim_buf_set_option(state.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)

  -- Apply highlights
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, -1, h.hl, h.line - 1, 0, -1)
  end
end

-- Create the floating window
local function create_window()
  -- Calculate dimensions
  local width = 60
  local height = math.min(#state.branches + 5, 30)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(state.buf, 'filetype', 'stacknav')

  -- Create window
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Stack Navigator ',
    title_pos = 'center',
  })

  -- Window options
  vim.api.nvim_win_set_option(state.win, 'cursorline', true)
  vim.api.nvim_win_set_option(state.win, 'wrap', false)
end

-- Set up keymaps for the navigator
local function setup_keymaps()
  local opts = { buffer = state.buf, silent = true }

  -- Close
  vim.keymap.set('n', 'q', function() M.close() end, opts)
  vim.keymap.set('n', '<Esc>', function() M.close() end, opts)

  -- Navigate (j/k are natural, but we need to track which branch we're on)
  vim.keymap.set('n', 'j', function()
    local pos = vim.api.nvim_win_get_cursor(state.win)
    local new_row = math.min(pos[1] + 1, #state.branches)
    vim.api.nvim_win_set_cursor(state.win, { new_row, 0 })
  end, opts)

  vim.keymap.set('n', 'k', function()
    local pos = vim.api.nvim_win_get_cursor(state.win)
    local new_row = math.max(pos[1] - 1, 1)
    vim.api.nvim_win_set_cursor(state.win, { new_row, 0 })
  end, opts)

  -- Go to branch under cursor
  vim.keymap.set('n', '<CR>', function()
    local pos = vim.api.nvim_win_get_cursor(state.win)
    local idx = pos[1]
    local branch = state.branches[idx]

    if branch then
      M.close()
      vim.fn.system('git checkout ' .. branch .. ' 2>/dev/null')
      vim.cmd('edit!')  -- Reload current buffer
      vim.notify('Switched to ' .. branch)
    end
  end, opts)

  -- Refresh
  vim.keymap.set('n', 'r', function()
    M.refresh()
  end, opts)
end

-- Close the navigator
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

-- Refresh data and re-render
function M.refresh()
  local info = parse_stack_info()
  if not info then
    vim.notify('Not in a git-town stack (run: git town init)', vim.log.levels.WARN)
    return false
  end

  state.branches = info.branches
  state.parents = info.parents
  state.current_idx = info.current_idx

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    render()
  end

  return true
end

-- Open the stack navigator
function M.open()
  -- Close existing if open
  M.close()

  -- Parse stack info
  if not M.refresh() then
    return
  end

  if #state.branches == 0 then
    vim.notify('No branches in stack', vim.log.levels.WARN)
    return
  end

  -- Create UI
  create_window()
  render()
  setup_keymaps()

  -- Position cursor on current branch
  vim.api.nvim_win_set_cursor(state.win, { state.current_idx, 0 })
end

-- Show diff for a specific branch vs its parent
function M.show_diff(branch)
  local parent = state.parents[branch]
  if not parent then
    vim.notify('No parent for ' .. branch, vim.log.levels.WARN)
    return
  end

  -- Open diffview comparing parent to branch
  vim.cmd('DiffviewOpen ' .. parent .. '..' .. branch)
end

-- Toggle the navigator
function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

-- Setup function for lazy loading
function M.setup(opts)
  opts = opts or {}

  -- Default keymap
  local key = opts.key or '<leader>sv'
  vim.keymap.set('n', key, function() M.toggle() end, { desc = 'Stack: View navigator' })

  -- [b and ]b for quick navigation using git-town
  vim.keymap.set('n', '[b', function()
    vim.fn.system('git town down 2>/dev/null')
    if vim.v.shell_error == 0 then
      vim.cmd('edit!')
      vim.notify('↓ ' .. vim.fn.system('git branch --show-current'):gsub('%s+$', ''))
    else
      vim.notify('Already at root', vim.log.levels.INFO)
    end
  end, { desc = 'Parent branch (git town down)' })

  vim.keymap.set('n', ']b', function()
    vim.fn.system('git town up 2>/dev/null')
    if vim.v.shell_error == 0 then
      vim.cmd('edit!')
      vim.notify('↑ ' .. vim.fn.system('git branch --show-current'):gsub('%s+$', ''))
    else
      vim.notify('Already at leaf', vim.log.levels.INFO)
    end
  end, { desc = 'Child branch (git town up)' })
end

return M
