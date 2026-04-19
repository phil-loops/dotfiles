import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import {
  conflictFiles,
  currentBranch,
  gitDir,
  gitOk,
  gitRun,
  hasLocalBranch,
  hasRemoteBranch,
  inRebase,
  isDirty,
  pushForceWithLease,
  rebaseAbort,
  repoRoot,
  repoSlugFromRemote,
} from "../lib/git.ts";
import {
  clearBranchConfig,
  getAllParentPointers,
  getStackPrefix,
  getStackTree,
  getTrunkBranch,
  setParent,
  walkTopDown,
} from "../lib/stack-config.ts";
import { findMergedPR } from "../lib/gh.ts";
import { resolveWithClaude } from "../lib/claude-resolver.ts";

interface Pending {
  name: string;
  parent: string;
  /** "remote" = next step is rebase onto `${remote}/${name}`, "parent" = onto parent. */
  phase: "remote" | "parent" | "push";
}

interface SyncState {
  original: string;
  prefix?: string;
  remote: string;
  noAutoResolve: boolean;
  pending: Pending[];
}

const STATE_NAME = "stack-sync-state.json";

function stateFile(): string {
  return join(gitDir(), STATE_NAME);
}

function writeState(state: SyncState): void {
  writeFileSync(stateFile(), JSON.stringify(state, null, 2));
}

