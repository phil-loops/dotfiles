import type { Command } from "../types.ts";
import {
  currentBranch,
  getDescendants,
  git,
  loadStack,
} from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

// ============ Health calculation (shared with info.ts logic) ============

type BranchHealth = {
  clean: boolean;
  driftedFiles: number;
  driftedFileList: string[];  // actual file paths that drifted
  totalFiles: number;
  loc: number;
};

function calculateHealth(chain: string[], stack: Record<string, string>): Map<string, BranchHealth> {
  const fileIntroducedIn = new Map<string, string>();
  const filesPerBranch = new Map<string, Set<string>>();
  const driftedFilesFrom = new Map<string, Set<string>>(); // branch -> set of drifted file paths
  const locPerBranch = new Map<string, number>();

  // Build ordered branches from root
  for (let i = 1; i < chain.length; i++) {
    const parent = chain[i - 1];
    const child = chain[i];

    try {
      // Get files changed
      const diffOutput = git(`diff --name-only ${parent}...${child}`);
      const files = diffOutput.split("\n").filter((f) =>
        f.endsWith(".ts") && !f.endsWith(".test.ts") && !f.endsWith(".tsx")
      );

      // Track LOC
      const locOutput = git(`diff --numstat ${parent}...${child} -- "*.ts" ":!*.tsx" ":!*.test.ts"`);
      let loc = 0;
      for (const line of locOutput.split("\n")) {
        if (!line.trim()) continue;
        const [added, removed] = line.split("\t");
        if (added !== "-" && removed !== "-") {
          loc += parseInt(added, 10) + parseInt(removed, 10);
        }
      }
      locPerBranch.set(child, loc);

      for (const file of files) {
        if (!fileIntroducedIn.has(file)) {
          fileIntroducedIn.set(file, child);
          if (!filesPerBranch.has(child)) {
            filesPerBranch.set(child, new Set());
          }
          filesPerBranch.get(child)!.add(file);
        } else {
          // File drifted - track it for the original branch
          const originalBranch = fileIntroducedIn.get(file)!;
          if (!driftedFilesFrom.has(originalBranch)) {
            driftedFilesFrom.set(originalBranch, new Set());
          }
          driftedFilesFrom.get(originalBranch)!.add(file);
        }
      }
    } catch {
      // skip
    }
  }

  // Build health map
  const health = new Map<string, BranchHealth>();
  for (const branch of chain) {
    const files = filesPerBranch.get(branch) || new Set();
    const driftedSet = driftedFilesFrom.get(branch) || new Set();
    health.set(branch, {
      clean: driftedSet.size === 0,
      driftedFiles: driftedSet.size,
      driftedFileList: [...driftedSet],
      totalFiles: files.size,
      loc: locPerBranch.get(branch) || 0,
    });
  }

  return health;
}

/**
 * Get the chain of ancestors from root to the target branch
 */
function getAncestorChain(stack: Record<string, string>, branch: string): string[] {
  const chain: string[] = [];
  let current = branch;

  while (current) {
    chain.unshift(current);
    current = stack[current]; // Move to parent
  }

  return chain;
}

export const command: Command = {
  category: "nav",
  name: "review",
  help: "Review stack in nvim (starts at current branch)",
  args: "[--from <branch>] [--all]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      from: { type: "string", short: "f" },
      all: { type: "boolean", short: "a" },
    });

    const stack = loadStack();
    if (Object.keys(stack).length === 0) {
      console.error("No branches tracked in stack");
      process.exit(1);
    }

    const startBranch = values.from || positionals[0] || currentBranch();

    // Get chain from root to current branch
    const ancestorChain = getAncestorChain(stack, startBranch);

    // Optionally include descendants with --all
    let chain = ancestorChain;
    if (values.all) {
      const descendants = getDescendants(stack, startBranch);
      chain = [...ancestorChain, ...descendants];
    }

    if (chain.length < 2) {
      console.error("Stack has no branches to review (only root)");
      process.exit(1);
    }

    // Find starting index based on current branch position in chain
    const current = currentBranch();
    const currentIdx = chain.indexOf(current);
    const startIdx = currentIdx >= 1 ? currentIdx : 1;

    // Calculate health for all branches
    const health = calculateHealth(chain, stack);

    // Always use nvim
    runNvimReview(chain, stack, startIdx, health);
  },
};

