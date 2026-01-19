import type { Command } from "../types.ts";
import {
  currentBranch,
  extractKeyChanges,
  getDescendants,
  git,
  loadStack,
} from "../lib.ts";
import { parseArgs } from "../args.ts";
import * as readline from "readline";
import { execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

interface CodeSnippet {
  file: string;
  line: number;
  code: string[];
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
  help: "Interactive code review through the stack",
  args: "[--from <branch>] [--nvim] [--all]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      from: { type: "string", short: "f" },
      nvim: { type: "boolean", short: "n" },
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

    if (values.nvim) {
      runNvimReview(chain, stack);
    } else {
      runInteractiveReview(chain, stack);
    }
  },
};

function runInteractiveReview(chain: string[], stack: Record<string, string>) {
  let idx = 1; // Start from first non-root branch

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const prompt = (q: string): Promise<string> =>
    new Promise((resolve) => rl.question(q, resolve));

  const loop = async () => {
    while (true) {
      console.clear();
      const branch = chain[idx];
      const parent = chain[idx - 1];

      displaySummary(branch, parent, idx, chain.length - 1);

      const input = await prompt(
        "\n[n]ext  [p]rev  [s]how code  [d]iff  [o]pen in editor  [q]uit\n> "
      );

      switch (input.toLowerCase().trim()) {
        case "n":
          if (idx < chain.length - 1) {
            idx++;
          } else {
            console.log("\nAlready at the last branch in the stack.");
            await prompt("Press ENTER to continue...");
          }
          break;
        case "p":
          if (idx > 1) {
            idx--;
          } else {
            console.log("\nAlready at the first branch in the stack.");
            await prompt("Press ENTER to continue...");
          }
          break;
        case "s":
          console.clear();
          showCode(branch, parent);
          await prompt("\nPress ENTER to continue...");
          break;
        case "d":
          console.clear();
          showDiff(branch, parent);
          await prompt("\nPress ENTER to continue...");
          break;
        case "o":
          openInEditor(branch, parent);
          break;
        case "q":
        case "":
          if (input.toLowerCase().trim() === "q") {
            rl.close();
            return;
          }
          break;
        default:
          // Unknown command, just refresh
          break;
      }
    }
  };

  loop().catch((err) => {
    console.error("Error:", err);
    rl.close();
    process.exit(1);
  });
}

function displaySummary(
  branch: string,
  parent: string,
  idx: number,
  total: number
) {
  const divider = "─".repeat(62);

  // Get diff stats
  let loc = 0;
  let files: { name: string; changes: string }[] = [];

  try {
    const stat = git(`diff --stat ${parent}...${branch}`);
    const lines = stat.split("\n");

    for (const line of lines) {
      // Parse file lines like: " file.ts | 10 ++++----"
      const fileMatch = line.match(/^\s*(.+?)\s*\|\s*(\d+)\s*([+-]+)?/);
      if (fileMatch) {
        const name = fileMatch[1].trim();
        const count = fileMatch[2];
        const plusMinus = fileMatch[3] || "";
        const plusCount = (plusMinus.match(/\+/g) || []).length;
        const minusCount = (plusMinus.match(/-/g) || []).length;
        files.push({
          name,
          changes: `(+${plusCount * parseInt(count) / (plusCount + minusCount || 1) | 0})`,
        });
      }

      // Parse summary line like: " 3 files changed, 45 insertions(+), 12 deletions(-)"
      const summaryMatch = line.match(/(\d+) insertions?\(\+\).*?(\d+) deletions?\(-\)/);
      if (summaryMatch) {
        loc = parseInt(summaryMatch[1]) + parseInt(summaryMatch[2]);
      } else {
        const insertOnly = line.match(/(\d+) insertions?\(\+\)/);
        const deleteOnly = line.match(/(\d+) deletions?\(-\)/);
        if (insertOnly) loc += parseInt(insertOnly[1]);
        if (deleteOnly) loc += parseInt(deleteOnly[1]);
      }
    }
  } catch {
    // Diff failed
  }

  // Get key changes
  let changes: string[] = [];
  try {
    const diff = git(`diff ${parent}...${branch}`);
    changes = extractKeyChanges(diff);
  } catch {
    // Diff failed
  }

  // Get file changes with line counts
  let fileDetails: { name: string; insertions: number; deletions: number }[] = [];
  try {
    const numstat = git(`diff --numstat ${parent}...${branch}`);
    for (const line of numstat.split("\n")) {
      const match = line.match(/^(\d+)\s+(\d+)\s+(.+)$/);
      if (match) {
        fileDetails.push({
          name: match[3],
          insertions: parseInt(match[1]),
          deletions: parseInt(match[2]),
        });
      }
    }
  } catch {
    // Diff failed
  }

  // Display header box
  console.log(`╭${divider}╮`);
  console.log(`│  REVIEWING: ${branch}`.padEnd(63) + "│");
  console.log(`│  ${idx}/${total} · ${loc} lines changed · Parent: ${parent}`.padEnd(63) + "│");
  console.log(`╰${divider}╯`);

  // Display files changed
  console.log("\nFiles changed:");
  if (fileDetails.length > 0) {
    for (const f of fileDetails) {
      const sign = f.insertions > 0 ? `+${f.insertions}` : "";
      const del = f.deletions > 0 ? `-${f.deletions}` : "";
      const stats = [sign, del].filter(Boolean).join("/");
      console.log(`  ${f.name.padEnd(40)} (${stats})`);
    }
  } else {
    console.log("  (no files changed)");
  }

  // Display key additions
  console.log("\nKey additions:");
  if (changes.length > 0) {
    const displayChanges = changes.slice(0, 8);
    for (const c of displayChanges) {
      console.log(`  + ${c}`);
    }
    if (changes.length > 8) {
      console.log(`  ... and ${changes.length - 8} more`);
    }
  } else {
    console.log("  (none detected)");
  }

  console.log("\n" + divider);
}

