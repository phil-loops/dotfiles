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

-- Get changed files between two commits
local function get_changed_files(old_hash, new_hash)
  local cmd = string.format('git diff --name-only %s..%s 2>/dev/null', old_hash, new_hash)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return output
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

  return state
end

-- Get all files that have changed since baseline, organized by branch
function M.get_changed_files_by_branch()
  if not state then
    M.load()
  end
  if not state or not state.baseline then
    return nil, 'No active review session'
  end

  local branches, parents = read_stack_file()
  local results = {
    branches = {},      -- { name, parent, files = { path, is_final, status } }
    file_info = {},     -- file_path -> { branches = {...}, final_branch = "..." }
    ordered_branches = {},
  }

  -- First pass: collect all changes per branch
  for _, branch in ipairs(branches) do
    local old_hash = state.baseline[branch]
    if old_hash then
      local new_hash = get_branch_hash(branch)
      if new_hash and old_hash ~= new_hash then
        local files = get_changed_files(old_hash, new_hash)
        if #files > 0 then
          results.branches[branch] = {
            name = branch,
            parent = parents[branch],
            files = files,
            old_hash = old_hash,
            new_hash = new_hash,
          }
          table.insert(results.ordered_branches, branch)

          -- Track which branches touch each file
          for _, filepath in ipairs(files) do
            results.file_info[filepath] = results.file_info[filepath] or { branches = {} }
            table.insert(results.file_info[filepath].branches, branch)
          end
        end
      end
    end
  end

  -- Second pass: determine which branch is "final" for each file
  -- (the last branch in the stack that modifies it)
  for filepath, info in pairs(results.file_info) do
    local final_branch = nil
    local final_index = 0
    for _, branch in ipairs(info.branches) do
      for i, b in ipairs(results.ordered_branches) do
        if b == branch and i > final_index then
          final_index = i
          final_branch = branch
        end
      end
    end
    info.final_branch = final_branch
  end

  return results
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
