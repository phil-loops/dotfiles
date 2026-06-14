-- Stack Blessed State
-- Tracks the blob hash (content hash) of each file when it was reviewed.
-- "Blessed" means "I reviewed this file's content."
-- A file is stale if its content has changed since blessing (blob hash differs).
-- Uses blob hashes so rebases don't invalidate blessings.
local M = {}

local blessed = {} -- branch -> { file -> blob_hash }
local json_path = nil -- resolved on first use
local blob_cache = {} -- "branch:filepath" -> { hash, time }
local BLOB_TTL = 10 -- seconds
local file_list_cache = {} -- branch -> string[] (file paths)

local function get_json_path()
  if json_path then return json_path end
  local git_dir = vim.fn.system("git rev-parse --path-format=absolute --git-common-dir 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  json_path = git_dir .. "/stack-blessed.json"
  return json_path
end

-- Get the blob hash (content hash) for a file on a branch (cached)
---@param branch string
---@param filepath string
---@return string|nil
local function get_blob_hash(branch, filepath)
  local key = branch .. ":" .. filepath
  local cached = blob_cache[key]
  local now = vim.loop.now()
  if cached and (now - cached.time) < (BLOB_TTL * 1000) then
    return cached.hash
  end
  local hash = vim.fn.system("git rev-parse " .. key .. " 2>/dev/null"):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return nil end
  blob_cache[key] = { hash = hash, time = now }
  return hash
end

-- Warm blob cache for all files on a branch in one git call
---@param branch string
---@param filepaths string[]
function M.warm_blobs(branch, filepaths)
  local now = vim.loop.now()
  local need = {}
  local need_keys = {}
  for _, fp in ipairs(filepaths) do
    local key = branch .. ":" .. fp
    local cached = blob_cache[key]
    if not cached or (now - cached.time) >= (BLOB_TTL * 1000) then
      table.insert(need, key)
      table.insert(need_keys, key)
    end
  end
  if #need == 0 then return end

  local cmd = "git rev-parse " .. table.concat(need, " ") .. " 2>/dev/null"
  local output = vim.fn.system(cmd):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then return end

  local i = 1
  for hash in output:gmatch("[^\n]+") do
    if need_keys[i] then
      blob_cache[need_keys[i]] = { hash = hash, time = now }
    end
    i = i + 1
  end
end

-- Compat shim: warm_tips now warms blobs for all cached file lists
---@param branches string[]
function M.warm_tips(branches)
  for _, b in ipairs(branches) do
    local files = file_list_cache[b]
    if files and #files > 0 then
      M.warm_blobs(b, files)
    end
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

-- Bless a single file on a branch using the file's blob hash (content hash)
---@param branch string
---@param filepath string
---@param quiet? boolean
function M.bless_file(branch, filepath, quiet)
  local blob = get_blob_hash(branch, filepath)
  if not blob then return end
  if not blessed[branch] then blessed[branch] = {} end
  blessed[branch][filepath] = blob
  M.save()
  if not quiet then
    vim.notify(string.format("Blessed %s (%s)", filepath, blob:sub(1, 8)), vim.log.levels.INFO)
  end
end

-- Bless all files on a branch using each file's blob hash
---@param branch string
---@param parent string
function M.bless_branch(branch, parent)
  -- Use cached file list if available, otherwise shell out
  local files = file_list_cache[branch]
  if not files then
    local cmd = string.format("git diff --name-only %s...%s 2>/dev/null", parent, branch)
    local output = vim.fn.system(cmd):gsub("%s+$", "")
    if output == "" then return end
    files = {}
    for filepath in output:gmatch("[^\n]+") do
      table.insert(files, filepath)
    end
  end

  -- Warm the blob cache for all files at once
  M.warm_blobs(branch, files)

  if not blessed[branch] then blessed[branch] = {} end
  local count = 0
  for _, filepath in ipairs(files) do
    local blob = get_blob_hash(branch, filepath)
    if blob then
      blessed[branch][filepath] = blob
      count = count + 1
    end
  end
  M.save()
  vim.notify(string.format("Blessed %d files", count), vim.log.levels.INFO)
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
-- Compares blessed blob hash to current blob hash (content-based).
---@param branch string
---@param filepath string
---@return string status "clean" | "stale" | "unblessed"
function M.file_status(branch, filepath)
  local blessed_blob = M.get_sha(branch, filepath)
  if not blessed_blob then return "unblessed" end
  local current_blob = get_blob_hash(branch, filepath)
  if not current_blob then return "unblessed" end
  return blessed_blob == current_blob and "clean" or "stale"
end

-- Branch-level summary — compares blessed blob hashes to current blob hashes.
-- Requires warm_blobs() to have been called first for performance.
-- Returns: { status, total, reviewed, stale_count, stale_files }
---@param branch string
---@param parent string
---@return table
function M.summary(branch, parent)
  local branch_blessed = blessed[branch]
  if not branch_blessed or vim.tbl_isempty(branch_blessed) then
    return { status = "unblessed", total = 0, reviewed = 0, stale_count = 0, stale_files = {} }
  end

  -- Count from blessed data, comparing blob hashes.
  -- Skip files no longer in the current diff (removed from branch).
  local current_files = file_list_cache[branch]
  local current_set = {}
  if current_files then
    for _, f in ipairs(current_files) do current_set[f] = true end
  end

  local reviewed = 0
  local stale_list = {}
  local total = 0

  for filepath, blessed_blob in pairs(branch_blessed) do
    if not current_files or current_set[filepath] then
      total = total + 1
      local current_blob = get_blob_hash(branch, filepath)
      if current_blob and blessed_blob == current_blob then
        reviewed = reviewed + 1
      else
        table.insert(stale_list, filepath)
      end
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
      local cmd = string.format("git diff --name-only %s...%s 2>/dev/null", item.parent, item.branch)
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

-- Invalidate blob and file list caches (e.g. after pushing or syncing)
function M.invalidate(branch)
  if branch then
    -- Clear all blob cache entries for this branch
    local prefix = branch .. ":"
    for key, _ in pairs(blob_cache) do
      if key:sub(1, #prefix) == prefix then
        blob_cache[key] = nil
      end
    end
    file_list_cache[branch] = nil
  else
    blob_cache = {}
    file_list_cache = {}
  end
end

return M
