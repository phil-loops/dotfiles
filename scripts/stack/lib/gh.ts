import { spawnSync } from "child_process";

export interface MergedPR {
  number: number;
  mergedAt: string;
  baseRefName: string;
}

export interface PullRequestInfo {
  branch: string;
  number: number;
  state: "OPEN" | "CLOSED" | "MERGED";
  isDraft: boolean;
  url: string;
  title: string;
  baseRefName: string;
  reviewDecision: "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED" | "" | null;
  mergeable: "MERGEABLE" | "CONFLICTING" | "UNKNOWN" | null;
  /** Roll-up "PASS" | "PENDING" | "FAILURE" computed from statusCheckRollup. */
  checkState: "PASS" | "PENDING" | "FAILURE" | "NONE";
  openReviewThreads: number;
  updatedAt: string;
}

interface RawCheck {
  __typename?: string;
  state?: string;
  conclusion?: string;
  status?: string;
}

interface RawPR {
  number: number;
  state: "OPEN" | "CLOSED" | "MERGED";
  isDraft: boolean;
  url: string;
  title: string;
  baseRefName: string;
  headRefName: string;
  reviewDecision: PullRequestInfo["reviewDecision"];
  mergeable: PullRequestInfo["mergeable"];
  statusCheckRollup?: RawCheck[];
  comments?: unknown[];
  updatedAt: string;
}

function rollupCheckState(checks: RawCheck[] | undefined): PullRequestInfo["checkState"] {
  if (!checks || checks.length === 0) return "NONE";
  let anyPending = false;
  let anyFailure = false;
  for (const c of checks) {
    // gh emits CheckRun (status + conclusion) or StatusContext (state).
    const status = (c.status || "").toUpperCase();
    const conclusion = (c.conclusion || "").toUpperCase();
    const state = (c.state || "").toUpperCase();
    if (status && status !== "COMPLETED") {
      anyPending = true;
      continue;
    }
    const result = conclusion || state;
    if (!result) continue;
    if (result === "SUCCESS" || result === "NEUTRAL" || result === "SKIPPED") continue;
    if (result === "PENDING" || result === "QUEUED" || result === "IN_PROGRESS") {
      anyPending = true;
    } else {
      anyFailure = true;
    }
  }
  if (anyFailure) return "FAILURE";
  if (anyPending) return "PENDING";
  return "PASS";
}

/**
 * Fetch open/closed PR info for one branch via `gh pr list`. Returns null when
 * gh has nothing for that branch.
 */
export function fetchPullRequestForBranch(
  branch: string,
  opts: { cwd?: string; repo?: string } = {},
): PullRequestInfo | null {
  const args = ["pr", "list"];
  if (opts.repo) args.push("--repo", opts.repo);
  args.push(
    "--head", branch,
    "--state", "all",
    "--json",
    "number,state,isDraft,url,title,baseRefName,headRefName,reviewDecision,mergeable,statusCheckRollup,comments,updatedAt",
    "--limit", "1",
  );
  const r = spawnSync("gh", args, {
    encoding: "utf-8",
    cwd: opts.cwd,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (r.status !== 0) return null;
  let parsed: RawPR[];
  try {
    parsed = JSON.parse(r.stdout || "[]");
  } catch {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length === 0) return null;
  const pr = parsed[0];
  // gh pr list doesn't expose reviewThreads; comments count is the coarse
  // approximation we surface for now. Phase 3 upgrades this for the triage
  // panel using `gh api graphql`.
  const commentCount = Array.isArray(pr.comments) ? pr.comments.length : 0;
  return {
    branch,
    number: pr.number,
    state: pr.state,
    isDraft: pr.isDraft,
    url: pr.url,
    title: pr.title,
    baseRefName: pr.baseRefName,
    reviewDecision: pr.reviewDecision,
    mergeable: pr.mergeable,
    checkState: rollupCheckState(pr.statusCheckRollup),
    openReviewThreads: commentCount,
    updatedAt: pr.updatedAt,
  };
}

/**
 * Fetch PR info for many branches. gh has no native batch list-by-heads, so
 * this sequentially walks them. Returns a Map keyed by branch name; missing
 * entries mean "no PR".
 *
 * If `repo` is supplied, all lookups target that repo (e.g. `phil-loops/loops`
 * for a fork); otherwise gh's default remote resolution applies.
 */
export function fetchPullRequestsForBranches(
  branches: string[],
  opts: { cwd?: string; repo?: string } = {},
): Map<string, PullRequestInfo> {
  const out = new Map<string, PullRequestInfo>();
  for (const branch of branches) {
    const info = fetchPullRequestForBranch(branch, opts);
    if (info) out.set(branch, info);
  }
  return out;
}

/**
 * Pick the best repo to query PRs against. Prefers a fork remote (anything
 * not named `origin`) when it has at least one PR for a probe branch; falls
 * back to undefined (= gh default = origin).
 */
export function detectPRRepo(probeBranches: string[], opts: { cwd?: string } = {}): string | undefined {
  const remotes = spawnSync("git", ["remote"], { encoding: "utf-8", cwd: opts.cwd });
  if (remotes.status !== 0) return undefined;
  const names = remotes.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
  const candidates: string[] = [];
  for (const name of names) {
    if (name === "origin") continue;
    const url = spawnSync("git", ["remote", "get-url", name], { encoding: "utf-8", cwd: opts.cwd });
    if (url.status !== 0) continue;
    const m = url.stdout.trim().match(/[:/]([^:/]+\/[^:/]+?)(?:\.git)?$/);
    if (m) candidates.push(m[1]);
  }
  for (const repo of candidates) {
    for (const branch of probeBranches) {
      const info = fetchPullRequestForBranch(branch, { ...opts, repo });
      if (info) return repo;
    }
  }
  return undefined;
}

/**
 * Ask gh if a branch has a merged PR on the given repo.
 * Returns the PR metadata if merged, otherwise null.
 */
export function findMergedPR(repo: string, branch: string): MergedPR | null {
  const r = spawnSync(
    "gh",
    [
      "pr",
      "list",
      "--repo", repo,
      "--state", "merged",
      "--head", branch,
      "--json", "number,mergedAt,baseRefName",
      "--limit", "1",
    ],
    { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 },
  );
  if (r.status !== 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(r.stdout || "[]");
    if (Array.isArray(parsed) && parsed.length > 0) {
      return parsed[0] as MergedPR;
    }
  } catch {
    return null;
  }
  return null;
}