function showCode(branch: string, parent: string) {
  console.log(`── ${branch} vs ${parent} ──────────────────────────────────\n`);

  try {
    const diff = git(`diff ${parent}...${branch}`);
    const snippets = extractCodeSnippets(diff);

    if (snippets.length === 0) {
      console.log("(no key code changes detected)");
      return;
    }

    for (const snippet of snippets) {
      console.log(`+ ${snippet.file}:${snippet.line}`);
      for (const line of snippet.code) {
        console.log(`  ${line}`);
      }
      console.log();
    }
  } catch {
    console.log("(could not compute diff)");
  }
}

function showDiff(branch: string, parent: string) {
  console.log(`── git diff ${parent}...${branch} ──────────────────────────\n`);

  try {
    const diff = git(`diff --color=always ${parent}...${branch}`);
    console.log(diff);
  } catch {
    console.log("(could not compute diff)");
  }
}

function openInEditor(branch: string, parent: string) {
  try {
    const filesOutput = git(`diff --name-only ${parent}...${branch}`);
    const files = filesOutput.trim().split("\n").filter(Boolean);

    if (files.length === 0) {
      console.log("No files to open");
      return;
    }

    const editor = process.env.EDITOR || "code";
    execSync(`${editor} ${files.join(" ")}`, { stdio: "inherit" });
  } catch {
    console.log("(could not open files in editor)");
  }
}

function runNvimReview(chain: string[], _stack: Record<string, string>) {
  // Write chain data to temp file for nvim to read
  const tmpDir = path.join(os.tmpdir(), "stack-review");
  fs.mkdirSync(tmpDir, { recursive: true });

  const chainFile = path.join(tmpDir, "chain.json");
  const stateFile = path.join(tmpDir, "state.json");

  // Write chain (skip root at index 0, pairs of [branch, parent])
  const reviewChain = [];
  for (let i = 1; i < chain.length; i++) {
    reviewChain.push({ branch: chain[i], parent: chain[i - 1] });
  }
  fs.writeFileSync(chainFile, JSON.stringify(reviewChain));
  fs.writeFileSync(stateFile, JSON.stringify({ index: 0 }));

  // Create lua init script for stack review navigation
  const luaScript = `
-- Stack Review Navigation
local chain_file = "${chainFile}"
local state_file = "${stateFile}"

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

local function open_review(idx)
  local chain = get_chain()
  if not chain or idx < 0 or idx >= #chain then return false end

  local item = chain[idx + 1]  -- lua is 1-indexed
  set_state({ index = idx })

  -- Close existing diffview if open
  pcall(vim.cmd, "DiffviewClose")

  -- Open new diffview
  vim.cmd("DiffviewOpen " .. item.parent .. "..." .. item.branch)

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

-- Reload command (re-source this script without losing position)
local script_path = "${luaFile}"
vim.api.nvim_create_user_command("StackReload", function()
  dofile(script_path)
  vim.notify("Stack review reloaded", vim.log.levels.INFO)
end, {})

-- Keybindings for navigation
vim.keymap.set("n", "]b", "<cmd>StackNext<cr>", { desc = "Next branch in stack" })
vim.keymap.set("n", "[b", "<cmd>StackPrev<cr>", { desc = "Prev branch in stack" })
vim.keymap.set("n", "<leader>gs", "<cmd>StackStatus<cr>", { desc = "Stack review status" })
vim.keymap.set("n", "<leader>gl", "<cmd>StackList<cr>", { desc = "Stack branch list" })

-- On first load, open first branch. On reload, stay at current position.
if not _G.stack_review_loaded then
  _G.stack_review_loaded = true
  open_review(0)
end
`;

  const luaFile = path.join(tmpDir, "init.lua");
  fs.writeFileSync(luaFile, luaScript);

  console.log(`\nStack Review: ${reviewChain.length} branches to review`);
  console.log("\nKeybindings:");
  console.log("  ]b / [b      next/prev branch");
  console.log("  <leader>gl   branch list (fuzzy jump)");
  console.log("  <leader>gs   show current position");
  console.log("  ]f / [f      next/prev file");
  console.log("  <tab>        toggle file panel");
  console.log("  :StackJump N jump to branch N");
  console.log("  :qa          quit review\n");

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

  console.log("\nReview complete!");
}

