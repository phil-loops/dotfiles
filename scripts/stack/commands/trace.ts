import type { Command } from "../types.ts";
import { git, loadStack, currentBranch } from "../lib.ts";
import { getCurrentStack } from "../graph.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

type FileChange = {
  branch: string;
  parent: string | null;
  status: "introduced" | "modified" | "unchanged" | "deleted";
  additions: number;
  deletions: number;
};

function getFileAtBranch(branch: string, file: string): string | null {
  try {
    return execSync(`git show ${branch}:${file}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
}

function getDiffStats(
  parent: string,
  child: string,
  file: string
): { additions: number; deletions: number } {
  try {
    const stat = execSync(
      `git diff --numstat ${parent}..${child} -- "${file}"`,
      { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] }
    ).trim();

    if (!stat) return { additions: 0, deletions: 0 };

    const [add, del] = stat.split("\t");
    return {
      additions: parseInt(add, 10) || 0,
      deletions: parseInt(del, 10) || 0,
    };
  } catch {
    return { additions: 0, deletions: 0 };
  }
}

function traceFile(file: string, branches: string[], stack: Record<string, string>): FileChange[] {
  const changes: FileChange[] = [];

  for (const branch of branches) {
    const parent = stack[branch] || null;
    const contentAtBranch = getFileAtBranch(branch, file);
    const contentAtParent = parent ? getFileAtBranch(parent, file) : null;

    let status: FileChange["status"];
    let additions = 0;
    let deletions = 0;

    if (contentAtBranch === null && contentAtParent === null) {
      // File doesn't exist in either - skip
      continue;
    } else if (contentAtBranch === null && contentAtParent !== null) {
      status = "deleted";
      deletions = contentAtParent.split("\n").length;
    } else if (contentAtBranch !== null && contentAtParent === null) {
      status = "introduced";
      additions = contentAtBranch.split("\n").length;
    } else if (contentAtBranch === contentAtParent) {
      status = "unchanged";
    } else {
      status = "modified";
      const stats = getDiffStats(parent!, branch, file);
      additions = stats.additions;
      deletions = stats.deletions;
    }

    changes.push({ branch, parent, status, additions, deletions });
  }

  return changes;
}

function openVisualTrace(file: string, changes: FileChange[]) {
  // Filter to branches where file actually changed
  const meaningful = changes.filter((c) => c.status !== "unchanged");
  if (meaningful.length === 0) {
    console.log("No changes to visualize.");
    return;
  }

  const tmpDir = path.join(os.tmpdir(), "stack-trace");
  fs.mkdirSync(tmpDir, { recursive: true });

  const dataFile = path.join(tmpDir, "trace.json");
  const luaFile = path.join(tmpDir, "trace.lua");

  fs.writeFileSync(dataFile, JSON.stringify({ file, changes: meaningful }));

  const luaScript = `
-- Stack Trace: File Evolution Viewer
local data_file = "${dataFile}"

local function read_json(file)
  local f = io.open(file, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content)
end

local data = read_json(data_file)
if not data then
  vim.notify("Could not load trace data", vim.log.levels.ERROR)
  return
end

local file = data.file
local changes = data.changes

local function open_file_version(branch, filepath)
  local result = vim.fn.system(string.format("git cat-file -e %s:%s 2>/dev/null; echo $?", branch, filepath))
  local exists = result:gsub("%s+", "") == "0"
  if exists then
    vim.cmd("Gedit " .. branch .. ":" .. filepath)
    vim.cmd("setlocal readonly nomodifiable")
  else
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {"[FILE DOES NOT EXIST IN " .. branch .. "]"})
    vim.cmd("setlocal readonly nomodifiable buftype=nofile")
  end
end

-- Build list of versions to show
local versions = {}

-- Add parent of first change (the "before" state)
if changes[1].parent then
  table.insert(versions, {
    branch = changes[1].parent,
    label = "BEFORE",
    stats = "",
  })
end

-- Add each changed version
for _, c in ipairs(changes) do
  local stats = ""
  if c.status == "introduced" then
    stats = "+" .. c.additions
  elseif c.status == "deleted" then
    stats = "-" .. c.deletions
  elseif c.status == "modified" then
    stats = "+" .. c.additions .. "/-" .. c.deletions
  end
  table.insert(versions, {
    branch = c.branch,
    label = c.status:upper(),
    stats = stats,
  })
end

-- Limit to 4 panes max (first, important middle ones, last)
if #versions > 4 then
  local first = versions[1]
  local last = versions[#versions]
  local second_last = versions[#versions - 1]
  -- Keep first, a middle one, second-to-last, and last
  local middle_idx = math.floor(#versions / 2)
  versions = { first, versions[middle_idx], second_last, last }
  vim.notify("Showing 4 of " .. #changes .. " versions (too many for splits)", vim.log.levels.WARN)
end

-- Open in new tab with vertical splits
vim.cmd("tabnew")

-- Open first version
open_file_version(versions[1].branch, file)

-- Open remaining in splits
for i = 2, #versions do
  vim.cmd("vsplit")
  open_file_version(versions[i].branch, file)
end

-- Enable diff mode and equalize
vim.cmd("windo diffthis")
vim.cmd("wincmd =")
vim.cmd("1wincmd w")

-- Build summary message
local labels = {}
for _, v in ipairs(versions) do
  local lbl = v.branch
  if v.stats ~= "" then lbl = lbl .. " (" .. v.stats .. ")" end
  table.insert(labels, lbl)
end
vim.notify("Evolution: " .. table.concat(labels, " → "), vim.log.levels.INFO)

-- Keybindings
vim.keymap.set("n", "q", "<cmd>qa<cr>", { desc = "Quit trace" })

vim.api.nvim_create_user_command("TraceHelp", function()
  vim.notify([[
Trace Keybindings:
  ]c / [c   next/prev change
  q         quit
]], vim.log.levels.INFO)
end, {})
`;

  fs.writeFileSync(luaFile, luaScript);

  try {
    execSync(`nvim -c "luafile ${luaFile}"`, { stdio: "inherit" });
  } catch {
    // nvim exited
  }

  // Cleanup
  try {
    fs.unlinkSync(dataFile);
    fs.unlinkSync(luaFile);
    fs.rmdirSync(tmpDir);
  } catch {
    // ignore
  }
}

export const command: Command = {
  category: "util",
  name: "trace",
  help: "Trace a file's evolution through the stack",
  args: "<file> [--diff] [--visual]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      diff: { type: "boolean", short: "d" },
      visual: { type: "boolean", short: "v" },
    });

    const file = positionals[0];
    if (!file) {
      console.error("Usage: stack trace <file> [--diff]");
      process.exit(1);
    }

    const stack = loadStack();
    const branch = currentBranch();
    const branches = getCurrentStack(stack, branch);

    if (branches.length === 0) {
      console.log("Not in a tracked stack.");
      return;
    }

    console.log(`\nTracing: ${file}\n`);

    const changes = traceFile(file, branches, stack);

    if (changes.length === 0) {
      console.log("File not found in any branch of the stack.");
      return;
    }

    // Find where file was introduced
    const introduced = changes.find((c) => c.status === "introduced");
    if (introduced) {
      console.log(`Introduced in: ${introduced.branch}`);
    }

    // Count modifications
    const mods = changes.filter((c) => c.status === "modified");
    if (mods.length > 0) {
      console.log(`Modified in: ${mods.length} branch${mods.length > 1 ? "es" : ""}`);
    }

    console.log("");

    // Show each branch
    for (const change of changes) {
      const statusIcon =
        change.status === "introduced"
          ? "+"
          : change.status === "modified"
          ? "~"
          : change.status === "deleted"
          ? "-"
          : " ";

      const stats =
        change.status === "unchanged"
          ? ""
          : change.status === "introduced"
          ? `+${change.additions} lines`
          : change.status === "deleted"
          ? `-${change.deletions} lines`
          : `+${change.additions}/-${change.deletions}`;

      console.log(`${statusIcon} ${change.branch}${stats ? `  (${stats})` : ""}`);

      // Show diff if requested and file changed
      if (values.diff && change.status === "modified" && change.parent) {
        try {
          const diff = execSync(
            `git diff --color=always ${change.parent}..${change.branch} -- "${file}"`,
            { encoding: "utf-8" }
          ).trim();

          if (diff) {
            // Indent diff output
            const lines = diff.split("\n");
            for (const line of lines) {
              console.log(`    ${line}`);
            }
            console.log("");
          }
        } catch {
          // Ignore
        }
      }
    }

    // Summary
    const totalAdd = changes.reduce((sum, c) => sum + c.additions, 0);
    const totalDel = changes.reduce((sum, c) => sum + c.deletions, 0);
    console.log(`\nTotal: +${totalAdd}/-${totalDel} lines across ${changes.filter(c => c.status !== "unchanged").length} changes`);

    // Open visual mode if requested
    if (values.visual) {
      console.log("\nOpening visual diff...\n");
      openVisualTrace(file, changes);
    }
  },
};
