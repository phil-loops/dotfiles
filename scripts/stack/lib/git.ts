import { execSync, spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
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

/** SHA of the commit the in-progress rebase is currently stopped on, or null. */
export function stoppedSha(): string | null {
  const dir = gitDir();
  const merge = join(dir, "rebase-merge", "stopped-sha");
  if (existsSync(merge)) return readFileSync(merge, "utf-8").trim();
  const apply = join(dir, "rebase-apply", "original-commit");
  if (existsSync(apply)) return readFileSync(apply, "utf-8").trim();
  return null;
}

/** True iff every hunk of `sha`'s patch is already present on HEAD.
 *
 * The check is `git apply --check --reverse` on the commit's diff: succeeds
 * only when reverse-applying every hunk works, which means every hunk is
 * currently in the tree. If any hunk is new (local fixups that didn't make
 * it into the squash-merge), `--reverse --check` fails. */
export function isGhostCommit(sha: string): boolean {
  const patch = gitRun(["show", "--patch", "--no-color", sha]);
  if (patch.exitCode !== 0 || !patch.stdout) return false;

  // Clear conflict markers so `git apply --check` operates on a clean tree.
  gitRun(["checkout", "--", "."]);

  const apply = spawnSync("git", ["apply", "--check", "--reverse", "-"], {
    input: patch.stdout,
    encoding: "utf-8",
  });
  return apply.status === 0;
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
