-- Stack Git-Town Integration
-- Shared module for reading git-town lineage
-- Used by stack-nav, stack-review-state, stack-file-inspect

local M = {}

-- Cache for lineage data (invalidated on branch change)
local cache = {
  parents = nil,
  main_branch = nil,
  last_check = 0,
}

local CACHE_TTL_MS = 5000  -- 5 seconds

-- Read git-town lineage from git config
function M.get_lineage()
  local now = vim.loop.now()
  if cache.parents and (now - cache.last_check) < CACHE_TTL_MS then
    return cache.parents, cache.main_branch
  end

  local output = vim.fn.systemlist('git config --local --list 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return {}, 'main'
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

  cache.parents = parents
  cache.main_branch = main_branch
  cache.last_check = now

  return parents, main_branch
end

-- Get parent of a branch
function M.get_parent(branch)
  local parents, main_branch = M.get_lineage()
  return parents[branch] or (branch ~= main_branch and main_branch or nil)
end

-- Get main branch name
function M.get_main_branch()
  local _, main_branch = M.get_lineage()
  return main_branch
end

-- Get current branch
function M.get_current_branch()
  local result = vim.fn.system('git branch --show-current 2>/dev/null')
  return result:gsub('%s+$', '')
end

-- Get all branches in order (root to leaves) for current stack
function M.get_stack_branches()
  local parents, main_branch = M.get_lineage()
  local current = M.get_current_branch()

  -- Build ancestor chain (current -> ... -> main)
  local ancestors = {}
  local branch = current
  while branch and branch ~= main_branch and parents[branch] do
    table.insert(ancestors, 1, branch)
    branch = parents[branch]
  end

  -- Add main at the start
  if #ancestors > 0 or current == main_branch then
    table.insert(ancestors, 1, main_branch)
  end

  -- If current branch isn't tracked, just return it alone
  if #ancestors == 0 then
    return { current }, 1
  end

  -- Find descendants
  local children = {}
  for child, parent in pairs(parents) do
    children[parent] = children[parent] or {}
    table.insert(children[parent], child)
  end

  -- Sort children alphabetically for consistent ordering
  for _, child_list in pairs(children) do
    table.sort(child_list)
  end

  -- BFS from current to find all descendants
  local descendants = {}
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

  -- Combine
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

-- Get ordered list of all tracked branches (for full stack view)
function M.get_all_branches()
  local parents, main_branch = M.get_lineage()

  -- Build children map
  local children = {}
  for child, parent in pairs(parents) do
    children[parent] = children[parent] or {}
    table.insert(children[parent], child)
  end

  -- Sort children
  for _, child_list in pairs(children) do
    table.sort(child_list)
  end

  -- DFS from main to get ordered list
  local result = {}
  local function dfs(branch, depth)
    table.insert(result, { branch = branch, depth = depth })
    if children[branch] then
      for _, child in ipairs(children[branch]) do
        dfs(child, depth + 1)
      end
    end
  end

  dfs(main_branch, 0)
  return result
end

-- Invalidate cache (call after git operations)
function M.invalidate_cache()
  cache.parents = nil
  cache.main_branch = nil
  cache.last_check = 0
end

-- Check if we're in a git-town managed repo
function M.is_git_town_repo()
  local parents, _ = M.get_lineage()
  return not vim.tbl_isempty(parents)
end

return M
