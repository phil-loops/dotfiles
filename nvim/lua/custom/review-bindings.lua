-- Review Bindings - shared keybindings for reviewing branches with blessing
-- Used by both stack-review.lua and branch-review.lua
--
-- ctx = {
--   get_branch()  -> string       current branch being reviewed
--   get_base()    -> string       parent/base to diff against
--   get_unreviewed() -> {{filepath, status}, ...}  all unreviewed files (may span branches)
--   on_blessed()                  callback after blessing (refresh panels etc)
-- }
local M = {}
local blessed = require("custom.stack-blessed")

-- Get the filepath of the currently focused file in diffview
function M.get_diffview_filepath()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local view = lib.get_current_view()
  if not view then return nil end

  if view.panel and view.panel.cur_file then
    return view.panel.cur_file.path
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if view.cur_layout then
    for _, win in ipairs(view.cur_layout.windows or {}) do
      if win.file and win.file.bufnr == bufnr then
        return win.file.path
      end
    end
  end

  if view.files then
    for _, file in view.files:iter() do
      if file.left_bufnr == bufnr or file.right_bufnr == bufnr then
        return file.path
      end
    end
  end

  return nil
end

-- Refresh blessed indicators in diffview's file panel
function M.refresh_diffview_panel(branch)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return end
  local view = lib.get_current_view()
  if not view or not view.panel then return end
  for _, file in view.files:iter() do
    file.blessed_status = blessed.file_status(branch, file.path)
  end
  view.panel:render()
  view.panel:redraw()
end