function runNvimReview(chain: string[], _stack: Record<string, string>, startIdx: number, health: Map<string, BranchHealth>) {
  // Write chain data to temp file for nvim to read
  const tmpDir = path.join(os.tmpdir(), "stack-review");
  fs.mkdirSync(tmpDir, { recursive: true });

  const chainFile = path.join(tmpDir, "chain.json");
  const stateFile = path.join(tmpDir, "state.json");

  // Write chain (skip root at index 0, pairs of [branch, parent]) with health data
  const reviewChain = [];
  for (let i = 1; i < chain.length; i++) {
    const branch = chain[i];
    const h = health.get(branch);
    reviewChain.push({
      branch,
      parent: chain[i - 1],
      health: h ? {
        clean: h.clean,
        driftedFiles: h.driftedFiles,
        driftedFileList: h.driftedFileList,
        loc: h.loc,
      } : null,
    });
  }
  fs.writeFileSync(chainFile, JSON.stringify(reviewChain));
  // Start at current branch position (reviewChain index is startIdx - 1 since it excludes root)
  const nvimStartIdx = Math.max(0, startIdx - 1);
  fs.writeFileSync(stateFile, JSON.stringify({ index: nvimStartIdx }));

  // Define luaFile path before using it in template
  const luaFile = path.join(tmpDir, "init.lua");

  // Create lua init script for stack review navigation
  const luaScript = `
-- Stack Review Navigation
local chain_file = "${chainFile}"
local state_file = "${stateFile}"

-- Forward declarations
local open_panel_above_diffview
local update_panel

local function read_json(file)
  local f = io.open(file, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content)
end

local function write_json(file, data)
  local f = io.open(file, "w")
  f:write(vim.json.encode(data))
  f:close()
end

local function get_chain() return read_json(chain_file) end
local function get_state() return read_json(state_file) end
local function set_state(s) write_json(state_file, s) end

local function branch_exists(branch)
  local result = vim.fn.system("git rev-parse --verify --quiet " .. branch)
  return vim.v.shell_error == 0
end

local function open_review(idx)
  local chain = get_chain()
  if not chain or idx < 0 or idx >= #chain then return false end

  local item = chain[idx + 1]  -- lua is 1-indexed

  -- Validate both branches exist before attempting diff
  if not branch_exists(item.parent) then
    vim.notify("Branch not found: " .. item.parent .. " (try: git fetch origin " .. item.parent .. ":" .. item.parent .. ")", vim.log.levels.ERROR)
    return false
  end
  if not branch_exists(item.branch) then
    vim.notify("Branch not found: " .. item.branch .. " (try: git fetch origin " .. item.branch .. ":" .. item.branch .. ")", vim.log.levels.ERROR)
    return false
  end

  set_state({ index = idx })

  -- Close existing diffview if open
  pcall(vim.cmd, "DiffviewClose")

  -- Open new diffview
  vim.cmd("DiffviewOpen " .. item.parent .. "..." .. item.branch)

  -- Reopen branch panel after diffview loads
  vim.defer_fn(function()
    open_panel_above_diffview()
  end, 100)

  -- Update statusline to show position
  vim.notify(string.format("Reviewing: %s (%d/%d)", item.branch, idx + 1, #chain), vim.log.levels.INFO)
  return true
end

vim.api.nvim_create_user_command("StackNext", function()
  local state = get_state()
  local chain = get_chain()
  if state.index + 1 >= #chain then
    vim.notify("Last branch in stack", vim.log.levels.WARN)
    return
  end
  open_review(state.index + 1)
end, {})

vim.api.nvim_create_user_command("StackPrev", function()
  local state = get_state()
  if state.index <= 0 then
    vim.notify("First branch in stack", vim.log.levels.WARN)
    return
  end
  open_review(state.index - 1)
end, {})

vim.api.nvim_create_user_command("StackStatus", function()
  local state = get_state()
  local chain = get_chain()
  local item = chain[state.index + 1]
  vim.notify(string.format("%s vs %s (%d/%d)", item.branch, item.parent, state.index + 1, #chain), vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("StackList", function()
  local state = get_state()
  local chain = get_chain()
  local items = {}
  for i, item in ipairs(chain) do
    local marker = (i - 1 == state.index) and " <--" or ""
    table.insert(items, string.format("%d. %s%s", i, item.branch, marker))
  end
  vim.ui.select(items, {
    prompt = "Jump to branch:",
    format_item = function(item) return item end,
  }, function(choice)
    if choice then
      local idx = tonumber(choice:match("^(%d+)%.")) - 1
      open_review(idx)
    end
  end)
end, {})

vim.api.nvim_create_user_command("StackJump", function(opts)
  local idx = tonumber(opts.args)
  if not idx then
    vim.notify("Usage: :StackJump <number>", vim.log.levels.ERROR)
    return
  end
  local chain = get_chain()
  if idx < 1 or idx > #chain then
    vim.notify(string.format("Invalid index. Range: 1-%d", #chain), vim.log.levels.ERROR)
    return
  end
  open_review(idx - 1)
end, { nargs = 1 })

-- 3-way view: root vs parent vs current
vim.api.nvim_create_user_command("Stack3Way", function()
  local state = get_state()
  local chain = get_chain()
  local item = chain[state.index + 1]

  -- Get git root
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]

  -- Try multiple methods to get the file path
  local rel_file = nil

  -- Method 1: Try to get from diffview's current entry
  local ok, diffview_lib = pcall(require, "diffview.lib")
  if ok then
    local view = diffview_lib.get_current_view()
    if view then
      local file_entry = view.panel:get_item_at_cursor()
      if file_entry and file_entry.path then
        rel_file = file_entry.path
      end
    end
  end

  -- Method 2: Parse from diffview buffer name
  if not rel_file then
    local bufname = vim.fn.expand("%:p")
    -- diffview://panels/0/DiffviewFilePanel is the panel - skip
    if not bufname:match("DiffviewFilePanel") then
      -- Try: diffview:///path/.git/abc123/filepath
      rel_file = bufname:match("%.git/[^/]+/(.+)$")
    end
  end

  -- Method 3: Get from current window if it's a normal file
  if not rel_file then
    local bufname = vim.fn.expand("%:p")
    if not bufname:match("^diffview://") and vim.fn.filereadable(bufname) == 1 then
      rel_file = bufname:gsub(git_root .. "/", "")
    end
  end

  -- Method 4: Prompt user
  if not rel_file or rel_file == "" then
    rel_file = vim.fn.input("File path (relative to repo): ")
  end

  if not rel_file or rel_file == "" then
    vim.notify("Could not determine file path", vim.log.levels.ERROR)
    return
  end

  -- Get branches for 3-way view
  local parent = item.parent                    -- One step back
  local current = item.branch                   -- Current branch being reviewed
  local final_branch = chain[#chain].branch     -- Last branch in stack (end result)

  -- Helper to check if file exists in a branch
  local function file_exists_in_branch(branch, filepath)
    local result = vim.fn.systemlist(string.format("git cat-file -e %s:%s 2>/dev/null; echo $?", branch, filepath))
    return result[#result] == "0"
  end

  -- Helper to open file from branch (or show [NEW FILE] message)
  local function open_branch_file(branch, filepath, label)
    if file_exists_in_branch(branch, filepath) then
      vim.cmd("Gedit " .. branch .. ":" .. filepath)
      vim.cmd("setlocal readonly nomodifiable")
    else
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {"[FILE DOES NOT EXIST IN " .. branch .. "]"})
      vim.cmd("setlocal readonly nomodifiable buftype=nofile bufhidden=wipe")
    end
    -- Don't rename - let fugitive/nvim handle buffer names naturally
  end

  -- Open 3-way split in new tab
  vim.cmd("tabnew")

  -- Left: parent version (one step back)
  open_branch_file(parent, rel_file, "PARENT")

  -- Center: current version (what you're reviewing)
  vim.cmd("vsplit")
  open_branch_file(current, rel_file, "CURRENT")

  -- Right: final version (end result of full stack)
  vim.cmd("vsplit")
  open_branch_file(final_branch, rel_file, "FINAL")

  -- Enable diff mode on all three
  vim.cmd("windo diffthis")
  vim.cmd("wincmd =")
  vim.cmd("1wincmd w")  -- Focus first window

  vim.notify(string.format("3-way: %s → %s → %s", parent, current, final_branch), vim.log.levels.INFO)
end, {})

-- Branch navigation panel
local panel_buf = nil
local panel_win = nil

update_panel = function()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then return end

  local state = get_state()
  local chain = get_chain()
  local lines = {}

  for i, item in ipairs(chain) do
    local marker = (i - 1 == state.index) and " ◀" or ""
    local prefix = (i - 1 == state.index) and "▶ " or "  "
    -- Shorten branch name for display
    local short_name = item.branch:gsub("goals%-v1%-", ""):gsub("goals%-v0%-", "")

    -- Build health indicator: ✅ only if no drift AND not large
    local health_str = ""
    if item.health then
      local is_drifted = item.health.driftedFiles > 0
      local is_large = item.health.loc > 150
      local is_clean = not is_drifted and not is_large

      if is_clean and item.health.loc > 0 then
        health_str = string.format(" ✅ %d", item.health.loc)
      else
        if is_drifted then
          health_str = string.format(" ⚠️%d", item.health.driftedFiles)
        end
        if is_large then
          health_str = health_str .. string.format(" 🔴%d", item.health.loc)
        elseif item.health.loc > 0 and is_drifted then
          health_str = health_str .. string.format(" %d", item.health.loc)
        end
      end
    end

    table.insert(lines, string.format("%s%d. %s%s%s", prefix, i, short_name, health_str, marker))
  end

  vim.api.nvim_buf_set_option(panel_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_buf, "modifiable", false)

  -- Move cursor to current branch
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    pcall(vim.api.nvim_win_set_cursor, panel_win, {state.index + 1, 0})
  end
end

local function setup_panel_keymaps()
  local opts = { buffer = panel_buf, silent = true }
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local idx = tonumber(line:match("(%d+)%."))
    if idx then
      open_review(idx - 1)
      update_panel()
      vim.cmd("wincmd l")  -- Go to diff window
    end
  end, opts)
  vim.keymap.set("n", "q", function()
    if panel_win and vim.api.nvim_win_is_valid(panel_win) then
      vim.api.nvim_win_close(panel_win, true)
      panel_win = nil
    end
  end, opts)
  -- Navigate and jump with single key
  vim.keymap.set("n", "J", function()
    local state = get_state()
    local chain = get_chain()
    if state.index + 1 < #chain then
      open_review(state.index + 1)
      update_panel()
    end
  end, opts)
  vim.keymap.set("n", "K", function()
    local state = get_state()
    if state.index > 0 then
      open_review(state.index - 1)
      update_panel()
    end
  end, opts)
end

open_panel_above_diffview = function()
  -- If panel already exists and is valid, just update it
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    update_panel()
    return
  end

  -- Find the diffview file panel window
  local file_panel_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("DiffviewFilePanel") then
      file_panel_win = win
      break
    end
  end

  if not file_panel_win then
    vim.notify("Diffview panel not found", vim.log.levels.WARN)
    return
  end

  -- Go to file panel window and split above it
  vim.api.nvim_set_current_win(file_panel_win)

  -- Create buffer (don't set a name to avoid conflicts)
  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(panel_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(panel_buf, "bufhidden", "wipe")

  -- Split above with fixed height
  local chain = get_chain()
  local height = math.min(#chain + 2, 20)
  vim.cmd("aboveleft " .. height .. "split")
  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_option(panel_win, "number", false)
  vim.api.nvim_win_set_option(panel_win, "relativenumber", false)
  vim.api.nvim_win_set_option(panel_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(panel_win, "winfixheight", true)
  vim.api.nvim_win_set_option(panel_win, "cursorline", true)

  update_panel()
  setup_panel_keymaps()

  -- Go back to diff window
  vim.cmd("wincmd l")
end

local function toggle_panel()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_win_close(panel_win, true)
    panel_win = nil
  else
    open_panel_above_diffview()
  end
end

vim.api.nvim_create_user_command("StackPanel", toggle_panel, {})

-- Auto-open branch panel above diffview after it loads
vim.defer_fn(function()
  open_panel_above_diffview()
end, 150)

-- Reload command (re-source this script without losing position)
local script_path = "${luaFile}"
vim.api.nvim_create_user_command("StackReload", function()
  dofile(script_path)
  vim.notify("Stack review reloaded", vim.log.levels.INFO)
end, {})

-- Keybindings for navigation
vim.keymap.set("n", "]b", function()
  vim.cmd("StackNext")
  update_panel()
end, { desc = "Next branch in stack" })
vim.keymap.set("n", "[b", function()
  vim.cmd("StackPrev")
  update_panel()
end, { desc = "Prev branch in stack" })
vim.keymap.set("n", "<leader>gs", "<cmd>StackStatus<cr>", { desc = "Stack review status" })
vim.keymap.set("n", "<leader>gl", "<cmd>StackList<cr>", { desc = "Stack branch list" })
vim.keymap.set("n", "<leader>g3", "<cmd>Stack3Way<cr>", { desc = "3-way diff: parent/current/final" })
vim.keymap.set("n", "<leader>g?", "<cmd>StackFileStatus<cr>", { desc = "Check if file matches final state" })
vim.keymap.set("n", "<leader>gp", "<cmd>StackPanel<cr>", { desc = "Toggle stack branch panel" })

-- Show drifted files for current branch and allow tracing
vim.api.nvim_create_user_command("StackDrift", function()
  local state = get_state()
  local chain = get_chain()
  local item = chain[state.index + 1]

  if not item.health or not item.health.driftedFileList or #item.health.driftedFileList == 0 then
    vim.notify("No drifted files for " .. item.branch, vim.log.levels.INFO)
    return
  end

  local files = item.health.driftedFileList
  vim.ui.select(files, {
    prompt = "Drifted files from " .. item.branch .. " (select to trace):",
    format_item = function(f) return f end,
  }, function(choice)
    if not choice then return end

    local introduced_branch = item.branch
    local final_branch = chain[#chain].branch

    -- Simple: show introduced version vs final version
    vim.cmd("tabnew")

    -- Helper to load file content from a branch into current buffer
    local function load_branch_file(branch, filepath)
      local content = vim.fn.systemlist(string.format("git show %s:%s 2>/dev/null", branch, filepath))
      if vim.v.shell_error ~= 0 then
        content = {"[FILE DOES NOT EXIST IN " .. branch .. "]"}
      end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
      vim.cmd("setlocal readonly nomodifiable buftype=nofile")
      -- Set filetype based on extension
      local ext = filepath:match("%.([^%.]+)$")
      if ext then vim.bo.filetype = ext end
    end

    -- Left: introduced version
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, introduced_branch .. ":" .. choice)
    load_branch_file(introduced_branch, choice)

    -- Right: final version
    vim.cmd("vsplit")
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, final_branch .. ":" .. choice)
    load_branch_file(final_branch, choice)

    -- Enable diff
    vim.cmd("windo diffthis")
    vim.cmd("wincmd =")
    vim.cmd("1wincmd w")

    vim.notify(string.format("Drift: %s (introduced) vs %s (final)", introduced_branch, final_branch), vim.log.levels.INFO)
  end)
end, {})
vim.keymap.set("n", "<leader>gD", "<cmd>StackDrift<cr>", { desc = "Show drifted files" })

-- Help command
vim.api.nvim_create_user_command("StackHelp", function()
  local help = {
    "Stack Review Keybindings:",
    "",
    "  ]b / [b        next/prev branch",
    "  ]f / [f        next/prev file",
    "  J / K          next/prev branch (in panel)",
    "  <CR>           jump to branch (in panel)",
    "",
    "  <leader>gl     branch list (fuzzy jump)",
    "  <leader>gs     show current position",
    "  <leader>g?     check if file matches final",
    "  <leader>g3     3-way diff view",
    "  <leader>gD     show drifted files (trace)",
    "  <leader>ge     edit current file",
    "  <leader>gp     toggle branch panel",
    "",
    "  <leader>gb     jump to branch panel",
    "  <leader>gf     jump to file panel",
    "  <leader>gd     jump to diff view",
    "  <leader>gy     copy branch name to clipboard",
    "",
    "  :StackJump N   jump to branch N",
    "  :StackDrift    show drifted files",
    "  :qa            quit review",
  }
  vim.notify(table.concat(help, "\\n"), vim.log.levels.INFO)
end, {})
vim.keymap.set("n", "g?", "<cmd>StackHelp<cr>", { desc = "Stack review help" })

-- Copy current branch name to clipboard
vim.api.nvim_create_user_command("StackYank", function()
  local state = get_state()
  local chain = get_chain()
  local item = chain[state.index + 1]
  vim.fn.setreg("+", item.branch)
  vim.notify("Copied: " .. item.branch, vim.log.levels.INFO)
end, {})
vim.keymap.set("n", "<leader>gy", "<cmd>StackYank<cr>", { desc = "Copy branch name to clipboard" })

-- Checkout the branch being reviewed
vim.api.nvim_create_user_command("StackCheckout", function()
  local state = get_state()
  local chain = get_chain()
  local item = chain[state.index + 1]
  vim.fn.jobstart({"git", "checkout", item.branch}, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          vim.notify("Checked out: " .. item.branch, vim.log.levels.INFO)
        else
          vim.notify("Failed to checkout: " .. item.branch, vim.log.levels.ERROR)
        end
      end)
    end
  })
end, {})
vim.keymap.set("n", "gC", "<cmd>StackCheckout<cr>", { desc = "Checkout reviewed branch" })

-- Quick jump to specific panels
vim.keymap.set("n", "<leader>gb", function()
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_set_current_win(panel_win)
  end
end, { desc = "Jump to branch panel" })

vim.keymap.set("n", "<leader>gf", function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match("DiffviewFilePanel") then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end, { desc = "Jump to file panel" })

vim.keymap.set("n", "<leader>gd", function()
  -- Jump to rightmost window (diff view)
  vim.cmd("wincmd l")
  vim.cmd("wincmd l")
  vim.cmd("wincmd l")
end, { desc = "Jump to diff view" })

-- Check if current file matches its final version in the stack
local function get_current_file()
  local bufname = vim.fn.expand("%:p")
  local rel_file = bufname:match("%.git/[^/]+/(.+)$")
  if not rel_file then
    local ok, diffview_lib = pcall(require, "diffview.lib")
    if ok then
      local view = diffview_lib.get_current_view()
      if view then
        local file_entry = view.panel:get_item_at_cursor()
        if file_entry and file_entry.path then
          rel_file = file_entry.path
        end
      end
    end
  end
  return rel_file
end

local function check_file_final_status(rel_file)
  if not rel_file then return nil end

  local state = get_state()
  local chain = get_chain()
  local current_branch = chain[state.index + 1].branch
  local final_branch = chain[#chain].branch

  -- If we're already on the final branch, it's by definition final
  if current_branch == final_branch then
    return "final", "This IS the final branch"
  end

  -- Compare file content between current branch and final branch
  local current_hash = vim.fn.systemlist(string.format("git rev-parse %s:%s 2>/dev/null", current_branch, rel_file))[1]
  local final_hash = vim.fn.systemlist(string.format("git rev-parse %s:%s 2>/dev/null", final_branch, rel_file))[1]

  -- Handle file not existing in one or both branches
  if not current_hash or current_hash:match("^fatal") then
    if not final_hash or final_hash:match("^fatal") then
      return "final", "File doesn't exist in either branch"
    else
      return "changes", "File will be ADDED in later branches"
    end
  end

  if not final_hash or final_hash:match("^fatal") then
    return "changes", "File will be DELETED in later branches"
  end

  if current_hash == final_hash then
    return "final", "✓ FINAL - matches end state"
  else
    return "changes", "⋯ Will change in later branches"
  end
end

vim.api.nvim_create_user_command("StackFileStatus", function()
  local rel_file = get_current_file()
  if not rel_file then
    vim.notify("Could not determine current file", vim.log.levels.WARN)
    return
  end

  local status, msg = check_file_final_status(rel_file)
  local level = status == "final" and vim.log.levels.INFO or vim.log.levels.WARN
  vim.notify(rel_file .. ": " .. msg, level)
end, {})

-- File navigation within diffview (with auto status check)
vim.keymap.set("n", "]f", function()
  local ok, diffview_lib = pcall(require, "diffview.lib")
  if ok then
    local view = diffview_lib.get_current_view()
    if view then
      view:next_file()
      -- Show file status after a brief delay
      vim.defer_fn(function()
        local rel_file = get_current_file()
        if rel_file then
          local status, msg = check_file_final_status(rel_file)
          local level = status == "final" and vim.log.levels.INFO or vim.log.levels.WARN
          vim.notify(msg, level)
        end
      end, 100)
    end
  end
end, { desc = "Next file in diff" })

vim.keymap.set("n", "[f", function()
  local ok, diffview_lib = pcall(require, "diffview.lib")
  if ok then
    local view = diffview_lib.get_current_view()
    if view then
      view:prev_file()
      -- Show file status after a brief delay
      vim.defer_fn(function()
        local rel_file = get_current_file()
        if rel_file then
          local status, msg = check_file_final_status(rel_file)
          local level = status == "final" and vim.log.levels.INFO or vim.log.levels.WARN
          vim.notify(msg, level)
        end
      end, 100)
    end
  end
end, { desc = "Prev file in diff" })

vim.keymap.set("n", "<leader>ge", function()
  -- Open the current file for editing
  local bufname = vim.fn.expand("%:p")
  local rel_file = nil

  -- Try to extract file path from diffview buffer name
  -- Format: diffview:///path/.git/abc123/filepath
  rel_file = bufname:match("%.git/[^/]+/(.+)$")

  -- If not in a diffview buffer, try getting from file panel
  if not rel_file then
    local ok, diffview_lib = pcall(require, "diffview.lib")
    if ok then
      local view = diffview_lib.get_current_view()
      if view then
        local file_entry = view.panel:get_item_at_cursor()
        if file_entry and file_entry.path then
          rel_file = file_entry.path
        end
      end
    end
  end

  if rel_file then
    -- Open in new tab to preserve diffview
    vim.cmd("tabedit " .. rel_file)
    vim.notify("Editing: " .. rel_file, vim.log.levels.INFO)
  else
    vim.notify("Could not determine file to edit. Try selecting a file in the panel first.", vim.log.levels.WARN)
  end
end, { desc = "Edit current file" })

-- On first load, open at current branch position. On reload, stay at current position.
if not _G.stack_review_loaded then
  _G.stack_review_loaded = true
  local state = get_state()
  open_review(state.index)
end
`;

  fs.writeFileSync(luaFile, luaScript);

  try {
    execSync(`nvim -c "luafile ${luaFile}"`, { stdio: "inherit" });
  } catch {
    // nvim exited
  }

  // Cleanup
  try {
    fs.unlinkSync(chainFile);
    fs.unlinkSync(stateFile);
    fs.unlinkSync(luaFile);
    fs.rmdirSync(tmpDir);
  } catch {
    // ignore cleanup errors
  }
}