/**
 * Extract code snippets from diff (similar to show.ts)
 */
function extractCodeSnippets(diff: string): CodeSnippet[] {
  const snippets: CodeSnippet[] = [];
  const lines = diff.split("\n");

  let currentFile = "";
  let currentHunkStart = 0;
  let lineOffset = 0;

  // Patterns to identify function/class starts
  const startPatterns = [
    // TypeScript/JavaScript
    /^(export\s+)?(async\s+)?function\s+\w+/,
    /^(export\s+)?(const|let|var)\s+\w+\s*=\s*(async\s+)?\(/,
    /^(export\s+)?class\s+\w+/,
    /^(export\s+)?(const|let|var)\s+\w+\s*=\s*z\./,  // Zod schemas
    /^(export\s+)?(const|let|var)\s+\w+\s*=\s*\{/,   // Object literals
    // Python
    /^def\s+\w+/,
    /^class\s+\w+/,
    // Go
    /^func\s+\w+/,
    // Rust
    /^(pub\s+)?fn\s+\w+/,
    /^(pub\s+)?struct\s+\w+/,
  ];

  // Track which functions we've seen
  const seenFunctions = new Set<string>();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // File header
    if (line.startsWith("diff --git")) {
      const match = line.match(/b\/(.+)$/);
      if (match) {
        currentFile = match[1];
      }
      continue;
    }

    // Hunk header - captures line number
    if (line.startsWith("@@")) {
      const match = line.match(/@@ .+ \+(\d+)/);
      if (match) {
        currentHunkStart = parseInt(match[1], 10);
        lineOffset = 0;
      }
      continue;
    }

    // Added line that matches a function pattern
    if (line.startsWith("+") && !line.startsWith("+++")) {
      const content = line.slice(1); // Remove the +
      const trimmed = content.trim();

      for (const pattern of startPatterns) {
        if (pattern.test(trimmed)) {
          // Create a key to dedupe
          const funcKey = `${currentFile}:${trimmed.slice(0, 50)}`;
          if (seenFunctions.has(funcKey)) break;
          seenFunctions.add(funcKey);

          // Collect the function body (up to 15 lines)
          const codeLines: string[] = [];
          let braceDepth = 0;
          let started = false;

          for (let j = i; j < lines.length && codeLines.length < 15; j++) {
            const codeLine = lines[j];

            // Stop at next file or hunk
            if (codeLine.startsWith("diff --git") || codeLine.startsWith("@@")) {
              break;
            }

            // Only include added or context lines
            if (codeLine.startsWith("+") || codeLine.startsWith(" ")) {
              const actualCode = codeLine.slice(1);
              codeLines.push(actualCode);

              // Track brace depth to know when function ends
              for (const char of actualCode) {
                if (char === "{" || char === "(") {
                  braceDepth++;
                  started = true;
                }
                if (char === "}" || char === ")") {
                  braceDepth--;
                }
              }

              // End if we've closed all braces
              if (started && braceDepth === 0) {
                break;
              }
            }
          }

          // Add truncation indicator if needed
          if (codeLines.length === 15) {
            codeLines.push("  ...");
          }

          snippets.push({
            file: currentFile,
            line: currentHunkStart + lineOffset,
            code: codeLines,
          });

          break;
        }
      }
    }

    // Track line offset within hunk
    if (line.startsWith("+") && !line.startsWith("+++")) {
      lineOffset++;
    } else if (line.startsWith(" ")) {
      lineOffset++;
    }
  }

  return snippets;
}
