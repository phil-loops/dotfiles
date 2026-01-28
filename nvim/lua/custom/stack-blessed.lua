-- Stack Blessed State
-- Tracks which commit SHA each branch was last reviewed at.
-- "Blessed" means "I reviewed this branch at this commit."
-- A file is stale if `git diff <blessed_sha> HEAD -- <file>` is non-empty.
local M = {}

local blessed = {} -- branch -> sha
local file_path = nil -- resolved on first use
local status_cache = {} -- branch -> { status, time }
local CACHE_TTL = 5 -- seconds

local function get_file_path()
  if file_path then return file_path end
  local git_dir = vim.fn.system("git rev-parse --git-dir 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  file_path = git_dir .. "/stack-blessed.json"
  return file_path
end

function M.load()
  local fp = get_file_path()
  if not fp then return end
  local f = io.open(fp, "r")
  if not f then
    blessed = {}
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    blessed = data
  else
    blessed = {}
  end
end

function M.save()
  local fp = get_file_path()
  if not fp then return end
  local f = io.open(fp, "w")
  if not f then
    vim.notify("Could not write " .. fp, vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(blessed))
  f:close()
end

-- Bless a branch at current HEAD
---@param branch string
function M.bless(branch)
  local sha = vim.fn.system("git rev-parse " .. branch .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then
    vim.notify("Could not resolve " .. branch, vim.log.levels.ERROR)
    return
  end
  blessed[branch] = sha
  M.invalidate(branch)
  M.save()
  vim.notify(string.format("Blessed %s at %s", branch, sha:sub(1, 8)), vim.log.levels.INFO)
end

-- Unbless a branch
---@param branch string
function M.unbless(branch)
  blessed[branch] = nil
  M.invalidate(branch)
  M.save()
end

-- Get blessed SHA for a branch (or nil)
---@param branch string
---@return string|nil
function M.get_sha(branch)
  return blessed[branch]
end

-- Invalidate cache for a branch (call after bless/unbless)
function M.invalidate(branch)
  status_cache[branch] = nil
end

-- Check if a branch has any changes since blessed
-- Returns: "clean" | "stale" | "unblessed"
---@param branch string
---@param parent string
---@return string status
function M.branch_status(branch, parent)
  local sha = blessed[branch]
  if not sha then return "unblessed" end

  -- Check cache
  local cached = status_cache[branch]
  if cached and (vim.loop.now() - cached.time) < (CACHE_TTL * 1000) then
    return cached.status
  end

  -- Compare the diff at blessed time vs now
  local cmd = string.format("git diff %s %s 2>/dev/null | wc -c", sha, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  local bytes = tonumber(output) or 0
  local status = bytes == 0 and "clean" or "stale"

  status_cache[branch] = { status = status, time = vim.loop.now() }
  return status
end

-- Get list of stale files for a branch (files whose diff changed since blessed)
---@param branch string
---@param parent string
---@return string[] file_paths
function M.stale_files(branch, parent)
  local sha = blessed[branch]
  if not sha then return {} end

  -- Files that differ between blessed snapshot and current branch tip
  local cmd = string.format("git diff --name-only %s %s 2>/dev/null", sha, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if output == "" then return {} end

  local files = {}
  for line in output:gmatch("[^\n]+") do
    table.insert(files, line)
  end
  return files
end

-- Summary for a branch: { status, sha, stale_count }
---@param branch string
---@param parent string
---@return table
function M.summary(branch, parent)
  local sha = blessed[branch]
  local status = M.branch_status(branch, parent)
  local stale = (status == "stale") and M.stale_files(branch, parent) or {}
  return {
    status = status,
    sha = sha,
    stale_count = #stale,
    stale_files = stale,
  }
end

return M
