import { execSync } from "child_process";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

export const STACK_FILE = join(process.cwd(), ".stack");
export const EDIT_STATE_FILE = join(process.cwd(), ".stack-edit");
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

// Maps child branch -> parent branch
export type Stack = Record<string, string>;

// State saved during `stack edit`
export type EditState = {
  returnBranch: string;
  hasStash: boolean;
};

export function loadStack(): Stack {
  if (!existsSync(STACK_FILE)) return {};
  const content = readFileSync(STACK_FILE, "utf-8");
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
  writeFileSync(STACK_FILE, content + "\n");
}

export function loadEditState(): EditState | null {
  if (!existsSync(EDIT_STATE_FILE)) return null;
  try {
    return JSON.parse(readFileSync(EDIT_STATE_FILE, "utf-8"));
  } catch {
    return null;
  }
}

export function saveEditState(state: EditState) {
  writeFileSync(EDIT_STATE_FILE, JSON.stringify(state));
}

export function clearEditState() {
  if (existsSync(EDIT_STATE_FILE)) {
    execSync(`rm ${EDIT_STATE_FILE}`);
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
