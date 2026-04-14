import { execSync, spawnSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

export interface GitResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export function gitRun(args: string[], opts: { cwd?: string } = {}): GitResult {
  const result = spawnSync("git", args, {
    cwd: opts.cwd,
    encoding: "utf-8",
    maxBuffer: 100 * 1024 * 1024,
  });
  return {
    stdout: (result.stdout || "").trim(),
    stderr: (result.stderr || "").trim(),
    exitCode: result.status ?? 1,
  };
}

export function gitOk(args: string[], opts: { cwd?: string } = {}): string {
  const r = gitRun(args, opts);
  if (r.exitCode !== 0) {
    const err = new Error(`git ${args.join(" ")} failed: ${r.stderr || r.stdout}`);
    (err as any).stdout = r.stdout;
    (err as any).stderr = r.stderr;
    (err as any).exitCode = r.exitCode;
    throw err;
  }
  return r.stdout;
}

export function gitInherit(args: string[]): void {
  const r = spawnSync("git", args, { stdio: "inherit" });
  if (r.status !== 0) {
    throw new Error(`git ${args.join(" ")} exited ${r.status}`);
  }
}

export function gitDir(): string {
  return gitOk(["rev-parse", "--git-dir"]);
}

export function repoRoot(): string {
  return gitOk(["rev-parse", "--show-toplevel"]);
}

export function currentBranch(): string {
  return gitOk(["branch", "--show-current"]);
}

export function isDirty(): boolean {
  const r = gitRun(["status", "--porcelain"]);
  return r.stdout.length > 0;
}

export function inRebase(): boolean {
  const dir = gitDir();
  return existsSync(join(dir, "rebase-merge")) || existsSync(join(dir, "rebase-apply"));
}

export function hasRemoteBranch(remote: string, branch: string): boolean {
  const r = gitRun(["rev-parse", "--verify", `refs/remotes/${remote}/${branch}`]);
  return r.exitCode === 0;
}

export function hasLocalBranch(branch: string): boolean {
  const r = gitRun(["rev-parse", "--verify", `refs/heads/${branch}`]);
  return r.exitCode === 0;
}

export function remoteUrl(remote: string): string {
  return gitOk(["remote", "get-url", remote]);
}

/** Parse owner/repo from a git remote URL (ssh or https). */
export function repoSlugFromRemote(remote: string): string | null {
  let url: string;
  try {
    url = remoteUrl(remote);
  } catch {
    return null;
  }
  const m = url.match(/[:/]([^:/]+\/[^:/]+?)(?:\.git)?$/);
  return m ? m[1] : null;
}

export function conflictFiles(): string[] {
  const out = gitRun(["diff", "--name-only", "--diff-filter=U"]).stdout;
  return out.split("\n").filter(Boolean);
}

export function rebaseAbort(): void {
  gitRun(["rebase", "--abort"]);
}

export function pushForceWithLease(remote: string, branch: string): void {
  const r = spawnSync(
    "git",
    ["push", "--force-with-lease", remote, branch],
    { stdio: "inherit" },
  );
  if (r.status !== 0) {
    throw new Error(`push ${remote} ${branch} failed`);
  }
}

/** Legacy helper used elsewhere in the codebase. */
export function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}
