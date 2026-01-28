-- Stack Review - branch navigation for git-town stacks
local M = {}

-- State
local chain = {}      -- { {branch="...", parent="..."}, ... }
local current_idx = 1
local panel_buf = nil
local panel_win = nil

local function update_panel()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then return end

  local lines = {}
  for i, item in ipairs(chain) do
    local marker = (i == current_idx) and " ◀" or ""
    local prefix = (i == current_idx) and "▶ " or "  "
    -- Shorten branch names (remove common prefixes)
    local short_name = item.branch:gsub("goals%-v%d+%-", "")
    table.insert(lines, string.format("%s%s%s", prefix, short_name, marker))
  end

  vim.api.nvim_buf_set_option(panel_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_buf, "modifiable", false)

  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_set_cursor, panel_win, {current_idx, 0})
  end
end

local function open_review(idx)
  if idx < 1 or idx > #chain then return false end

  local item = chain[idx]
  if not item.parent or item.parent == "" then
    vim.notify("No parent to diff against", vim.log.levels.WARN)
    return false
  end

  current_idx = idx
  pcall(vim.cmd, "DiffviewClose")
  vim.cmd("DiffviewOpen " .. item.parent .. ".." .. item.branch)

  vim.notify(string.format("Reviewing: %s (%d/%d)", item.branch, idx, #chain), vim.log.levels.INFO)

  -- Reopen panel after diffview loads
  vim.defer_fn(function()
    M.open_panel()
  end, 150)

  return true
end

function M.open_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    update_panel()
    return
  end

  -- Find diffview file panel
  local file_panel_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("DiffviewFilePanel") then
      file_panel_win = win
      break
    end
  end

  if not file_panel_win then
    vim.notify("Diffview panel not found", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(file_panel_win)

  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(panel_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(panel_buf, "bufhidden", "wipe")

  local height = math.min(#chain + 2, 20)
  vim.cmd("aboveleft " .. height .. "split")
  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_option(panel_win, "number", false)
  vim.api.nvim_win_set_option(panel_win, "relativenumber", false)
  vim.api.nvim_win_set_option(panel_win, "cursorline", true)
  vim.api.nvim_win_set_option(panel_win, "winfixheight", true)

  -- Panel keymaps
  local opts = { buffer = panel_buf, silent = true }
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    open_review(line)
  end, opts)
  vim.keymap.set("n", "j", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] < #chain then
      vim.api.nvim_win_set_cursor(0, {pos[1] + 1, 0})
    end
  end, opts)
  vim.keymap.set("n", "k", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] > 1 then
      vim.api.nvim_win_set_cursor(0, {pos[1] - 1, 0})
    end
  end, opts)
  vim.keymap.set("n", "q", function()
    vim.cmd("qa")
  end, opts)

  update_panel()
  vim.cmd("wincmd l")
end

function M.close_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_win_close(panel_win, true)
    panel_win = nil
  end
end

function M.toggle_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    M.close_panel()
  else
    M.open_panel()
  end
end

function M.next_branch()
  if current_idx < #chain then
    open_review(current_idx + 1)
  else
    vim.notify("Last branch", vim.log.levels.INFO)
  end
end

function M.prev_branch()
  if current_idx > 1 then
    open_review(current_idx - 1)
  else
    vim.notify("First branch", vim.log.levels.INFO)
  end
end

function M.setup(data)
  chain = data.chain or {}
  current_idx = data.start_idx or 1

  -- Global keymaps
  vim.keymap.set("n", "]b", M.next_branch, { desc = "Next branch in stack" })
  vim.keymap.set("n", "[b", M.prev_branch, { desc = "Prev branch in stack" })
  vim.keymap.set("n", "<leader>sp", M.toggle_panel, { desc = "Toggle stack panel" })

  vim.keymap.set("n", "g?", function()
    vim.notify([[
Stack Review Keybindings:
  ]b / [b       next/prev branch
  <leader>sp    toggle stack panel
  <CR>          jump to branch (in panel)
  j / k         move in panel
  q             quit
]], vim.log.levels.INFO)
  end, { desc = "Stack review help" })

  -- Open panel after a short delay
  vim.defer_fn(M.open_panel, 200)
end

return M
