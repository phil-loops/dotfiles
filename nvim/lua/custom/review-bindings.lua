-- Review Bindings - shared keybindings for reviewing a branch in diffview
-- Used by branch-review.lua and <leader>gm
--
-- ctx = {
--   get_branch()  -> string       current branch being reviewed
--   get_base()    -> string       parent/base to diff against
-- }
local M = {}

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

-- Set up all common review keybindings given a context table
function M.setup(ctx)
  vim.keymap.set("n", "<leader>gf", function()
    local filepath = M.get_diffview_filepath()
    if not filepath then
      vim.notify("Focus a file first", vim.log.levels.WARN)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    local branch = ctx.get_branch()
    local cur = vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null"):gsub("%s+$", "")
    if cur ~= branch then
      local out = vim.fn.system("git checkout " .. branch .. " 2>&1")
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to checkout " .. branch .. ": " .. out, vim.log.levels.ERROR)
        return
      end
    end

    local cwd = vim.fn.getcwd()
    local full_path = cwd .. "/" .. filepath
    if vim.fn.filereadable(full_path) == 0 then
      vim.notify("File not on disk after checkout: " .. filepath, vim.log.levels.ERROR)
      return
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(full_path))
    pcall(vim.api.nvim_win_set_cursor, 0, { cursor_line, 0 })
  end, { desc = "[G]it go to [F]ile (new tab, with LSP)" })

  vim.keymap.set("n", "<leader>gy", function()
    local branch = ctx.get_branch()
    vim.fn.setreg("+", branch)
    vim.notify("Copied: " .. branch, vim.log.levels.INFO)
  end, { desc = "[G]it [Y]ank branch name" })

  vim.keymap.set("n", "<leader>gY", function()
    local branch = ctx.get_branch()
    local filepath = M.get_diffview_filepath()
    if filepath then
      local ref = branch .. ":" .. filepath
      vim.fn.setreg("+", ref)
      vim.notify("Copied: " .. ref, vim.log.levels.INFO)
    else
      vim.fn.setreg("+", branch)
      vim.notify("Copied branch (no file focused): " .. branch, vim.log.levels.INFO)
    end
  end, { desc = "[G]it [Y]ank branch:file ref" })

  vim.keymap.set("n", "g?", function()
    local help = ctx.help_text or [[
Review Keybindings:
  <leader>gf    go to file in new tab (with LSP)
  <leader>gy    copy branch name to clipboard
  <leader>gY    copy branch:file ref to clipboard
  g?            show this help
]]
    vim.notify(help, vim.log.levels.INFO)
  end, { desc = "Review help" })
end

return M
