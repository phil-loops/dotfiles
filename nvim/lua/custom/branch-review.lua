-- Branch Review - review a single branch against main
-- Branch-against-base review without stack parent tracking
local M = {}
local bindings = require("custom.review-bindings")

function M.setup(data)
  local branch_name = data.branch or ""
  local base_name = data.base or "main"
  vim.notify(string.format("Branch review: %s", branch_name), vim.log.levels.INFO)

  bindings.setup({
    get_branch = function() return branch_name end,
    get_base = function() return base_name end,
    help_text = [[
Branch Review Keybindings:
  <leader>gf    open file in new tab (with LSP)
  <leader>gy    copy branch name to clipboard
  <leader>gY    copy branch:file ref to clipboard
  g?            show this help
]],
  })
end

return M
