import { gitRun } from "../lib/git.ts";

interface Move {
  from: string;
  to: string;
  value: string;
}

function listLegacyPairs(): Move[] {
  const r = gitRun(["config", "--local", "--get-regexp", "^git-town-branch\\..*\\.parent$"]);
  if (r.exitCode !== 0 || !r.stdout) return [];
  const moves: Move[] = [];
  for (const line of r.stdout.split("\n")) {
    const m = line.match(/^git-town-branch\.(.+)\.parent\s+(.+)$/);
    if (!m) continue;
    moves.push({
      from: `git-town-branch.${m[1]}.parent`,
      to: `stack-branch.${m[1]}.parent`,
      value: m[2],
    });
  }
  return moves;
}

function trunkMove(): Move | null {
  for (const key of ["git-town.main-branch", "git-town.main"]) {
    const r = gitRun(["config", "--local", key]);
    if (r.exitCode === 0 && r.stdout) {
      return { from: key, to: "stack.main-branch", value: r.stdout };
    }
  }
  return null;
}

export async function migrate(args: string[]) {
  const dryRun = args.includes("--dry-run");

  const branchMoves = listLegacyPairs();
  const trunk = trunkMove();

  if (branchMoves.length === 0 && !trunk) {
    console.log("No legacy git-town config found. Nothing to migrate.");
    return;
  }

  console.log(`\nMigrating git config${dryRun ? " (dry run)" : ""}:`);

  if (trunk) {
    console.log(`  ${trunk.from} → ${trunk.to} = ${trunk.value}`);
    if (!dryRun) {
      // Only write if the target key isn't already set (user may have run migrate before).
      const existing = gitRun(["config", "--local", trunk.to]);
      if (existing.exitCode !== 0 || !existing.stdout) {
        const w = gitRun(["config", "--local", trunk.to, trunk.value]);
        if (w.exitCode !== 0) throw new Error(`failed to set ${trunk.to}: ${w.stderr}`);
      }
      gitRun(["config", "--local", "--unset", trunk.from]);
    }
  }

  for (const mv of branchMoves) {
    console.log(`  ${mv.from} → ${mv.to} = ${mv.value}`);
    if (!dryRun) {
      const existing = gitRun(["config", "--local", mv.to]);
      if (existing.exitCode !== 0 || !existing.stdout) {
        const w = gitRun(["config", "--local", mv.to, mv.value]);
        if (w.exitCode !== 0) throw new Error(`failed to set ${mv.to}: ${w.stderr}`);
      }
      gitRun(["config", "--local", "--unset", mv.from]);
    }
  }

  // Clean up any now-empty legacy sections.
  if (!dryRun) {
    const branches = new Set(branchMoves.map((m) => m.from.split(".")[1]));
    for (const b of branches) {
      // --remove-section fails silently if keys remain or section is absent; that's fine.
      gitRun(["config", "--local", "--remove-section", `git-town-branch.${b}`]);
    }
  }

  console.log(`\n${dryRun ? "Would migrate" : "Migrated"} ${branchMoves.length} branch pointer${branchMoves.length === 1 ? "" : "s"}${trunk ? " and trunk" : ""}.`);
  if (dryRun) console.log("Re-run without --dry-run to apply.");
}
