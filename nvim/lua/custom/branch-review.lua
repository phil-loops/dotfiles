-- Branch Review - review a single branch against main with blessing support
-- Simpler version of stack-review without stack parent tracking
local M = {}
local blessed = require("custom.stack-blessed")
local bindings = require("custom.review-bindings")

-- State
local branch_name = ""
local base_name = "main"

function M.setup(data)
  branch_name = data.branch or ""
  base_name = data.base or "main"

  -- Load blessed state and warm caches
  blessed.load()
  local chain = { { branch = branch_name, parent = base_name } }
  blessed.warm_file_counts(chain)
  blessed.warm_tips({ branch_name })

  -- Show initial blessed status
  local bsum = blessed.summary(branch_name, base_name)
  local total_files = blessed.file_count(branch_name)
  if bsum.status == "clean" and bsum.reviewed >= total_files then
    vim.notify(string.format("Branch review: %s (all %d files blessed)", branch_name, total_files), vim.log.levels.INFO)
  elseif bsum.reviewed > 0 then
    vim.notify(string.format("Branch review: %s (%d/%d blessed)", branch_name, bsum.reviewed, total_files), vim.log.levels.INFO)
  else
    vim.notify(string.format("Branch review: %s (%d files)", branch_name, total_files), vim.log.levels.INFO)
  end

  -- Build unreviewed list for this single branch
  local function get_unreviewed()
    local results = {}
    local lines = vim.fn.systemlist(string.format("git diff --name-only %s..%s 2>/dev/null", base_name, branch_name))
    if vim.v.shell_error ~= 0 then return results end

    local known = {}
    for _, fp in ipairs(blessed.file_list(branch_name)) do
      known[fp] = true
    end
    for _, fp in ipairs(lines) do
      local status = known[fp] and blessed.file_status(branch_name, fp) or "unblessed"
      if status ~= "clean" then
        table.insert(results, { filepath = fp, status = status })
      end
    end
    return results
  end

  -- Set up shared keybindings
  bindings.setup({
    get_branch = function() return branch_name end,
    get_base = function() return base_name end,
    get_unreviewed = get_unreviewed,
    on_blessed = function()
      bindings.refresh_diffview_panel(branch_name)
    end,
    help_text = [[
Branch Review Keybindings:
  ]u / [u       next/prev unreviewed file
  <leader>sb    bless current file
  <leader>sB    bless all files on branch
  go            open file in new tab (with LSP)
  gd            show delta since blessed (new tab)
  gy            copy branch:file ref to clipboard
  g?            show this help

  Blessed = "I reviewed this file's content" (survives rebases)
  ✓ = all clean  ! = stale files
]],
  })

  -- Refresh diffview panel with blessed indicators after it loads
  vim.defer_fn(function()
    bindings.refresh_diffview_panel(branch_name)
  end, 200)
end

return M
