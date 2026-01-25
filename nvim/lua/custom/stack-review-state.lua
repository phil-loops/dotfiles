-- Stack Review State Management
-- Unified state for tracking review progress across branches and files

local M = {}

-- State structure:
-- {
--   baseline = { branch1 = "hash1", branch2 = "hash2", ... },
--   files = {
--     ["src/foo.ts"] = { reviewed = true },
--     ["src/bar.ts"] = { reviewed = false, note = "check error handling" },
--   },
--   position = { branch_index = 2, file_path = "src/bar.ts" },
--   started_at = "2024-01-23T12:00:00Z",
-- }

local state = nil
local state_path = nil

-- In-memory cache for computed branch/file data
local cache = {
  data = nil,           -- The computed get_changed_files_by_branch result
  computing = false,    -- Whether an async refresh is in progress
  last_updated = 0,     -- vim.loop.now() timestamp
  subscribers = {},     -- Callbacks to notify when cache updates
}

-- Subscribe to cache updates (returns unsubscribe function)
function M.on_cache_update(callback)
  table.insert(cache.subscribers, callback)
  return function()
    for i, cb in ipairs(cache.subscribers) do
      if cb == callback then
        table.remove(cache.subscribers, i)
        return
      end
    end
  end
end

-- Notify all subscribers that cache updated
local function notify_subscribers()
  for _, callback in ipairs(cache.subscribers) do
    vim.schedule(function()
      pcall(callback, cache.data)
    end)
  end
end

-- Check if cache is available
function M.has_cache()
  return cache.data ~= nil
end

-- Check if currently computing
function M.is_computing()
  return cache.computing
end

-- Get git root directory
local function get_git_root()
  local result = vim.fn.systemlist('git rev-parse --show-toplevel')[1]
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- Get repo name from git root
local function get_repo_name()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end
  return vim.fn.fnamemodify(git_root, ':t')
end

-- Get path to the state directory for this repo
local function get_state_dir()
  local repo_name = get_repo_name()
  if not repo_name then
    return nil
  end
  return vim.fn.expand('~/.local/share/stack/' .. repo_name)
end

-- Get path to review-state.json
local function get_state_path()
  local state_dir = get_state_dir()
  if not state_dir then
    return nil
  end
  return state_dir .. '/review-state.json'
end

-- Read stack file to get ordered branch list
local function read_stack_file()
  local state_dir = get_state_dir()
  if not state_dir then
    return {}, {}
  end

  local stack_path = state_dir .. '/stack'
  local file = io.open(stack_path, 'r')
  if not file then
    return {}, {}
  end

  local branches = {}
  local parents = {}
  for line in file:lines() do
    local child, parent = line:match('^([^:]+):(.+)$')
    if child and parent then
      table.insert(branches, child)
      parents[child] = parent
    end
  end
  file:close()

  return branches, parents
end

-- Get current hash for a branch
local function get_branch_hash(branch)
  local result = vim.fn.systemlist('git rev-parse ' .. branch .. ' 2>/dev/null')[1]
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- Get changed files between two commits (sync version for fallback)
-- Returns files list and file_status table
local function get_changed_files(old_ref, new_ref)
  local cmd = string.format('git diff --name-status %s..%s 2>/dev/null', old_ref, new_ref)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}, {}
  end
  local files = {}
  local file_status = {}
  for _, line in ipairs(output) do
    local status, filepath = line:match('^(%w)%s+(.+)$')
    if status and filepath then
      table.insert(files, filepath)
      file_status[filepath] = status
    end
  end
  return files, file_status
end

-- Async git command execution
-- Runs a git command and calls callback with output lines
local function git_async(cmd, callback)
  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= '' then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      callback(output, exit_code)
    end,
  })
end

-- Async refresh of cache data
-- Computes all branch/file changes in background, then updates cache
function M.refresh_async(force)
  -- Don't start another refresh if one is in progress (unless forced)
  if cache.computing and not force then
    return
  end

  -- Load state if needed
  if not state then
    M.load()
  end
  if not state or not state.baseline then
    return
  end

  cache.computing = true

  local branches, parents = read_stack_file()
  if #branches == 0 then
    cache.computing = false
    return
  end

  -- We'll collect results here
  local results = {
    branches = {},
    file_info = {},
    ordered_branches = {},
  }

  -- Track pending operations
  local pending = 0
  local branch_hashes = {}

  -- First, get current hashes for all branches (async)
  for _, branch in ipairs(branches) do
    pending = pending + 1
    git_async({ 'git', 'rev-parse', branch }, function(output, exit_code)
      if exit_code == 0 and output[1] then
        branch_hashes[branch] = output[1]
      end
      pending = pending - 1

      -- Once all hashes are fetched, get diffs
      if pending == 0 then
        M._process_branch_diffs(branches, parents, branch_hashes, results)
      end
    end)
  end
