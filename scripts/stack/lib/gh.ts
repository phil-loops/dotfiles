import { spawnSync } from "child_process";

export interface MergedPR {
  number: number;
  mergedAt: string;
  baseRefName: string;
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
