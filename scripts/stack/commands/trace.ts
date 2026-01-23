import type { Command } from "../types.ts";
import { git, loadStack, currentBranch } from "../lib.ts";
import { getCurrentStack } from "../graph.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";

type FileChange = {
  branch: string;
  parent: string | null;
  status: "introduced" | "modified" | "unchanged" | "deleted";
  additions: number;
  deletions: number;
};

function getFileAtBranch(branch: string, file: string): string | null {
  try {
    return execSync(`git show ${branch}:${file}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
}

function getDiffStats(
  parent: string,
  child: string,
  file: string
): { additions: number; deletions: number } {
  try {
    const stat = execSync(
      `git diff --numstat ${parent}..${child} -- "${file}"`,
      { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] }
    ).trim();

    if (!stat) return { additions: 0, deletions: 0 };

    const [add, del] = stat.split("\t");
    return {
      additions: parseInt(add, 10) || 0,
      deletions: parseInt(del, 10) || 0,
    };
  } catch {
    return { additions: 0, deletions: 0 };
  }
}

function traceFile(file: string, branches: string[], stack: Record<string, string>): FileChange[] {
  const changes: FileChange[] = [];

  for (const branch of branches) {
    const parent = stack[branch] || null;
    const contentAtBranch = getFileAtBranch(branch, file);
    const contentAtParent = parent ? getFileAtBranch(parent, file) : null;

    let status: FileChange["status"];
    let additions = 0;
    let deletions = 0;

    if (contentAtBranch === null && contentAtParent === null) {
      // File doesn't exist in either - skip
      continue;
    } else if (contentAtBranch === null && contentAtParent !== null) {
      status = "deleted";
      deletions = contentAtParent.split("\n").length;
    } else if (contentAtBranch !== null && contentAtParent === null) {
      status = "introduced";
      additions = contentAtBranch.split("\n").length;
    } else if (contentAtBranch === contentAtParent) {
      status = "unchanged";
    } else {
      status = "modified";
      const stats = getDiffStats(parent!, branch, file);
      additions = stats.additions;
      deletions = stats.deletions;
    }

    changes.push({ branch, parent, status, additions, deletions });
  }

  return changes;
}

export const command: Command = {
  category: "info",
  name: "trace",
  help: "Trace a file's evolution through the stack",
  args: "<file> [--diff]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      diff: { type: "boolean", short: "d" },
    });

    const file = positionals[0];
    if (!file) {
      console.error("Usage: stack trace <file> [--diff]");
      process.exit(1);
    }

    const stack = loadStack();
    const branch = currentBranch();
    const branches = getCurrentStack(stack, branch);

    if (branches.length === 0) {
      console.log("Not in a tracked stack.");
      return;
    }

    console.log(`\nTracing: ${file}\n`);

    const changes = traceFile(file, branches, stack);

    if (changes.length === 0) {
      console.log("File not found in any branch of the stack.");
      return;
    }

    // Find where file was introduced
    const introduced = changes.find((c) => c.status === "introduced");
    if (introduced) {
      console.log(`Introduced in: ${introduced.branch}`);
    }

    // Count modifications
    const mods = changes.filter((c) => c.status === "modified");
    if (mods.length > 0) {
      console.log(`Modified in: ${mods.length} branch${mods.length > 1 ? "es" : ""}`);
    }

    console.log("");

    // Show each branch
    for (const change of changes) {
      const statusIcon =
        change.status === "introduced"
          ? "+"
          : change.status === "modified"
          ? "~"
          : change.status === "deleted"
          ? "-"
          : " ";

      const stats =
        change.status === "unchanged"
          ? ""
          : change.status === "introduced"
          ? `+${change.additions} lines`
          : change.status === "deleted"
          ? `-${change.deletions} lines`
          : `+${change.additions}/-${change.deletions}`;

      console.log(`${statusIcon} ${change.branch}${stats ? `  (${stats})` : ""}`);

      // Show diff if requested and file changed
      if (values.diff && change.status === "modified" && change.parent) {
        try {
          const diff = execSync(
            `git diff --color=always ${change.parent}..${change.branch} -- "${file}"`,
            { encoding: "utf-8" }
          ).trim();

          if (diff) {
            // Indent diff output
            const lines = diff.split("\n");
            for (const line of lines) {
              console.log(`    ${line}`);
            }
            console.log("");
          }
        } catch {
          // Ignore
        }
      }
    }

    // Summary
    const totalAdd = changes.reduce((sum, c) => sum + c.additions, 0);
    const totalDel = changes.reduce((sum, c) => sum + c.deletions, 0);
    console.log(`\nTotal: +${totalAdd}/-${totalDel} lines across ${changes.filter(c => c.status !== "unchanged").length} changes`);
  },
};
