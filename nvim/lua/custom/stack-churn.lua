-- Stack Churn Detection
-- Detects lines added in an earlier branch that are removed/modified in a later branch.
-- These represent "churn" - changes that should be moved to the earlier branch.
local M = {}

---@class ChurnHunk
---@field file string
---@field added_in string       -- branch that added the line
---@field removed_in string     -- branch that removed/changed it
---@field added_idx number
---@field removed_idx number
---@field lines string[]        -- the churned line content

---@class BranchDiff
---@field branch string
---@field parent string
---@field adds table<string, table<string, boolean>>   -- file -> {trimmed_line -> true}
---@field removes table<string, table<string, boolean>> -- file -> {trimmed_line -> true}

-- Parse unified diff output into per-file added/removed lines
local function parse_diff(diff_output)
  local adds = {}    -- file -> {line_content -> true}
  local removes = {} -- file -> {line_content -> true}
  local current_file = nil

  for line in diff_output:gmatch("[^\n]+") do
    -- Track current file from diff headers
    local new_file = line:match("^%+%+%+ b/(.+)")
    if new_file then
      current_file = new_file
    elseif line:match("^%-%-%-") or line:match("^diff ") then
      -- skip
    elseif current_file then
      if line:match("^%+") and not line:match("^%+%+%+") then
        local content = line:sub(2):match("^%s*(.-)%s*$") -- trim
        if content and content ~= "" then
          adds[current_file] = adds[current_file] or {}
          adds[current_file][content] = true
        end
      elseif line:match("^%-") and not line:match("^%-%-%-") then
        local content = line:sub(2):match("^%s*(.-)%s*$") -- trim
        if content and content ~= "" then
          removes[current_file] = removes[current_file] or {}
          removes[current_file][content] = true
        end
      end
    end
  end

  return adds, removes
end

-- Analyze churn across the entire stack
---@param chain table[] -- {branch, parent} pairs
---@return ChurnHunk[]
function M.analyze(chain)
  -- Collect diffs for each branch
  local branch_diffs = {} ---@type BranchDiff[]

  for i, item in ipairs(chain) do
    if item.parent and item.parent ~= "" then
      local cmd = string.format("git diff %s...%s 2>/dev/null", item.parent, item.branch)
      local output = vim.fn.system(cmd)
      local adds, removes = parse_diff(output)
      table.insert(branch_diffs, {
        branch = item.branch,
        parent = item.parent,
        idx = i,
        adds = adds,
        removes = removes,
      })
    end
  end

  -- Cross-reference: for each removed line in branch[j],
  -- check if it was added in an earlier branch[i]
  local churns = {} ---@type ChurnHunk[]

  for j, later in ipairs(branch_diffs) do
    for file, removed_lines in pairs(later.removes) do
      for line_content, _ in pairs(removed_lines) do
        -- Search earlier branches for this added line
        for i = 1, j - 1 do
          local earlier = branch_diffs[i]
          if earlier.adds[file] and earlier.adds[file][line_content] then
            table.insert(churns, {
              file = file,
              added_in = earlier.branch,
              removed_in = later.branch,
              added_idx = earlier.idx,
              removed_idx = later.idx,
              lines = { line_content },
            })
            break -- only report first match
          end
        end
      end
    end
  end

  -- Sort by file, then by added_idx
  table.sort(churns, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.added_idx < b.added_idx
  end)

  -- Merge adjacent churns (same file, same branch pair)
  local merged = {}
  for _, c in ipairs(churns) do
    local prev = merged[#merged]
    if prev
      and prev.file == c.file
      and prev.added_in == c.added_in
      and prev.removed_in == c.removed_in then
      table.insert(prev.lines, c.lines[1])
    else
      table.insert(merged, c)
    end
  end

  return merged
end

-- Summarize churn by branch (how many churn hunks affect each branch)
---@param churns ChurnHunk[]
---@return table<string, number> -- branch_name -> count
function M.by_branch(churns)
  local counts = {}
  for _, c in ipairs(churns) do
    counts[c.added_in] = (counts[c.added_in] or 0) + 1
  end
  return counts
end

-- Format churn results as displayable lines
---@param churns ChurnHunk[]
---@return string[]
function M.format(churns)
  if #churns == 0 then
    return { "No churn detected - stack looks clean!" }
  end

  local lines = {}
  table.insert(lines, string.format("Found %d churn hunks:", #churns))
  table.insert(lines, "")

  local current_file = nil
  for _, c in ipairs(churns) do
    if c.file ~= current_file then
      current_file = c.file
      table.insert(lines, "  " .. c.file)
    end

    local added_short = c.added_in:gsub("goals%-v%d+%-", "")
    local removed_short = c.removed_in:gsub("goals%-v%d+%-", "")
    table.insert(lines, string.format(
      "    + %s  ->  - %s  (%d lines)",
      added_short, removed_short, #c.lines
    ))
    -- Show first few lines
    for i, l in ipairs(c.lines) do
      if i > 3 then
        table.insert(lines, string.format("      ... and %d more", #c.lines - 3))
        break
      end
      local truncated = #l > 60 and l:sub(1, 57) .. "..." or l
      table.insert(lines, "      " .. truncated)
    end
  end

  return lines
end

-- Show churn in a floating window
---@param churns ChurnHunk[]
function M.show(churns)
  local lines = M.format(churns)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 10)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = (vim.o.lines - height) / 2,
    col = (vim.o.columns - width) / 2,
    style = "minimal",
    border = "rounded",
    title = " Stack Churn ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

return M