end

-- Internal: Process diffs for all branches (called after hashes are fetched)
function M._process_branch_diffs(branches, parents, branch_hashes, results)
  local pending = 0
  local branches_with_changes = {}

  -- Find branches that have changes
  for _, branch in ipairs(branches) do
    local old_hash = state.baseline[branch]
    local new_hash = branch_hashes[branch]
    if old_hash and new_hash and old_hash ~= new_hash then
      table.insert(branches_with_changes, {
        name = branch,
        parent = parents[branch],
        old_hash = old_hash,
        new_hash = new_hash,
      })
    end
  end

  if #branches_with_changes == 0 then
    -- No changes, update cache with empty results
    cache.data = results
    cache.computing = false
    cache.last_updated = vim.loop.now()
    notify_subscribers()
    return
  end

  -- Get file diffs for each branch with changes
  -- Use parent..branch to show only what this branch introduces (not inherited changes)
  for _, branch_info in ipairs(branches_with_changes) do
    pending = pending + 1
    -- Diff against parent branch to show only branch-specific changes
    local diff_base = branch_info.parent or 'main'
    -- Use --diff-filter to detect new files (A=added) vs modified (M)
    local cmd = { 'git', 'diff', '--name-status', diff_base .. '..' .. branch_info.name }
    git_async(cmd, function(output, exit_code)
      if exit_code == 0 and #output > 0 then
        local files = {}
        local file_status = {}  -- filepath -> 'A' (added) or 'M' (modified) or 'D' (deleted)
        for _, line in ipairs(output) do
          local status, filepath = line:match('^(%w)%s+(.+)$')
          if status and filepath then
            table.insert(files, filepath)
            file_status[filepath] = status
          end
        end

        if #files > 0 then
          results.branches[branch_info.name] = {
            name = branch_info.name,
            parent = branch_info.parent,
            files = files,
            file_status = file_status,
            old_hash = branch_info.old_hash,
            new_hash = branch_info.new_hash,
          }
          table.insert(results.ordered_branches, branch_info.name)

          -- Track which branches touch each file
          for _, filepath in ipairs(files) do
            results.file_info[filepath] = results.file_info[filepath] or { branches = {}, status = {} }
            table.insert(results.file_info[filepath].branches, branch_info.name)
            results.file_info[filepath].status[branch_info.name] = file_status[filepath]
          end
        end
      end

      pending = pending - 1
      if pending == 0 then
        -- All diffs complete, finalize results
        M._finalize_cache(results)
      end
    end)
  end
end

-- Internal: Finalize cache after all async operations complete
function M._finalize_cache(results)
  -- Sort ordered_branches to match original stack order
  local branches, _ = read_stack_file()
  local branch_order = {}
  for i, b in ipairs(branches) do
    branch_order[b] = i
  end
  table.sort(results.ordered_branches, function(a, b)
    return (branch_order[a] or 999) < (branch_order[b] or 999)
  end)

  -- Determine which branch is "first" and "final" for each file
  for filepath, info in pairs(results.file_info) do
    local first_branch = nil
    local first_index = 999
    local final_branch = nil
    local final_index = 0

    for _, branch in ipairs(info.branches) do
      local idx = branch_order[branch] or 0
      if idx < first_index then
        first_index = idx
        first_branch = branch
      end
      if idx > final_index then
        final_index = idx
        final_branch = branch
      end
    end

    info.first_branch = first_branch
    info.final_branch = final_branch

    -- Determine if file was introduced (added) in its first branch
    -- Status 'A' means added, anything else means it existed before
    if first_branch and info.status and info.status[first_branch] == 'A' then
      info.introduced_in = first_branch
    end
  end

  -- Update cache
  cache.data = results
  cache.computing = false
  cache.last_updated = vim.loop.now()

  -- Notify subscribers
  notify_subscribers()
end

-- Load state from disk
function M.load()
  state_path = get_state_path()
  if not state_path then
    return nil, 'Not in a git repository with stack tracking'
  end

  local file = io.open(state_path, 'r')
  if not file then
    state = nil
    return nil, 'No active review session'
  end

  local content = file:read('*all')
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    state = nil
    return nil, 'Failed to parse review state'
  end

  state = data
  return state
end

-- Save state to disk
function M.save()
  if not state then
    return false, 'No active review session'
  end

  state_path = state_path or get_state_path()
  if not state_path then
    return false, 'Not in a git repository with stack tracking'
  end

  local ok, json = pcall(vim.json.encode, state)
  if not ok then
    return false, 'Failed to serialize review state'
  end

  local file = io.open(state_path, 'w')
  if not file then
    return false, 'Failed to write review state'
  end

  file:write(json)
  file:close()
  return true
