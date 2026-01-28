-- Stack Churn Detection
-- Finds code added in one branch that gets removed in a later branch
-- This represents wasted work that should ideally be avoided

local M = {}

-- Normalize content for comparison (strip whitespace, normalize strings)
local function normalize(content)
  if not content then return "" end
  -- Remove leading/trailing whitespace per line
  -- Collapse multiple spaces to single space
  -- Remove empty lines
  local lines = {}
  for line in content:gmatch("[^\n]+") do
    local normalized = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if normalized ~= "" then
      table.insert(lines, normalized)
    end
  end
  return table.concat(lines, "\n")
end

-- Hash content for quick comparison
local function hash_content(content)
  local normalized = normalize(content)
  -- Simple hash: sum of bytes (not cryptographic, just for comparison)
  local h = 0
  for i = 1, #normalized do
    h = (h * 31 + normalized:byte(i)) % 2147483647
  end
  return h, normalized
end

-- Parse a unified diff and extract hunks
-- Returns: { { type = "add"|"remove", file = "...", content = "...", start_line = N, num_lines = N } }
local function parse_diff(diff_output)
  local hunks = {}
  local current_file = nil
  local current_hunk = nil
  local in_hunk = false
  local add_lines = {}
  local remove_lines = {}
  local add_start, remove_start = 0, 0

  for line in diff_output:gmatch("[^\n]*\n?") do
    -- New file
    local file = line:match("^%+%+%+ b/(.+)$")
    if file then
      current_file = file
      goto continue
    end

    -- Hunk header: @@ -start,count +start,count @@
    local rm_start, rm_count, ad_start, ad_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if rm_start then
      -- Save previous hunk if exists
      if #add_lines > 0 then
        table.insert(hunks, {
          type = "add",
          file = current_file,
          content = table.concat(add_lines, "\n"),
          start_line = add_start,
          num_lines = #add_lines,
        })
      end
      if #remove_lines > 0 then
        table.insert(hunks, {
          type = "remove",
          file = current_file,
          content = table.concat(remove_lines, "\n"),
          start_line = remove_start,
          num_lines = #remove_lines,
        })
      end

      -- Reset for new hunk
      add_lines = {}
      remove_lines = {}
      add_start = tonumber(ad_start) or 0
      remove_start = tonumber(rm_start) or 0
      in_hunk = true
      goto continue
    end

    -- Diff content lines
    if in_hunk then
      if line:match("^%+[^%+]") or line:match("^%+$") then
        -- Added line (but not +++ header)
        local content = line:sub(2)
        table.insert(add_lines, content)
      elseif line:match("^%-[^%-]") or line:match("^%-$") then
        -- Removed line (but not --- header)
        local content = line:sub(2)
        table.insert(remove_lines, content)
      elseif line:match("^[^%+%-@]") or line == "" then
        -- Context line or empty - if we have accumulated lines, save them
        if #add_lines > 0 then
          table.insert(hunks, {
            type = "add",
            file = current_file,
            content = table.concat(add_lines, "\n"),
            start_line = add_start,
            num_lines = #add_lines,
          })
          add_lines = {}
        end
        if #remove_lines > 0 then
          table.insert(hunks, {
            type = "remove",
            file = current_file,
            content = table.concat(remove_lines, "\n"),
            start_line = remove_start,
            num_lines = #remove_lines,
          })
          remove_lines = {}
        end
      end
    end

    ::continue::
  end

  -- Don't forget the last hunk
  if #add_lines > 0 then
    table.insert(hunks, {
      type = "add",
      file = current_file,
      content = table.concat(add_lines, "\n"),
      start_line = add_start,
      num_lines = #add_lines,
    })
  end
  if #remove_lines > 0 then
    table.insert(hunks, {
      type = "remove",
      file = current_file,
      content = table.concat(remove_lines, "\n"),
      start_line = remove_start,
      num_lines = #remove_lines,
    })
  end

  return hunks
end

-- Get diff between two branches
local function get_diff(parent, branch)
  local cmd = string.format("git diff %s..%s -- '*.ts' '*.tsx' 2>/dev/null", parent, branch)
  local handle = io.popen(cmd)
  if not handle then return "" end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Calculate similarity between two normalized strings (0-1)
