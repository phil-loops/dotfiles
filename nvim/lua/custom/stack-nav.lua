-- Stack Navigator
-- Visual floating window for navigating git branch stacks
-- Designed to be readable by both humans and Claude

local M = {}

-- The loops stack command (shell function wrapper)
local STACK_CMD = 'node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts'

-- State
local state = {
  buf = nil,
  win = nil,
  branches = {},      -- ordered list of branch names
  current_idx = 1,    -- which branch we're on
  cursor_idx = 1,     -- which line the cursor is on
  drift_info = {},    -- { branch = { files = {}, downstream = {} } }
  size_info = {},     -- { branch = loc }
}

-- Parse stack info output
local function parse_stack_info()
  local output = vim.fn.system(STACK_CMD .. ' info 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local branches = {}
  local current_branch = vim.fn.system('git branch --show-current 2>/dev/null'):gsub('%s+$', '')
  local current_idx = 1
  local size_info = {}
  local drift_info = {}

  local idx = 0
  for line in output:gmatch('[^\n]+') do
    -- Extract branch name (handles tree prefixes like "└─ ", "├─ ", "│  ")
    local branch = line:match('[└├│─ ]*([%w%-_%.]+)%s*%(')
    if not branch then
      branch = line:match('^([%w%-_%.]+)$')  -- root branch (no parens)
    end

    if branch and branch ~= '' then
      idx = idx + 1
      table.insert(branches, branch)

      if branch == current_branch or line:match('<%-%-? you') then
        current_idx = idx
      end

      -- Parse size: (✅ 58) or (🔴240) or just number
      local loc = line:match('(%d+)%)')
      if loc then
        size_info[branch] = tonumber(loc)
      end

      -- Parse drift indicator
      local drift_count = line:match('⚠️(%d+)')
      if drift_count then
        drift_info[branch] = { count = tonumber(drift_count), files = {} }
      end
    end

    -- Parse drift file lines: "↳ drift: filename.ts"
    local drift_file = line:match('↳ drift:%s*(.+)$')
    if drift_file and #branches > 0 then
      local last_branch = branches[#branches]
      if drift_info[last_branch] then
        -- Split on comma for multiple files
        for file in drift_file:gmatch('[^,]+') do
          file = file:match('^%s*(.-)%s*$')  -- trim
          if file and file ~= '' and not file:match('^%+') then
            table.insert(drift_info[last_branch].files, file)
          end
        end
      end
    end
  end

  return {
    branches = branches,
    current_idx = current_idx,
    size_info = size_info,
    drift_info = drift_info,
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
    else
      prefix = '○ '
    end

    -- Size indicator
    local loc = state.size_info[branch]
    if loc then
      if loc > 150 then
        suffix = suffix .. string.format(' 🔴%d', loc)
      else
        suffix = suffix .. string.format(' %d', loc)
      end
    end

    -- Drift indicator
    local drift = state.drift_info[branch]
    if drift and drift.count > 0 then
      suffix = suffix .. string.format(' ⚠️%d', drift.count)
      hl = 'WarningMsg'
    end

    -- You are here
    if i == state.current_idx then
      suffix = suffix .. '  ← you'
    end

    local line = prefix .. branch .. suffix
    table.insert(lines, line)

    if hl then
      table.insert(highlights, { line = i, hl = hl })
    end

    -- Show drifted files indented under branch
    if drift and #drift.files > 0 then
      local drift_line = '    ↳ ' .. table.concat(drift.files, ', ')
      table.insert(lines, drift_line)
      table.insert(highlights, { line = #lines, hl = 'Comment' })
    end
  end

  -- Footer
  table.insert(lines, '')
  table.insert(lines, ' [j/k] navigate  [enter] goto  [d] drift  [q] quit')
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
    local new_row = math.min(pos[1] + 1, vim.api.nvim_buf_line_count(state.buf) - 2)
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
    local line = vim.api.nvim_buf_get_lines(state.buf, pos[1] - 1, pos[1], false)[1]

    -- Extract branch name from line
    local branch = line:match('[●○]%s+([%w%-_%.]+)')
    if branch then
      M.close()
      vim.fn.system(STACK_CMD .. ' go ' .. branch)
      vim.cmd('edit!')  -- Reload current buffer
      vim.notify('Switched to ' .. branch)
    end
  end, opts)

  -- Show drift details for branch under cursor
  vim.keymap.set('n', 'd', function()
    local pos = vim.api.nvim_win_get_cursor(state.win)
    local line = vim.api.nvim_buf_get_lines(state.buf, pos[1] - 1, pos[1], false)[1]
    local branch = line:match('[●○]%s+([%w%-_%.]+)')

    if branch and state.drift_info[branch] then
      M.close()
      M.show_drift(branch)
    else
      vim.notify('No drift on this branch', vim.log.levels.INFO)
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
    vim.notify('Not in a stack', vim.log.levels.WARN)
    return false
  end

  state.branches = info.branches
  state.current_idx = info.current_idx
  state.size_info = info.size_info
  state.drift_info = info.drift_info

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

-- Show drift details for a specific branch
function M.show_drift(branch)
  local output = vim.fn.system(STACK_CMD .. ' info -d 2>/dev/null')

  -- Create a scratch buffer with drift details
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  local lines = {
    'Drift Details: ' .. branch,
    string.rep('─', 40),
    '',
  }

  -- Parse drift info for this branch
  local in_drift_section = false
  for line in output:gmatch('[^\n]+') do
    if line:match('Drifted files') then
      in_drift_section = true
    elseif in_drift_section then
      table.insert(lines, line)
    end
  end

  if #lines == 3 then
    table.insert(lines, 'No drift details available')
    table.insert(lines, '')
    table.insert(lines, 'Run: loops stack info -d')
  end

  table.insert(lines, '')
  table.insert(lines, '[q] close')

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Open in split
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 2, 15))

  vim.keymap.set('n', 'q', ':close<CR>', { buffer = buf, silent = true })
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
  local key = opts.key or '<leader>sn'
  vim.keymap.set('n', key, function() M.toggle() end, { desc = 'Stack Navigator' })

  -- Also set up [b and ]b for quick navigation without opening the window
  vim.keymap.set('n', '[b', function()
    vim.fn.system(STACK_CMD .. ' go prev 2>/dev/null')
    if vim.v.shell_error == 0 then
      vim.cmd('edit!')
      vim.notify('← ' .. vim.fn.system('git branch --show-current'):gsub('%s+$', ''))
    end
  end, { desc = 'Previous branch in stack' })

  vim.keymap.set('n', ']b', function()
    vim.fn.system(STACK_CMD .. ' go next 2>/dev/null')
    if vim.v.shell_error == 0 then
      vim.cmd('edit!')
      vim.notify('→ ' .. vim.fn.system('git branch --show-current'):gsub('%s+$', ''))
    end
  end, { desc = 'Next branch in stack' })
end

return M
