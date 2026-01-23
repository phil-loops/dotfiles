import { execSync } from "child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { basename, join } from "path";
import { git } from "./git.ts";

/**
 * Get the stack data directory for the current repo
 * Stored in ~/.local/share/stack/<repo-name>/
 */
function getStackDir(): string {
  let repoName: string;
  try {
    const repoRoot = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
    repoName = basename(repoRoot);
  } catch {
    repoName = basename(process.cwd());
  }

  const stackDir = join(homedir(), ".local", "share", "stack", repoName);

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

export function getSnapshotFile(): string {
  return join(getStackDir(), "snapshot");
}

export function getAckFile(): string {
  return join(getStackDir(), "ack");
}

// Maps child branch -> parent branch
export type Stack = Record<string, string>;

// State saved during `stack edit`
export type EditState = {
  returnBranch: string;
  hasStash: boolean;
};

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

// Snapshot: records branch HEADs before operations
export type Snapshot = {
  timestamp: string;
  operation: string;
  branches: Record<string, string>; // branch name -> commit hash
};

export function saveSnapshot(operation: string, branches: string[]) {
  const snapshot: Snapshot = {
    timestamp: new Date().toISOString(),
    operation,
    branches: {},
  };

  for (const branch of branches) {
    try {
      snapshot.branches[branch] = git(`rev-parse ${branch}`);
    } catch {
      // Branch might not exist yet
    }
  }

  writeFileSync(getSnapshotFile(), JSON.stringify(snapshot, null, 2));
}

export function loadSnapshot(): Snapshot | null {
  const snapshotFile = getSnapshotFile();
  if (!existsSync(snapshotFile)) return null;
  try {
    return JSON.parse(readFileSync(snapshotFile, "utf-8"));
  } catch {
    return null;
  }
}

export function saveAck(branches: string[]) {
  const ack: Snapshot = {
    timestamp: new Date().toISOString(),
    operation: "ack",
    branches: {},
  };

  for (const branch of branches) {
    try {
      ack.branches[branch] = git(`rev-parse ${branch}`);
    } catch {
      // Branch might not exist
    }
  }

  writeFileSync(getAckFile(), JSON.stringify(ack, null, 2));
}

export function loadAck(): Snapshot | null {
  const ackFile = getAckFile();
  if (!existsSync(ackFile)) return null;
  try {
    return JSON.parse(readFileSync(ackFile, "utf-8"));
  } catch {
    return null;
  }
}