local function similarity(s1, s2)
  if s1 == s2 then return 1.0 end
  if #s1 == 0 or #s2 == 0 then return 0.0 end

  -- Simple: check if one contains the other
  if s1:find(s2, 1, true) or s2:find(s1, 1, true) then
    return 0.8
  end

  -- Line-by-line overlap
  local lines1 = {}
  for line in s1:gmatch("[^\n]+") do lines1[line] = true end

  local matches = 0
  local total = 0
  for line in s2:gmatch("[^\n]+") do
    total = total + 1
    if lines1[line] then matches = matches + 1 end
  end

  if total == 0 then return 0.0 end
  return matches / total
end

-- Analyze churn across a stack of branches
-- branches: ordered list of { branch = "name", parent = "parent_name" }
-- Returns: list of churn items
function M.analyze(branches)
  local all_adds = {}  -- { hash = { branch, file, content, normalized } }
  local churn = {}

  -- First pass: collect all added hunks
  for i, b in ipairs(branches) do
    if not b.parent or b.parent == "" then
      goto continue
    end

    local diff = get_diff(b.parent, b.branch)
    local hunks = parse_diff(diff)

    for _, hunk in ipairs(hunks) do
      if hunk.type == "add" and hunk.num_lines >= 2 then  -- Only track hunks of 2+ lines
        local hash, normalized = hash_content(hunk.content)
        all_adds[hash] = all_adds[hash] or {}
        table.insert(all_adds[hash], {
          branch = b.branch,
          branch_idx = i,
          file = hunk.file,
          content = hunk.content,
          normalized = normalized,
          start_line = hunk.start_line,
          num_lines = hunk.num_lines,
        })
      end
    end

    ::continue::
  end

  -- Second pass: check removed hunks against added hunks
  for i, b in ipairs(branches) do
    if not b.parent or b.parent == "" then
      goto continue
    end

    local diff = get_diff(b.parent, b.branch)
    local hunks = parse_diff(diff)

    for _, hunk in ipairs(hunks) do
      if hunk.type == "remove" and hunk.num_lines >= 2 then
        local hash, normalized = hash_content(hunk.content)

        -- Check exact hash match first
        if all_adds[hash] then
          for _, add in ipairs(all_adds[hash]) do
            -- Only flag if the add was in an EARLIER branch
            if add.branch_idx < i and add.file == hunk.file then
              table.insert(churn, {
                file = hunk.file,
                branch_added = add.branch,
                branch_removed = b.branch,
                content = add.content,
                lines_added = add.num_lines,
                lines_removed = hunk.num_lines,
                similarity = 1.0,
              })
            end
          end
        else
          -- Fuzzy match: check all adds in the same file
          for _, adds in pairs(all_adds) do
            for _, add in ipairs(adds) do
              if add.branch_idx < i and add.file == hunk.file then
                local sim = similarity(add.normalized, normalized)
                if sim >= 0.7 then  -- 70% similarity threshold
                  table.insert(churn, {
                    file = hunk.file,
                    branch_added = add.branch,
                    branch_removed = b.branch,
                    content = add.content,
                    lines_added = add.num_lines,
                    lines_removed = hunk.num_lines,
                    similarity = sim,
                  })
                end
              end
            end
          end
        end
      end
    end

    ::continue::
  end

  return churn
end

-- Get churn summary per branch (how many churned hunks originated in each branch)
function M.summarize_by_branch(churn)
  local summary = {}
  for _, c in ipairs(churn) do
    summary[c.branch_added] = (summary[c.branch_added] or 0) + 1
  end
  return summary
end

-- Format churn report (simple text)
function M.format_report(churn)
  if #churn == 0 then
    return "No churn detected - clean stack!"
  end

  local lines = { "Churn detected:", "" }
  for _, c in ipairs(churn) do
    table.insert(lines, string.format("  %s:", c.file))
    table.insert(lines, string.format("    Added in:   %s (%d lines)", c.branch_added, c.lines_added))
    table.insert(lines, string.format("    Removed in: %s (%d lines)", c.branch_removed, c.lines_removed))
    if c.similarity < 1.0 then
      table.insert(lines, string.format("    Similarity: %d%%", math.floor(c.similarity * 100)))
    end
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