end

-- Delete state file (for complete_review)
function M.delete()
  state_path = state_path or get_state_path()
  if state_path then
    os.remove(state_path)
  end
  state = nil
end

-- Check if an active review session exists
function M.has_active_session()
  if state then
    return true
  end
  local loaded = M.load()
  return loaded ~= nil
end

-- Get current state (read-only)
function M.get()
  if not state then
    M.load()
  end
  return state
end

-- Start a new review session
-- Uses current branch hashes as baseline
function M.start_review()
  local branches, parents = read_stack_file()
  if #branches == 0 then
    return nil, 'Not in a stack (no branches tracked)'
  end

  -- Build baseline from current branch hashes
  local baseline = {}
  for _, branch in ipairs(branches) do
    local hash = get_branch_hash(branch)
    if hash then
      baseline[branch] = hash
    end
  end

  -- Check for existing ack file to use as baseline instead
  local state_dir = get_state_dir()
  local ack_path = state_dir .. '/ack'
  local ack_file = io.open(ack_path, 'r')
  if ack_file then
    local content = ack_file:read('*all')
    ack_file:close()
    local ok, ack_data = pcall(vim.json.decode, content)
    if ok and ack_data and ack_data.branches then
      -- Use ack baseline if available
      baseline = ack_data.branches
    end
  end

  state = {
    baseline = baseline,
    files = {},
    position = { branch_index = 1, file_path = nil },
    started_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }

  local ok, err = M.save()
  if not ok then
    return nil, err
  end

  -- Immediately start populating cache in background
  M.refresh_async()

  return state
end

-- Get all files that have changed since baseline, organized by branch
-- Returns cached data immediately if available, triggers async refresh
function M.get_changed_files_by_branch()
  if not state then
    M.load()
  end
  if not state or not state.baseline then
    return nil, 'No active review session'
  end

  -- If we have cached data, return it immediately
  if cache.data then
    -- Trigger background refresh if data might be stale (older than 30 seconds)
    local age = vim.loop.now() - cache.last_updated
    if age > 30000 and not cache.computing then
      M.refresh_async()
    end
    return cache.data
  end

  -- No cache - trigger async refresh and return empty for now
  -- (caller should subscribe to updates or call get_changed_files_by_branch_sync)
  if not cache.computing then
    M.refresh_async()
  end

  return nil, 'Computing changes...'
end

-- Synchronous version (blocks UI - use sparingly, e.g., for initial load fallback)
function M.get_changed_files_by_branch_sync()
  if not state then
    M.load()
  end
  if not state or not state.baseline then
    return nil, 'No active review session'
  end

  local branches, parents = read_stack_file()
  local results = {
    branches = {},
    file_info = {},
    ordered_branches = {},
  }

  -- First pass: collect all changes per branch
  -- Use parent..branch to show only branch-specific changes (not inherited from main)
  for _, branch in ipairs(branches) do
    local old_hash = state.baseline[branch]
    if old_hash then
      local new_hash = get_branch_hash(branch)
      if new_hash and old_hash ~= new_hash then
        -- Diff against parent branch, not old hash
        local parent = parents[branch] or 'main'
        local files, file_status = get_changed_files(parent, branch)
        if #files > 0 then
          results.branches[branch] = {
            name = branch,
            parent = parent,
            files = files,
            file_status = file_status,
            old_hash = old_hash,
            new_hash = new_hash,
          }
          table.insert(results.ordered_branches, branch)

          -- Track which branches touch each file
          for _, filepath in ipairs(files) do
            results.file_info[filepath] = results.file_info[filepath] or { branches = {}, status = {} }
            table.insert(results.file_info[filepath].branches, branch)
            results.file_info[filepath].status[branch] = file_status[filepath]
          end
        end
      end
    end
  end

  -- Second pass: determine which branch is "first" and "final" for each file
  for filepath, info in pairs(results.file_info) do
    local first_branch = nil
    local first_index = 999
    local final_branch = nil
    local final_index = 0

    for _, branch in ipairs(info.branches) do
      for i, b in ipairs(results.ordered_branches) do
        if b == branch then
          if i < first_index then
            first_index = i
            first_branch = branch
          end
          if i > final_index then
            final_index = i
            final_branch = branch
          end
        end
      end
    end

    info.first_branch = first_branch
    info.final_branch = final_branch

    -- Determine if file was introduced (added) in its first branch
    if first_branch and info.status and info.status[first_branch] == 'A' then
      info.introduced_in = first_branch
    end
  end

  -- Update cache with sync result
  cache.data = results
  cache.last_updated = vim.loop.now()

  return results
