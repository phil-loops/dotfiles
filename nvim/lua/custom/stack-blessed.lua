-- Stack Blessed State
-- Tracks which commit SHA each file in a branch was last reviewed at.
-- "Blessed" means "I reviewed this file at this commit."
-- A file is stale if `git diff <blessed_sha> <branch> -- <file>` is non-empty.
local M = {}

local blessed = {} -- branch -> { file -> sha }
local json_path = nil -- resolved on first use
local status_cache = {} -- "branch:file" -> { status, time }
local CACHE_TTL = 5 -- seconds

local function get_json_path()
  if json_path then return json_path end
  local git_dir = vim.fn.system("git rev-parse --git-dir 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  json_path = git_dir .. "/stack-blessed.json"
  return json_path
end

function M.load()
  local fp = get_json_path()
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
  local fp = get_json_path()
  if not fp then return end
  local f = io.open(fp, "w")
  if not f then
    vim.notify("Could not write " .. fp, vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(blessed))
  f:close()
end

-- Bless a single file on a branch at the branch's current HEAD
---@param branch string
---@param filepath string
function M.bless_file(branch, filepath)
  local sha = vim.fn.system("git rev-parse " .. branch .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then
    vim.notify("Could not resolve " .. branch, vim.log.levels.ERROR)
    return
  end
  if not blessed[branch] then blessed[branch] = {} end
  blessed[branch][filepath] = sha
  status_cache[branch .. ":" .. filepath] = nil
  M.save()
  vim.notify(string.format("Blessed %s @ %s (%s)", filepath, branch, sha:sub(1, 8)), vim.log.levels.INFO)
end

-- Bless all files on a branch at current HEAD
---@param branch string
---@param parent string
function M.bless_branch(branch, parent)
  local sha = vim.fn.system("git rev-parse " .. branch .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then
    vim.notify("Could not resolve " .. branch, vim.log.levels.ERROR)
    return
  end
  -- Get all files in this branch's diff
  local cmd = string.format("git diff --name-only %s %s 2>/dev/null", parent, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if output == "" then return end

  if not blessed[branch] then blessed[branch] = {} end
  local count = 0
  for filepath in output:gmatch("[^\n]+") do
    blessed[branch][filepath] = sha
    status_cache[branch .. ":" .. filepath] = nil
    count = count + 1
  end
  M.save()
  vim.notify(string.format("Blessed %d files on %s at %s", count, branch, sha:sub(1, 8)), vim.log.levels.INFO)
end

-- Unbless a single file
---@param branch string
---@param filepath string
function M.unbless_file(branch, filepath)
  if blessed[branch] then
    blessed[branch][filepath] = nil
    if vim.tbl_isempty(blessed[branch]) then blessed[branch] = nil end
  end
  status_cache[branch .. ":" .. filepath] = nil
  M.save()
end

-- Unbless all files on a branch
---@param branch string
function M.unbless_branch(branch)
  if blessed[branch] then
    for filepath, _ in pairs(blessed[branch]) do
      status_cache[branch .. ":" .. filepath] = nil
    end
  end
  blessed[branch] = nil
  M.save()
end

-- Get blessed SHA for a file (or nil)
---@param branch string
---@param filepath string
---@return string|nil
function M.get_sha(branch, filepath)
  return blessed[branch] and blessed[branch][filepath]
end

-- Check if a single file is clean/stale/unblessed
---@param branch string
---@param filepath string
---@return string status "clean" | "stale" | "unblessed"
function M.file_status(branch, filepath)
  local sha = M.get_sha(branch, filepath)
  if not sha then return "unblessed" end

  local cache_key = branch .. ":" .. filepath
  local cached = status_cache[cache_key]
  if cached and (vim.loop.now() - cached.time) < (CACHE_TTL * 1000) then
    return cached.status
  end

  local cmd = string.format("git diff %s %s -- %s 2>/dev/null | wc -c",
    vim.fn.shellescape(sha), vim.fn.shellescape(branch), vim.fn.shellescape(filepath))
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  local bytes = tonumber(output) or 0
  local status = bytes == 0 and "clean" or "stale"

  status_cache[cache_key] = { status = status, time = vim.loop.now() }
  return status
end

-- Branch-level status derived from per-file statuses
-- Returns: "clean" | "stale" | "partial" | "unblessed"
---@param branch string
---@param parent string
---@return string status
function M.branch_status(branch, parent)
  -- Get all files in this branch's diff
  local cmd = string.format("git diff --name-only %s %s 2>/dev/null", parent, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if output == "" then return "clean" end

  local total = 0
  local clean_count = 0
  local has_stale = false

  for filepath in output:gmatch("[^\n]+") do
    total = total + 1
    local fs = M.file_status(branch, filepath)
    if fs == "clean" then
      clean_count = clean_count + 1
    elseif fs == "stale" then
      has_stale = true
    end
  end

  if clean_count == total then return "clean" end
  if has_stale then return "stale" end
  if clean_count > 0 then return "partial" end
  return "unblessed"
end

-- Get list of stale files for a branch
---@param branch string
---@param parent string
---@return string[] file_paths
function M.stale_files(branch, parent)
  local cmd = string.format("git diff --name-only %s %s 2>/dev/null", parent, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if output == "" then return {} end

  local stale = {}
  for filepath in output:gmatch("[^\n]+") do
    local fs = M.file_status(branch, filepath)
    if fs == "stale" then
      table.insert(stale, filepath)
    end
  end
  return stale
end

-- Summary for a branch
---@param branch string
---@param parent string
---@return table
function M.summary(branch, parent)
  local cmd = string.format("git diff --name-only %s %s 2>/dev/null", parent, branch)
  local output = vim.fn.system(cmd):gsub("%s+$", "")

  local total = 0
  local reviewed = 0
  local stale_list = {}

  if output ~= "" then
    for filepath in output:gmatch("[^\n]+") do
      total = total + 1
      local fs = M.file_status(branch, filepath)
      if fs == "clean" then
        reviewed = reviewed + 1
      elseif fs == "stale" then
        table.insert(stale_list, filepath)
      end
    end
  end

  return {
    status = M.branch_status(branch, parent),
    total = total,
    reviewed = reviewed,
    stale_count = #stale_list,
    stale_files = stale_list,
  }
end

return M