-- Show interactive churn browser
function M.show_interactive(churn)
  if #churn == 0 then
    vim.notify("No churn detected - clean stack!", vim.log.levels.INFO)
    return
  end

  -- Build display lines with index tracking
  local lines = {}
  local line_to_churn = {}  -- line number -> churn index

  table.insert(lines, "Churn: code added then removed (wasted work)")
  table.insert(lines, "")
  table.insert(lines, "[<CR>] view code  [t] trace evolution  [d] diff  [o] open  [q] quit")
  table.insert(lines, string.rep("─", 60))

  for i, c in ipairs(churn) do
    local start_line = #lines + 1
    table.insert(lines, string.format("%s", c.file))
    line_to_churn[#lines] = i
    table.insert(lines, string.format("  + %s (%d lines)", c.branch_added, c.lines_added))
    line_to_churn[#lines] = i
    table.insert(lines, string.format("  - %s (%d lines)", c.branch_removed, c.lines_removed))
    line_to_churn[#lines] = i
    table.insert(lines, "")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"

  local width = 65
  local height = math.min(#lines + 2, 35)
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

  vim.wo[win].cursorline = true

  local function get_current_churn()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line_to_churn[line]
    if idx then return churn[idx] end
    -- Try nearby lines
    for offset = 1, 3 do
      if line_to_churn[line - offset] then return churn[line_to_churn[line - offset]] end
      if line_to_churn[line + offset] then return churn[line_to_churn[line + offset]] end
    end
    return nil
  end

  -- View the churned code
  vim.keymap.set("n", "<CR>", function()
    local c = get_current_churn()
    if not c then return end

    -- Show the code in a split
    local code_buf = vim.api.nvim_create_buf(false, true)
    local code_lines = {
      "ADDED in " .. c.branch_added .. ":",
      string.rep("─", 50),
    }
    for line in c.content:gmatch("[^\n]+") do
      table.insert(code_lines, "+ " .. line)
    end
    table.insert(code_lines, "")
    table.insert(code_lines, "Then REMOVED in " .. c.branch_removed)
    table.insert(code_lines, "")
    table.insert(code_lines, "FIX: Move this code to " .. c.branch_removed .. " instead of " .. c.branch_added)
    table.insert(code_lines, "     Or: keep the code and remove the deletion")

    vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, code_lines)
    vim.bo[code_buf].modifiable = false
    vim.bo[code_buf].filetype = "diff"

    local code_win = vim.api.nvim_open_win(code_buf, true, {
      relative = "editor",
      width = 70,
      height = math.min(#code_lines + 2, 30),
      row = 3,
      col = (vim.o.columns - 70) / 2,
      style = "minimal",
      border = "rounded",
      title = " " .. c.file .. " ",
      title_pos = "center",
    })

    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(code_win, true) end, { buffer = code_buf })
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(code_win, true) end, { buffer = code_buf })
  end, { buffer = buf })

  -- Open file in the "added" branch
  vim.keymap.set("n", "o", function()
    local c = get_current_churn()
    if not c then return end
    vim.api.nvim_win_close(win, true)
    vim.cmd("Gedit " .. c.branch_added .. ":" .. c.file)
  end, { buffer = buf })

  -- Show diff between the two branches for this file
  vim.keymap.set("n", "d", function()
    local c = get_current_churn()
    if not c then return end
    vim.api.nvim_win_close(win, true)
    vim.cmd("DiffviewOpen " .. c.branch_added .. ".." .. c.branch_removed .. " -- " .. c.file)
  end, { buffer = buf })

  -- Trace file evolution through entire stack
  vim.keymap.set("n", "t", function()
    local c = get_current_churn()
    if not c then return end
    vim.api.nvim_win_close(win, true)
    local ok, inspect = pcall(require, "custom.stack-file-inspect")
    if ok then
      inspect.inspect(c.file)
    else
      vim.notify("stack-file-inspect not available", vim.log.levels.WARN)
    end
  end, { buffer = buf })

  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })

  -- Position cursor on first churn item
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
end

-- Setup commands
function M.setup()
  vim.api.nvim_create_user_command("StackChurn", function()
    local git_town = require("custom.stack-git-town")
    local branches_raw = git_town.get_all_branches()

    -- Convert to format needed by analyze
    local branches = {}
    local parents, _ = git_town.get_lineage()
    for _, item in ipairs(branches_raw) do
      table.insert(branches, {
        branch = item.branch,
        parent = parents[item.branch] or "",
      })
    end

    local churn = M.analyze(branches)
    local report = M.format_report(churn)

    -- Show in floating window
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(report, "\n"))
    vim.bo[buf].modifiable = false

    local width = 70
    local height = math.min(#churn * 5 + 4, 30)
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
  end, { desc = "Analyze churn in stack" })
end

return M