function readState(): SyncState | null {
  const path = stateFile();
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

function clearState(): void {
  const path = stateFile();
  if (existsSync(path)) unlinkSync(path);
}

function log(msg: string): void {
  process.stdout.write(msg + "\n");
}

function warn(msg: string): void {
  process.stderr.write(msg + "\n");
}

export async function sync(args: string[]): Promise<void> {
  const continueMode = args.includes("--continue");
  const abortMode = args.includes("--abort");
  const dryRun = args.includes("--dry-run");
  const noAutoResolve = args.includes("--no-auto-resolve");
  const noPrune = args.includes("--no-prune");
  const syncAll = args.includes("--all");
  const remote =
    args.find((a) => a.startsWith("--remote="))?.split("=")[1] || "phil-loops";
  const positional = args.find(
    (a) => !a.startsWith("-"),
  );

  if (abortMode) {
    return abort();
  }

  if (continueMode) {
    return resume();
  }

  if (isDirty()) {
    warn("Working tree has uncommitted changes. Commit or stash first.");
    process.exit(1);
  }
  if (inRebase()) {
    warn("A rebase is already in progress. Resolve it, then run `loops stack sync --continue`.");
    process.exit(1);
  }

  const original = currentBranch();
  if (!original) {
    warn("Detached HEAD — refusing to sync.");
    process.exit(1);
  }

  // --all syncs every tracked branch; otherwise filter by positional or inferred prefix.
  // If no prefix can be inferred, fall through to everything.
  const prefix = syncAll ? undefined : positional || getStackPrefix();

  log(`\nFetching from ${remote} and origin...`);
  if (!dryRun) {
    gitRun(["fetch", "--prune", "--tags", remote]);
    gitRun(["fetch", "--prune", "origin"]);
  }

  // Update trunk locally from origin, then mirror it to the fork so `${remote}/${trunk}`
  // never falls behind origin (keeps `gh pr create --base <trunk>` diffs honest).
  const trunk = detectTrunk();
  if (!dryRun && trunk) {
    const onTrunk = original === trunk;
    if (!onTrunk) gitRun(["checkout", trunk]);
    gitRun(["merge", "--ff-only", `origin/${trunk}`]);
    if (!onTrunk) gitRun(["checkout", original]);
    mirrorTrunkToFork(trunk, remote);
  }

  if (!noPrune) {
    await pruneMerged({ remote, prefix, dryRun, originalBranch: original });
  }

  // Re-read stack after pruning may have removed entries.
  const roots = prefix ? getStackTree(prefix) : getStackTree();
  const ordered = walkTopDown(roots);

  if (ordered.length === 0) {
    log("No tracked branches to sync.");
    maybeCheckout(original);
    return;
  }

  log(`\nRebasing ${ordered.length} branch${ordered.length === 1 ? "" : "es"}:`);
  for (const n of ordered) log(`  ${n.name} → ${n.parent}`);
  log("");

  if (dryRun) {
    log("(dry run — no changes made)");
    return;
  }

  const pending: Pending[] = ordered.flatMap((n) => [
    { name: n.name, parent: n.parent, phase: "remote" as const },
    { name: n.name, parent: n.parent, phase: "parent" as const },
    { name: n.name, parent: n.parent, phase: "push" as const },
  ]);

  const state: SyncState = {
    original: hasLocalBranch(original) ? original : trunk || "main",
    prefix,
    remote,
    noAutoResolve,
    pending,
  };

  await runLoop(state);
}

async function resume(): Promise<void> {
  const state = readState();
  if (!state) {
    warn("No sync in progress.");
    process.exit(1);
  }

  if (inRebase()) {
    log("Continuing in-flight rebase...");
    const r = gitRun(["-c", "core.editor=true", "rebase", "--continue"]);
    if (r.exitCode !== 0) {
      // Still unresolved conflicts. Offer Claude again or bail.
      if (!state.noAutoResolve) {
        const resolved = await tryClaudeOnCurrentConflict(state);
        if (!resolved) {
          warn("Conflicts remain. Resolve manually, `git add`, then `loops stack sync --continue`.");
          process.exit(1);
        }
      } else {
        warn("Conflicts remain. Resolve manually, `git add`, then `loops stack sync --continue`.");
        process.exit(1);
      }
    }
  }

  // The head of pending was "in flight" — it's now done, so drop it.
  state.pending.shift();
  await runLoop(state);
}

async function abort(): Promise<void> {
  if (inRebase()) {
    log("Aborting in-flight rebase...");
    rebaseAbort();
  }
  const state = readState();
  if (state) {
    maybeCheckout(state.original);
  }
  clearState();
  log("Sync aborted.");
}

async function runLoop(state: SyncState): Promise<void> {
  while (state.pending.length > 0) {
    const step = state.pending[0];
    writeState(state);

    if (step.phase === "remote") {
      await stepRemote(step, state);
    } else if (step.phase === "parent") {
      await stepParent(step, state);
    } else {
      await stepPush(step, state);
    }

    state.pending.shift();
  }

  maybeCheckout(state.original);
  clearState();
  log("\nSync complete.");
}

async function stepRemote(step: Pending, state: SyncState): Promise<void> {
  checkout(step.name);
  if (!hasRemoteBranch(state.remote, step.name)) return;

  const aheadBehind = gitRun([
    "rev-list", "--left-right", "--count",
    `${step.name}...${state.remote}/${step.name}`,
  ]);
  if (aheadBehind.exitCode === 0) {
    const [, behind] = aheadBehind.stdout.split("\t").map((s) => parseInt(s, 10));
    if (!behind) return; // local already has all remote commits
  }

  log(`[${step.name}] picking up ${state.remote}/${step.name}`);
  const r = gitRun(["rebase", `${state.remote}/${step.name}`]);
  if (r.exitCode !== 0) {
    await handleConflict({
      state,
      branch: step.name,
      onto: `${state.remote}/${step.name}`,
    });
  }
}

async function stepParent(step: Pending, state: SyncState): Promise<void> {
  checkout(step.name);
  const parentRef = step.parent === detectTrunk() ? `origin/${step.parent}` : step.parent;

  // Skip if already up to date.
  const base = gitRun(["merge-base", step.name, parentRef]).stdout;
  const parentTip = gitRun(["rev-parse", parentRef]).stdout;
  if (base && parentTip && base === parentTip) {
    return;
  }

  log(`[${step.name}] rebase onto ${parentRef}`);
  const r = gitRun(["rebase", parentRef]);
  if (r.exitCode !== 0) {
    await handleConflict({ state, branch: step.name, onto: parentRef });
  }
}

async function stepPush(step: Pending, state: SyncState): Promise<void> {
  checkout(step.name);
  log(`[${step.name}] push --force-with-lease ${state.remote}`);
  try {
    pushForceWithLease(state.remote, step.name);
  } catch (e: any) {
    warn(`push failed for ${step.name}: ${e.message}`);
    process.exit(1);
  }
}

async function handleConflict(opts: {
  state: SyncState;
  branch: string;
  onto: string;
}): Promise<void> {
  const files = conflictFiles();
  warn(`\nConflict rebasing ${opts.branch} onto ${opts.onto}:`);
  for (const f of files) warn(`  ${f}`);

  if (opts.state.noAutoResolve) {
    warn(`\nResolve the files, run \`git add\` + \`git rebase --continue\`, then:`);
    warn(`    loops stack sync --continue`);
    warn(`Or abort with: loops stack sync --abort`);
    process.exit(1);
  }

  log("\nHanding off to Claude...");
  const result = resolveWithClaude({
    branch: opts.branch,
    onto: opts.onto,
    files,
    repoRoot: repoRoot(),
  });

  if (result.kind === "resolved") {
    log(`Claude resolved ${result.files.length} file${result.files.length === 1 ? "" : "s"}; continuing rebase.`);
    const add = gitRun(["add", ...result.files]);
    if (add.exitCode !== 0) {
      warn(`git add failed: ${add.stderr}`);
      process.exit(1);
    }
    const cont = gitRun(["-c", "core.editor=true", "rebase", "--continue"]);
    if (cont.exitCode !== 0) {
      // Claude's resolution produced a new conflict chunk downstream.
      await handleConflict(opts);
    }
    return;
  }

  if (result.kind === "unresolvable") {
    warn(`\nClaude marked this unresolvable: ${result.reason}`);
  } else {
    warn(`\nClaude handoff failed: ${result.reason}`);
  }
  warn(`\nResolve manually, \`git add\`, then:`);
  warn(`    loops stack sync --continue`);
  warn(`Or abort with: loops stack sync --abort`);
  process.exit(1);
}

async function tryClaudeOnCurrentConflict(state: SyncState): Promise<boolean> {
  const step = state.pending[0];
  if (!step) return false;
  const files = conflictFiles();
  if (files.length === 0) return true;
  const onto = step.phase === "remote" ? `${state.remote}/${step.name}` : step.parent;
  const result = resolveWithClaude({
    branch: step.name,
    onto,
    files,
    repoRoot: repoRoot(),
  });
  if (result.kind !== "resolved") return false;
  gitRun(["add", ...result.files]);
  const cont = gitRun(["-c", "core.editor=true", "rebase", "--continue"]);
  return cont.exitCode === 0;
}

async function pruneMerged(opts: {
  remote: string;
  prefix?: string;
  dryRun: boolean;
  originalBranch: string;
}): Promise<string[]> {
  const repo = repoSlugFromRemote(opts.remote);
  if (!repo) {
    log(`Skipping merged-branch prune (can't resolve ${opts.remote} repo).`);
    return [];
  }

  const all = getAllParentPointers();
  const candidates = opts.prefix
    ? all.filter((b) => b.name.startsWith(opts.prefix!))
    : all;

  const merged: { name: string; parent: string }[] = [];
  for (const b of candidates) {
    const pr = findMergedPR(repo, b.name);
    if (pr) merged.push(b);
  }

  if (merged.length === 0) return [];

  log(`\nMerged branches to prune (${merged.length}):`);
  for (const m of merged) log(`  ${m.name} (→ ${m.parent})`);

  if (opts.dryRun) return merged.map((m) => m.name);

  // Re-parent children before deleting the merged branch.
  for (const m of merged) {
    const children = all.filter((b) => b.parent === m.name);
    for (const c of children) {
      setParent(c.name, m.parent);
      log(`  re-parented ${c.name} → ${m.parent}`);
    }
  }

  // Make sure we're not on any branch we're about to delete.
  const onMerged = merged.some((m) => m.name === currentBranch());
  if (onMerged) {
    const trunk = detectTrunk();
    if (trunk) checkout(trunk);
  }

  for (const m of merged) {
    const del = gitRun(["branch", "-D", m.name]);
    if (del.exitCode === 0) {
      log(`  deleted local ${m.name}`);
    } else {
      warn(`  failed to delete local ${m.name}: ${del.stderr}`);
    }
    clearBranchConfig(m.name);
    if (hasRemoteBranch(opts.remote, m.name)) {
      const r = gitRun(["push", opts.remote, "--delete", m.name]);
      if (r.exitCode === 0) log(`  deleted ${opts.remote}/${m.name}`);
    }
  }

  return merged.map((m) => m.name);
}

/** Fast-forward `${remote}/${trunk}` to match `origin/${trunk}`. No-op if already in sync
 * or if the fork has commits origin doesn't (don't want to clobber work). */
function mirrorTrunkToFork(trunk: string, remote: string): void {
  if (remote === "origin") return;
  if (!hasRemoteBranch("origin", trunk)) return;
  if (!hasRemoteBranch(remote, trunk)) return;

  const ahead = gitRun(["rev-list", "--count", `origin/${trunk}..${remote}/${trunk}`]);
  const behind = gitRun(["rev-list", "--count", `${remote}/${trunk}..origin/${trunk}`]);
  const aheadN = parseInt(ahead.stdout, 10) || 0;
  const behindN = parseInt(behind.stdout, 10) || 0;

  if (behindN === 0 && aheadN === 0) return;
  if (aheadN > 0) {
    warn(`${remote}/${trunk} has ${aheadN} commit(s) not on origin/${trunk} — skipping mirror.`);
    return;
  }

  log(`Mirroring origin/${trunk} → ${remote}/${trunk} (+${behindN})`);
  const r = gitRun(["push", remote, `origin/${trunk}:refs/heads/${trunk}`]);
  if (r.exitCode !== 0) {
    warn(`  push failed: ${r.stderr}`);
  }
}

function detectTrunk(): string {
  const trunk = getTrunkBranch();
  if (trunk !== "main") return trunk;
  // getTrunkBranch defaults to "main" if nothing configured; verify against origin/HEAD
  // before trusting it, so repos with a non-"main" trunk and no config still work.
  const head = gitRun(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]);
  if (head.exitCode === 0 && head.stdout) {
    return head.stdout.replace(/^origin\//, "");
  }
  return trunk;
}

function checkout(branch: string): void {
  if (currentBranch() === branch) return;
  try {
    gitOk(["checkout", branch]);
  } catch (e: any) {
    warn(`checkout ${branch} failed: ${e.message}`);
    process.exit(1);
  }
}

function maybeCheckout(branch: string): void {
  if (!branch || !hasLocalBranch(branch)) return;
  if (currentBranch() === branch) return;
  gitRun(["checkout", branch]);
}
