import { execSync } from "child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { basename, join } from "path";

/**
 * Get the stack data directory for the current repo
 * Stored in ~/.local/share/stack/<repo-name>/
 */
function getStackDir(): string {
  // Get repo root directory name
  let repoName: string;
  try {
    const repoRoot = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
    repoName = basename(repoRoot);
  } catch {
    repoName = basename(process.cwd());
  }

  const stackDir = join(homedir(), ".local", "share", "stack", repoName);

  // Create directory if it doesn't exist
  if (!existsSync(stackDir)) {
    mkdirSync(stackDir, { recursive: true });
  }

  return stackDir;
}

export function getStackFile(): string {
  return join(getStackDir(), "stack");
}

export function getEditStateFile(): string {
  return join(getStackDir(), "edit-state");
}

const LOCAL_CONFIG_FILE = join(process.cwd(), ".stackrc");
const GLOBAL_CONFIG_FILE = join(homedir(), ".stackrc");

export type Config = {
  remote?: string; // e.g. "phil-loops" or "origin"
  repo?: string; // e.g. "phil-loops/loops" for gh commands
};

/**
 * Load config from .stackrc (local takes precedence over global)
 * Format: JSON { "remote": "phil-loops", "repo": "phil-loops/loops" }
 */
export function loadConfig(): Config {
  let config: Config = {};

  // Load global first
  if (existsSync(GLOBAL_CONFIG_FILE)) {
    try {
      config = { ...config, ...JSON.parse(readFileSync(GLOBAL_CONFIG_FILE, "utf-8")) };
    } catch {
      // ignore invalid config
    }
  }

  // Local overrides global
  if (existsSync(LOCAL_CONFIG_FILE)) {
    try {
      config = { ...config, ...JSON.parse(readFileSync(LOCAL_CONFIG_FILE, "utf-8")) };
    } catch {
      // ignore invalid config
    }
  }

  return config;
}

// Maps child branch -> parent branch (explicit mode)
export type Stack = Record<string, string>;

// Convention-based stack config
export type ConventionConfig = {
  prefix: string; // e.g., "goals-"
  root: string; // e.g., "main"
};

// State saved during `stack edit`
export type EditState = {
  returnBranch: string;
  hasStash: boolean;
};

function getConventionFile(): string {
  return join(getStackDir(), "convention");
}

export function loadConvention(): ConventionConfig | null {
  const file = getConventionFile();
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf-8"));
  } catch {
    return null;
  }
}

export function saveConvention(config: ConventionConfig) {
  writeFileSync(getConventionFile(), JSON.stringify(config, null, 2) + "\n");
}

export function clearConvention() {
  const file = getConventionFile();
  if (existsSync(file)) {
    execSync(`rm "${file}"`);
  }
}

/**
 * Get all branches matching a prefix, sorted numerically
 * Handles: goals-1, goals-1.5, goals-2, goals-10
 */
export function getBranchesByPrefix(prefix: string): string[] {
  try {
    const allBranches = git("branch --list").split("\n").map((b) => b.trim().replace(/^\*\s*/, ""));
    const matching = allBranches.filter((b) => b.startsWith(prefix));

    // Extract numeric suffix and sort
    return matching.sort((a, b) => {
      const numA = parseFloat(a.slice(prefix.length)) || 0;
      const numB = parseFloat(b.slice(prefix.length)) || 0;
      return numA - numB;
    });
  } catch {
    return [];
  }
}

/**
 * Get the parent branch in a convention-based stack
 */
export function getConventionParent(branch: string, config: ConventionConfig): string | null {
  const branches = getBranchesByPrefix(config.prefix);
  const idx = branches.indexOf(branch);
  if (idx <= 0) return config.root; // First branch or not found -> root is parent
  return branches[idx - 1];
}

/**
 * Get children in a convention-based stack
 */
export function getConventionChildren(branch: string, config: ConventionConfig): string[] {
  const branches = getBranchesByPrefix(config.prefix);
  if (branch === config.root) {
    return branches.length > 0 ? [branches[0]] : [];
  }
  const idx = branches.indexOf(branch);
  if (idx === -1 || idx === branches.length - 1) return [];
  return [branches[idx + 1]];
}

/**
 * Check if current branch matches a convention prefix
 */
export function matchesConvention(branch: string, config: ConventionConfig): boolean {
  return branch.startsWith(config.prefix);
}

export function loadStack(): Stack {
  const stackFile = getStackFile();
  if (!existsSync(stackFile)) return {};
  const content = readFileSync(stackFile, "utf-8");
  const stack: Stack = {};
  for (const line of content.trim().split("\n")) {
    if (!line) continue;
    const [child, parent] = line.split(":");
    if (child && parent) stack[child] = parent;
  }
  return stack;
}