end

-- Invalidate cache (call after git operations)
function M.invalidate_cache()
  cache.data = nil
  cache.last_updated = 0
end

-- Force refresh cache now (async)
function M.refresh_cache()
  M.invalidate_cache()
  M.refresh_async(true)
end

-- Mark a file as reviewed
function M.mark_reviewed(filepath, reviewed)
  if not state then
    M.load()
  end
  if not state then
    return false, 'No active review session'
  end

  reviewed = reviewed ~= false -- default to true
  state.files = state.files or {}
  state.files[filepath] = state.files[filepath] or {}
  state.files[filepath].reviewed = reviewed

  return M.save()
end

-- Check if a file is reviewed
function M.is_reviewed(filepath)
  if not state then
    M.load()
  end
  if not state or not state.files then
    return false
  end
  return state.files[filepath] and state.files[filepath].reviewed == true
end

-- Add a note to a file
function M.add_note(filepath, note)
  if not state then
    M.load()
  end
  if not state then
    return false, 'No active review session'
  end

  state.files = state.files or {}
  state.files[filepath] = state.files[filepath] or {}
  state.files[filepath].note = note

  return M.save()
end

-- Get note for a file
function M.get_note(filepath)
  if not state then
    M.load()
  end
  if not state or not state.files or not state.files[filepath] then
    return nil
  end
  return state.files[filepath].note
end

-- Update current position
function M.set_position(branch_index, file_path)
  if not state then
    M.load()
  end
  if not state then
    return false, 'No active review session'
  end

  state.position = {
    branch_index = branch_index,
    file_path = file_path,
  }

  return M.save()
end

-- Get current position
function M.get_position()
  if not state then
    M.load()
  end
  if not state then
    return nil
  end
  return state.position
end

-- Get progress stats
function M.get_progress()
  if not state then
    M.load()
  end
  if not state then
    return { reviewed = 0, total = 0, percent = 0 }
  end

  local changes = M.get_changed_files_by_branch()
  if not changes then
    return { reviewed = 0, total = 0, percent = 0 }
  end

  local total = vim.tbl_count(changes.file_info)
  local reviewed = 0

  for filepath, _ in pairs(changes.file_info) do
    if M.is_reviewed(filepath) then
      reviewed = reviewed + 1
    end
  end

  local percent = total > 0 and math.floor((reviewed / total) * 100) or 100

  return {
    reviewed = reviewed,
    total = total,
    percent = percent,
  }
end

-- Complete review and write new ack file
function M.complete_review()
  if not state then
    M.load()
  end
  if not state then
    return false, 'No active review session'
  end

  local progress = M.get_progress()
  if progress.reviewed < progress.total then
    return false, string.format('Review incomplete: %d/%d files reviewed', progress.reviewed, progress.total)
  end

  -- Write new ack file with current branch hashes
  local state_dir = get_state_dir()
  local ack_path = state_dir .. '/ack'

  local branches = read_stack_file()
  local new_baseline = {}
  for _, branch in ipairs(branches) do
    local hash = get_branch_hash(branch)
    if hash then
      new_baseline[branch] = hash
    end
  end

  local ack_data = {
    timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    operation = 'ack',
    branches = new_baseline,
  }

  local ok, json = pcall(vim.json.encode, ack_data)
  if not ok then
    return false, 'Failed to serialize ack data'
  end

  local file = io.open(ack_path, 'w')
  if not file then
    return false, 'Failed to write ack file'
  end

  file:write(json)
  file:close()

  -- Delete review state file
  M.delete()

  return true
end

-- Force complete (skip unreviewed files check)
function M.force_complete()
  if not state then
    M.load()
  end
  if not state then
    return false, 'No active review session'
  end

  -- Write new ack file with current branch hashes
  local state_dir = get_state_dir()
  local ack_path = state_dir .. '/ack'

  local branches = read_stack_file()
  local new_baseline = {}
  for _, branch in ipairs(branches) do
    local hash = get_branch_hash(branch)
    if hash then
      new_baseline[branch] = hash
    end
  end

  local ack_data = {
    timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    operation = 'ack',
    branches = new_baseline,
  }

  local ok, json = pcall(vim.json.encode, ack_data)
  if not ok then
    return false, 'Failed to serialize ack data'
  end

  local file = io.open(ack_path, 'w')
  if not file then
    return false, 'Failed to write ack file'
  end

  file:write(json)
  file:close()

  -- Delete review state file
  M.delete()

  return true
end

-- Cancel review (delete state without writing ack)
function M.cancel_review()
  M.delete()
  return true
end

return M
