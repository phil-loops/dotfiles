import { execSync } from "child_process";
import { getAllParentPointers } from "../../lib/stack-config.ts";

function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}

export function escapeJs(text: string): string {
  return text
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r");
}

export interface BranchData {
  name: string;
  parent: string;
  filesChanged: number;
  insertions: number;
  deletions: number;
  message: string;
  files: { name: string; adds: number; dels: number; diff: string }[];
}

export interface ChurnHunk {
  file: string;
  addedIn: string;
  removedIn: string;
  addedIdx: number;
  removedIdx: number;
  lines: string[];
}

export function getStackBranchesForWebview(prefix?: string): { name: string; parent: string }[] {
  const all = getAllParentPointers();
  const branches: { name: string; parent: string }[] = [];

  for (const { name, parent } of all) {
    if (prefix && !name.startsWith(prefix)) continue;
    branches.push({ name, parent });
  }

  const sorted: { name: string; parent: string }[] = [];
  const remaining = [...branches];
  let current = "main";

  while (remaining.length > 0) {
    const idx = remaining.findIndex((b) => b.parent === current);
    if (idx === -1) break;
    const branch = remaining.splice(idx, 1)[0];
    sorted.push(branch);
    current = branch.name;
  }

  return sorted;
}

export function getBranchData(name: string, parent: string): BranchData {
  const stat = git(`diff -w ${parent}..${name} --stat`);
  const lastLine = stat.split("\n").pop() || "";

  const filesMatch = lastLine.match(/(\d+) file/);
  const insertMatch = lastLine.match(/(\d+) insertion/);
  const deleteMatch = lastLine.match(/(\d+) deletion/);

  const filesChanged = filesMatch ? parseInt(filesMatch[1]) : 0;
  const insertions = insertMatch ? parseInt(insertMatch[1]) : 0;
  const deletions = deleteMatch ? parseInt(deleteMatch[1]) : 0;

  const message = git(`log ${parent}..${name} --format="%s" -1`);

  const numstat = git(`diff -w ${parent}..${name} --numstat`);
  const files: BranchData["files"] = [];

  for (const line of numstat.split("\n")) {
    if (!line.trim()) continue;
    const [adds, dels, filename] = line.split("\t");
    if (!filename) continue;

    const diff = git(`diff -w ${parent}..${name} -- "${filename}"`);
    files.push({
      name: filename,
      adds: parseInt(adds) || 0,
      dels: parseInt(dels) || 0,
      diff: escapeJs(diff),
    });
  }

  return { name, parent, filesChanged, insertions, deletions, message, files };
}

export function detectChurn(branches: BranchData[]): ChurnHunk[] {
  const branchAdds: Map<string, Set<string>>[] = [];

  for (const b of branches) {
    const adds = new Map<string, Set<string>>();
    for (const f of b.files) {
      const fileAdds = new Set<string>();
      for (const rawLine of f.diff.split("\n")) {
        if (rawLine.startsWith("+") && !rawLine.startsWith("+++")) {
          const content = rawLine.slice(1).trim();
          if (content) fileAdds.add(content);
        }
      }
      if (fileAdds.size > 0) adds.set(f.name, fileAdds);
    }
    branchAdds.push(adds);
  }

  const churns: ChurnHunk[] = [];

  for (let j = 1; j < branches.length; j++) {
    const b = branches[j];
    const removedByFile = new Map<string, Set<string>>();

    for (const f of b.files) {
      const fileRemoves = new Set<string>();
      for (const rawLine of f.diff.split("\n")) {
        if (rawLine.startsWith("-") && !rawLine.startsWith("---")) {
          const content = rawLine.slice(1).trim();
          if (content) fileRemoves.add(content);
        }
      }
      if (fileRemoves.size > 0) removedByFile.set(f.name, fileRemoves);
    }

    for (const [file, removedLines] of removedByFile) {
      for (const line of removedLines) {
        for (let i = 0; i < j; i++) {
          const earlierAdds = branchAdds[i].get(file);
          if (earlierAdds?.has(line)) {
            const existing = churns.find(
              (c) => c.file === file && c.addedIdx === i && c.removedIdx === j
            );
            if (existing) {
              existing.lines.push(line);
            } else {
              churns.push({
                file,
                addedIn: branches[i].name,
                removedIn: branches[j].name,
                addedIdx: i,
                removedIdx: j,
                lines: [line],
              });
            }
            break;
          }
        }
      }
    }
  }

  return churns;
}
