-- Stack Blessed State
-- Tracks which commit SHA each file in a branch was last reviewed at.
-- "Blessed" means "I reviewed this file at this commit."
-- A file is stale if the branch tip has moved since the blessed SHA.
local M = {}

local blessed = {} -- branch -> { file -> sha }
local json_path = nil -- resolved on first use
local tip_cache = {} -- branch -> { sha, time }
local TIP_TTL = 10 -- seconds
local file_list_cache = {} -- branch -> string[] (file paths)

local function get_json_path()
  if json_path then return json_path end
  local git_dir = vim.fn.system("git rev-parse --git-dir 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  json_path = git_dir .. "/stack-blessed.json"
  return json_path
end

-- Get the current tip SHA for a branch (cached)
local function get_tip(branch)
  local cached = tip_cache[branch]
  local now = vim.loop.now()
  if cached and (now - cached.time) < (TIP_TTL * 1000) then
    return cached.sha
  end
  local sha = vim.fn.system("git rev-parse " .. branch .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  tip_cache[branch] = { sha = sha, time = now }
  return sha
end

-- Warm the tip cache for multiple branches in one git call
---@param branches string[]
function M.warm_tips(branches)
  local now = vim.loop.now()
  local need = {}
  for _, b in ipairs(branches) do
    local cached = tip_cache[b]
    if not cached or (now - cached.time) >= (TIP_TTL * 1000) then
      table.insert(need, b)
    end
  end
  if #need == 0 then return end

  local cmd = "git rev-parse " .. table.concat(need, " ") .. " 2>/dev/null"
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return end

  local i = 1
  for sha in output:gmatch("[^\n]+") do
    if need[i] then
      tip_cache[need[i]] = { sha = sha, time = now }
    end
    i = i + 1
  end
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

local save_timer = nil

function M.save()
  -- Debounce: write at most once per 100ms
  if save_timer then save_timer:stop() end
  save_timer = vim.defer_fn(function()
    local fp = get_json_path()
    if not fp then return end
    local content = vim.json.encode(blessed)
    vim.loop.fs_open(fp, "w", 438, function(err, fd)
      if err or not fd then return end
      vim.loop.fs_write(fd, content)
      vim.loop.fs_close(fd)
    end)
    save_timer = nil
  end, 50)
end

-- Bless a single file on a branch at the branch's current HEAD
---@param branch string
---@param filepath string
---@param quiet? boolean
function M.bless_file(branch, filepath, quiet)
  local sha = get_tip(branch)
  if not sha then return end
  if not blessed[branch] then blessed[branch] = {} end
  blessed[branch][filepath] = sha
  M.save()
  if not quiet then
    vim.notify(string.format("Blessed %s (%s)", filepath, sha:sub(1, 8)), vim.log.levels.INFO)
  end
end

-- Bless all files on a branch at current HEAD
---@param branch string
---@param parent string
function M.bless_branch(branch, parent)
  local sha = get_tip(branch)
  if not sha then return end

  -- Use cached file list if available, otherwise shell out
  local files = file_list_cache[branch]
  if not files then
    local cmd = string.format("git diff --name-only %s %s 2>/dev/null", parent, branch)
    local output = vim.fn.system(cmd):gsub("%s+$", "")
    if output == "" then return end
    files = {}
    for filepath in output:gmatch("[^\n]+") do
      table.insert(files, filepath)
    end
  end

  if not blessed[branch] then blessed[branch] = {} end
  for _, filepath in ipairs(files) do
    blessed[branch][filepath] = sha
  end
  M.save()
  vim.notify(string.format("Blessed %d files (%s)", #files, sha:sub(1, 8)), vim.log.levels.INFO)
end

-- Unbless a single file
---@param branch string
---@param filepath string
function M.unbless_file(branch, filepath)
  if blessed[branch] then
    blessed[branch][filepath] = nil
    if vim.tbl_isempty(blessed[branch]) then blessed[branch] = nil end
  end
  M.save()
end

-- Unbless all files on a branch
---@param branch string
function M.unbless_branch(branch)
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
-- Pure in-memory check: blessed SHA == branch tip SHA means clean.
---@param branch string
---@param filepath string
---@return string status "clean" | "stale" | "unblessed"
function M.file_status(branch, filepath)
  local bsha = M.get_sha(branch, filepath)
  if not bsha then return "unblessed" end
  local tip = get_tip(branch)
  if not tip then return "unblessed" end
  return bsha == tip and "clean" or "stale"
end

-- Branch-level summary — no per-file git calls, all in-memory.
-- Returns: { status, total, reviewed, stale_count, stale_files }
---@param branch string
---@param parent string
---@return table
function M.summary(branch, parent)
  local branch_blessed = blessed[branch]
  if not branch_blessed or vim.tbl_isempty(branch_blessed) then
    return { status = "unblessed", total = 0, reviewed = 0, stale_count = 0, stale_files = {} }
  end

  local tip = get_tip(branch)
  if not tip then
    return { status = "unblessed", total = 0, reviewed = 0, stale_count = 0, stale_files = {} }
  end

  -- Count from blessed data (we know which files were blessed)
  local reviewed = 0
  local stale_list = {}
  local total = 0

  for filepath, sha in pairs(branch_blessed) do
    total = total + 1
    if sha == tip then
      reviewed = reviewed + 1
    else
      table.insert(stale_list, filepath)
    end
  end

  local status
  if total == 0 then
    status = "unblessed"
  elseif #stale_list > 0 then
    status = "stale"
  elseif reviewed == total then
    status = "clean"
  else
    status = "partial"
  end

  return {
    status = status,
    total = total,
    reviewed = reviewed,
    stale_count = #stale_list,
    stale_files = stale_list,
  }
end

-- Compat: branch_status for panel display
---@param branch string
---@param parent string
---@return string
function M.branch_status(branch, parent)
  return M.summary(branch, parent).status
end

-- Compat: stale_files
---@param branch string
---@param parent string
---@return string[]
function M.stale_files(branch, parent)
  return M.summary(branch, parent).stale_files
end

-- Pre-compute file lists for all branches in the chain (one git call each, but only once)
---@param chain table[] -- { {branch, parent}, ... }
function M.warm_file_counts(chain)
  for _, item in ipairs(chain) do
    if not file_list_cache[item.branch] and item.parent and item.parent ~= "" then
      local cmd = string.format("git diff --name-only %s %s 2>/dev/null", item.parent, item.branch)
      local output = vim.fn.system(cmd):gsub("%s+$", "")
      local files = {}
      if output ~= "" then
        for f in output:gmatch("[^\n]+") do
          table.insert(files, f)
        end
      end
      file_list_cache[item.branch] = files
    end
  end
end

-- Get total file count for a branch (from cache)
---@param branch string
---@return number
function M.file_count(branch)
  return file_list_cache[branch] and #file_list_cache[branch] or 0
end

-- Get cached file list for a branch
---@param branch string
---@return string[]
function M.file_list(branch)
  return file_list_cache[branch] or {}
end

-- Invalidate tip cache (e.g. after pushing)
function M.invalidate(branch)
  if branch then
    tip_cache[branch] = nil
  else
    tip_cache = {}
  end
end

return M
