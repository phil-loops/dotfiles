import { git } from "./git.ts";

export type FileFilter = { includeTsx: boolean; includeTests: boolean };

export const defaultFileFilter: FileFilter = { includeTsx: false, includeTests: false };

export function matchesFilter(file: string, filter: FileFilter): boolean {
  if (!file.endsWith(".ts") && !file.endsWith(".tsx")) return false;
  if (file.endsWith(".tsx") && !filter.includeTsx) return false;
  if (file.endsWith(".test.ts") && !filter.includeTests) return false;
  if (file.endsWith(".test.tsx") && !filter.includeTests) return false;
  return true;
}

// Check if a file diff has deletions (real drift) vs just additions (acceptable growth)
export function hasMinusLines(parent: string, child: string, file: string): boolean {
  try {
    const diff = git(`diff ${parent}...${child} -- "${file}"`);
    return diff.split("\n").some((l) => l.startsWith("-") && !l.startsWith("---"));
  } catch {
    return false;
  }
}

export type DriftInfo = {
  file: string;
  introducedIn: string;
  modifiedIn: string[];
};

export type BranchHealth = {
  clean: boolean;
  driftedFiles: number;
  driftedFileList: string[];
  totalFiles: number;
};

export type BranchDriftInfo = {
  fileDrifts: DriftInfo[];
  branchHealth: Map<string, BranchHealth>;
};

export function getDrifts(
  orderedBranches: string[],
  stack: Record<string, string>,
  filter: FileFilter = defaultFileFilter
): BranchDriftInfo {
  const fileIntroducedIn = new Map<string, string>();
  const fileDrifts: DriftInfo[] = [];
  const filesPerBranch = new Map<string, Set<string>>();

  // First pass: track which files each branch introduces
  for (let i = 1; i < orderedBranches.length; i++) {
    const parent = orderedBranches[i - 1];
    const child = orderedBranches[i];

    try {
      const diffOutput = git(`diff --name-only ${parent}...${child}`);
      if (!diffOutput) continue;

      const files = diffOutput.split("\n").filter((f) => matchesFilter(f, filter));

      for (const file of files) {
        if (!fileIntroducedIn.has(file)) {
          fileIntroducedIn.set(file, child);
          if (!filesPerBranch.has(child)) {
            filesPerBranch.set(child, new Set());
          }
          filesPerBranch.get(child)!.add(file);
        } else {
          // Only count as drift if there are deletions (not just additions)
          if (hasMinusLines(parent, child, file)) {
            const introducedIn = fileIntroducedIn.get(file)!;
            let drift = fileDrifts.find((d) => d.file === file);
            if (!drift) {
              drift = { file, introducedIn, modifiedIn: [] };
              fileDrifts.push(drift);
            }
            drift.modifiedIn.push(child);
          }
        }
      }
    } catch {
      // skip
    }
  }

  // Second pass: compute per-branch health
  const branchHealth = new Map<string, BranchHealth>();

  for (const branch of orderedBranches) {
    const files = filesPerBranch.get(branch) || new Set();
    const driftedFilesInfo = fileDrifts.filter((d) => d.introducedIn === branch);
    branchHealth.set(branch, {
      clean: driftedFilesInfo.length === 0,
      driftedFiles: driftedFilesInfo.length,
      driftedFileList: driftedFilesInfo.map((d) => d.file),
      totalFiles: files.size,
    });
  }

  return { fileDrifts, branchHealth };
}

/**
 * Get the diff content for a drifted file between where it was introduced
 * and where it was modified
 */
export function getDriftDiff(drift: DriftInfo, stack: Record<string, string>): string {
  const { file, introducedIn, modifiedIn } = drift;
  const lastModified = modifiedIn[modifiedIn.length - 1];

  try {
    return git(`diff ${introducedIn}...${lastModified} -- "${file}"`);
  } catch {
    return "";
  }
}