-- Set up all common review keybindings given a context table
function M.setup(ctx)
  local last_jump = nil

  vim.keymap.set("n", "<leader>sb", function()
    local filepath = M.get_diffview_filepath()
    if filepath then
      blessed.bless_file(ctx.get_branch(), filepath)
      if ctx.on_blessed then ctx.on_blessed() end
    else
      vim.notify("Focus a file first (use <leader>sB to bless all)", vim.log.levels.WARN)
    end
  end, { desc = "Bless current file" })

  vim.keymap.set("n", "<leader>sB", function()
    blessed.bless_branch(ctx.get_branch(), ctx.get_base())
    if ctx.on_blessed then ctx.on_blessed() end
  end, { desc = "Bless all files on branch" })

  -- Next/prev unreviewed file
  local function jump_unreviewed(direction)
    local unreviewed = ctx.get_unreviewed()
    if #unreviewed == 0 then
      vim.notify("All files reviewed", vim.log.levels.INFO)
      return
    end

    local cur_filepath = M.get_diffview_filepath()
    local cur_branch = ctx.get_branch()
    local cur_pos = nil

    -- Try exact match on currently focused file
    if cur_filepath then
      for i, entry in ipairs(unreviewed) do
        local eb = entry.branch or cur_branch
        if eb == cur_branch and entry.filepath == cur_filepath then
          cur_pos = i
          break
        end
      end
    end

    -- Fall back to last jump target
    if not cur_pos and last_jump then
      for i, entry in ipairs(unreviewed) do
        local eb = entry.branch or cur_branch
        if eb == (last_jump.branch or cur_branch) and entry.filepath == last_jump.filepath then
          cur_pos = i
          break
        end
      end
    end

    if not cur_pos then
      cur_pos = direction == "next" and 0 or 1
    end

    local target_pos
    if direction == "next" then
      target_pos = cur_pos % #unreviewed + 1
    else
      target_pos = (cur_pos - 2) % #unreviewed + 1
    end

    local target = unreviewed[target_pos]
    last_jump = { branch = target.branch, filepath = target.filepath }

    -- If target has a switch_to callback (cross-branch jump), use it
    if target.switch_to then
      target.switch_to(function()
        M._focus_file(target.filepath)
        local label = target.status == "stale" and "stale" or "unreviewed"
        local loc = target.branch and (target.branch .. " ") or ""
        vim.notify(string.format("[%d/%d] %s%s (%s)", target_pos, #unreviewed, loc, target.filepath, label), vim.log.levels.INFO)
      end)
    else
      M._focus_file(target.filepath)
      local label = target.status == "stale" and "stale" or "unreviewed"
      vim.notify(string.format("[%d/%d] %s (%s)", target_pos, #unreviewed, target.filepath, label), vim.log.levels.INFO)
    end
  end

  vim.keymap.set("n", "]u", function() jump_unreviewed("next") end, { desc = "Next unreviewed file" })
  vim.keymap.set("n", "[u", function() jump_unreviewed("prev") end, { desc = "Prev unreviewed file" })

  vim.keymap.set("n", "go", function()
    local filepath = M.get_diffview_filepath()
    if not filepath then
      vim.notify("Focus a file first", vim.log.levels.WARN)
      return
    end

    local branch = ctx.get_branch()
    local cur = vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null"):gsub("%s+$", "")
    if cur ~= branch then
      vim.fn.system("git checkout " .. branch .. " 2>/dev/null")
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to checkout " .. branch, vim.log.levels.ERROR)
        return
      end
    end

    local cwd = vim.fn.getcwd()
    vim.cmd("tabedit " .. vim.fn.fnameescape(cwd .. "/" .. filepath))
  end, { desc = "Open file in new tab (with LSP)" })

  vim.keymap.set("n", "gd", function()
    local branch = ctx.get_branch()
    local filepath = M.get_diffview_filepath()
    if not filepath then
      vim.notify("Focus a file first", vim.log.levels.WARN)
      return
    end

    local bsha = blessed.get_sha(branch, filepath)
    if not bsha then
      vim.notify("File not blessed yet", vim.log.levels.WARN)
      return
    end

    if blessed.file_status(branch, filepath) == "clean" then
      vim.notify("File unchanged since blessing", vim.log.levels.INFO)
      return
    end

    vim.cmd("tabnew")

    local left_content = vim.fn.systemlist(string.format("git cat-file blob %s 2>/dev/null", bsha))
    local left_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_content)
    vim.api.nvim_buf_set_option(left_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(left_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(left_buf, "bufhidden", "wipe")
    local ext = filepath:match("%.(%w+)$") or ""
    if ext ~= "" then vim.api.nvim_buf_set_option(left_buf, "filetype", ext) end
    vim.api.nvim_buf_set_name(left_buf, string.format("%s (blessed %s)", filepath, bsha:sub(1, 8)))
    vim.cmd("diffthis")

    vim.cmd("vsplit")
    local right_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, right_buf)
    local right_content = vim.fn.systemlist(string.format("git show %s:%s 2>/dev/null", branch, filepath))
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_content)
    vim.api.nvim_buf_set_option(right_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(right_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(right_buf, "bufhidden", "wipe")
    if ext ~= "" then vim.api.nvim_buf_set_option(right_buf, "filetype", ext) end
    vim.api.nvim_buf_set_name(right_buf, string.format("%s @ %s (current)", filepath, branch))
    vim.cmd("diffthis")

    for _, b in ipairs({ left_buf, right_buf }) do
      vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = b, desc = "Close delta tab" })
    end
  end, { desc = "Show delta since blessed" })

  vim.keymap.set("n", "gy", function()
    local branch = ctx.get_branch()
    local filepath = M.get_diffview_filepath()
    if filepath then
      local ref = branch .. ":" .. filepath
      vim.fn.setreg("+", ref)
      vim.notify("Copied: " .. ref, vim.log.levels.INFO)
    else
      vim.fn.setreg("+", branch)
      vim.notify("Copied: " .. branch, vim.log.levels.INFO)
    end
  end, { desc = "Copy branch:file ref to clipboard" })

  vim.keymap.set("n", "g?", function()
    local help = ctx.help_text or [[
Review Keybindings:
  ]u / [u       next/prev unreviewed file
  <leader>sb    bless current file
  <leader>sB    bless all files on branch
  go            open file in new tab (with LSP)
  gd            show delta since blessed (new tab)
  gy            copy branch:file ref to clipboard
  g?            show this help

  Blessed = "I reviewed this file's content" (survives rebases)
]]
    vim.notify(help, vim.log.levels.INFO)
  end, { desc = "Review help" })
end

-- Focus a file in the current diffview by path
function M._focus_file(filepath)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return end
  local view = lib.get_current_view()
  if not view or not view.panel then return end
  for _, f in view.files:iter() do
    if f.path == filepath then
      view:set_file(f, false, true)
      break
    end
  end
end

return M