export function saveStack(stack: Stack) {
  const content = Object.entries(stack)
    .map(([child, parent]) => `${child}:${parent}`)
    .join("\n");
  writeFileSync(getStackFile(), content + "\n");
}

export function loadEditState(): EditState | null {
  const editFile = getEditStateFile();
  if (!existsSync(editFile)) return null;
  try {
    return JSON.parse(readFileSync(editFile, "utf-8"));
  } catch {
    return null;
  }
}

export function saveEditState(state: EditState) {
  writeFileSync(getEditStateFile(), JSON.stringify(state));
}

export function clearEditState() {
  const editFile = getEditStateFile();
  if (existsSync(editFile)) {
    execSync(`rm "${editFile}"`);
  }
}

export function git(cmd: string): string {
  return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
}

export function gitTry(cmd: string): boolean {
  try {
    execSync(`git ${cmd}`, { encoding: "utf-8", stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export type ConflictResult = {
  hasConflict: boolean;
  files: string[];
};

/**
 * Check if rebasing child onto parent would cause conflicts
 * Uses git merge-tree to simulate the merge without touching working directory
 */
export function checkConflict(parent: string, child: string): ConflictResult {
  try {
    const mergeBase = git(`merge-base ${parent} ${child}`);
    execSync(`git merge-tree ${mergeBase} ${parent} ${child}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { hasConflict: false, files: [] };
  } catch (e: any) {
    const output = e.stdout?.toString() || "";
    const stderr = e.stderr?.toString() || "";
    const conflictFiles: string[] = [];

    const lines = (output + stderr).split("\n");
    for (const line of lines) {
      if (line.includes("CONFLICT")) {
        const match = line.match(/Merge conflict in (.+)$/);
        if (match) {
          conflictFiles.push(match[1]);
        }
      }
    }

    if (conflictFiles.length === 0 && output.includes("<<<<<<")) {
      return { hasConflict: true, files: ["(unable to parse specific files)"] };
    }

    return { hasConflict: conflictFiles.length > 0, files: conflictFiles };
  }
}

export function currentBranch(): string {
  return git("branch --show-current");
}

export function getChildren(stack: Stack, branch: string): string[] {
  return Object.entries(stack)
    .filter(([_, parent]) => parent === branch)
    .map(([child]) => child);
}

export function getDescendants(stack: Stack, branch: string): string[] {
  const children = getChildren(stack, branch);
  const descendants: string[] = [];
  for (const child of children) {
    descendants.push(child);
    descendants.push(...getDescendants(stack, child));
  }
  return descendants;
}

export function findRoot(stack: Stack, branch: string): string {
  let current = branch;
  while (stack[current]) {
    current = stack[current];
  }
  return current;
}

export function wouldCreateCycle(stack: Stack, child: string, parent: string): boolean {
  let current = parent;
  while (stack[current]) {
    if (stack[current] === child) return true;
    current = stack[current];
  }
  return false;
}

export function getChainFromRoot(stack: Stack, branch: string): string[] {
  const root = findRoot(stack, branch);
  const chain: string[] = [];

  function walk(b: string) {
    const children = getChildren(stack, b);
    for (const child of children) {
      chain.push(child);
      walk(child);
    }
  }

  walk(root);
  return chain;
}

export function createBackup(branch: string): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const backupName = `backup/${branch}/${timestamp}`;
  git(`branch ${backupName} ${branch}`);
  return backupName;
}

export function listBackups(branch: string): string[] {
  try {
    const output = git(`branch --list "backup/${branch}/*"`);
    return output
      .split("\n")
      .map((b) => b.trim().replace(/^\*?\s*/, ""))
      .filter(Boolean);
  } catch {
    return [];
  }
}

export function getForkRemote(): string {
  const config = loadConfig();

  // Config takes precedence
  if (config.remote) return config.remote;

  // Fallback to auto-detection
  try {
    const remotes = git("remote").split("\n");
    if (remotes.includes("phil-loops")) return "phil-loops";
    return "origin";
  } catch {
    return "origin";
  }
}

export function getGitHubRepo(): string | null {
  const config = loadConfig();

  // Config takes precedence
  if (config.repo) return config.repo;

  // Fallback to auto-detection from remote URL
  try {
    const remote = getForkRemote();
    const url = git(`remote get-url ${remote}`);
    const match = url.match(/github\.com[:/]([^/]+\/[^/.]+)/);
    return match ? match[1].replace(/\.git$/, "") : null;
  } catch {
    return null;
  }
}
