import { execSync, spawnSync } from "child_process";
import { writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  getCurrentBranch,
  getParent,
  getProjectBranches,
  getProjectMemory,
  getProjects,
  getTrunkBranch,
  type StackTreeNode,
} from "../lib/stack-config.ts";
import { detectPRRepo, fetchPullRequestsForBranches, type PullRequestInfo } from "../lib/gh.ts";
import { buildProjectForest } from "./project.ts";

interface TriageRow {
  branch: string;
  project: string;
  pr: PullRequestInfo;
  reason: string;
}

interface Triage {
  readyToMerge: TriageRow[];
  reviewDue: TriageRow[];
  rebaseNeeded: TriageRow[];
  ciBroken: TriageRow[];
}

function countBehind(base: string, branch: string): number {
  const r = spawnSync("git", ["rev-list", "--count", `${branch}..${base}`], {
    encoding: "utf-8",
  });
  if (r.status !== 0) return 0;
  const n = parseInt(r.stdout.trim(), 10);
  return Number.isFinite(n) ? n : 0;
}

function branchExists(name: string): boolean {
  const r = spawnSync("git", ["rev-parse", "--verify", "--quiet", name], { encoding: "utf-8" });
  return r.status === 0;
}

function buildTriage(
  projects: ProjectView[],
  prs: Map<string, PullRequestInfo>,
  trunk: string,
): Triage {
  const seen = new Set<string>();
  const out: Triage = { readyToMerge: [], reviewDue: [], rebaseNeeded: [], ciBroken: [] };

  for (const project of projects) {
    for (const branch of project.branches) {
      // Dedup: a branch can appear in multiple projects; attribute to the
      // first project we see so each triage row points somewhere stable.
      if (seen.has(branch)) continue;
      seen.add(branch);
      const pr = prs.get(branch);
      if (!pr || pr.state !== "OPEN") continue;

      if (pr.checkState === "FAILURE") {
        out.ciBroken.push({ branch, project: project.name, pr, reason: "CI failing" });
      }
      if (pr.reviewDecision === "CHANGES_REQUESTED") {
        out.reviewDue.push({
          branch,
          project: project.name,
          pr,
          reason: "Changes requested",
        });
      }
      // Rebase: behind trunk OR behind tracked parent (in stack-branch config).
      const trunkBehind = branchExists(trunk) && branchExists(branch)
        ? countBehind(trunk, branch)
        : 0;
      const parent = getParent(branch);
      const parentBehind = parent && parent !== trunk && branchExists(parent) && branchExists(branch)
        ? countBehind(parent, branch)
        : 0;
      if (trunkBehind > 0 || parentBehind > 0) {
        const parts: string[] = [];
        if (trunkBehind > 0) parts.push(`${trunkBehind} behind ${trunk}`);
        if (parentBehind > 0) parts.push(`${parentBehind} behind ${parent}`);
        out.rebaseNeeded.push({
          branch,
          project: project.name,
          pr,
          reason: parts.join(", "),
        });
      }
      // Ready: approved + passing + mergeable (and not also flagged elsewhere).
      const isReady =
        pr.reviewDecision === "APPROVED" &&
        (pr.checkState === "PASS" || pr.checkState === "NONE") &&
        pr.mergeable !== "CONFLICTING" &&
        !pr.isDraft;
      if (isReady && trunkBehind === 0 && parentBehind === 0) {
        out.readyToMerge.push({
          branch,
          project: project.name,
          pr,
          reason: pr.checkState === "PASS" ? "Approved, CI green" : "Approved",
        });
      }
    }
  }
  return out;
}

function renderTriageSection(triage: Triage): string {
  const cats: { title: string; rows: TriageRow[]; cls: string }[] = [
    { title: "Ready to merge", rows: triage.readyToMerge, cls: "triage-ready" },
    { title: "Review due", rows: triage.reviewDue, cls: "triage-review" },
    { title: "Rebase needed", rows: triage.rebaseNeeded, cls: "triage-rebase" },
    { title: "CI broken", rows: triage.ciBroken, cls: "triage-ci" },
  ];
  const populated = cats.filter((c) => c.rows.length > 0);
  if (populated.length === 0) {
    return `<section class="triage triage-empty">
      <h2 class="triage-heading">Today</h2>
      <div class="triage-empty-msg">Nothing actionable. Inbox zero. </div>
    </section>`;
  }
  const blocks = populated
    .map((c) => {
      const rows = c.rows
        .map(
          (r) => `<li class="triage-row">
        <a class="triage-pr" href="${escHtml(r.pr.url)}" target="_blank" rel="noopener">#${r.pr.number}</a>
        <span class="triage-branch">${escHtml(r.branch)}</span>
        <span class="triage-project">${escHtml(r.project)}</span>
        <span class="triage-reason">${escHtml(r.reason)}</span>
      </li>`,
        )
        .join("");
      return `<div class="triage-cat ${c.cls}">
        <h3 class="triage-cat-title">${escHtml(c.title)} <span class="triage-cat-count">${c.rows.length}</span></h3>
        <ul class="triage-list">${rows}</ul>
      </div>`;
    })
    .join("");
  return `<section class="triage">
    <h2 class="triage-heading">Today</h2>
    ${blocks}
  </section>`;
}

interface ProjectView {
  name: string;
  branches: string[];
  memory: string | null;
  forest: StackTreeNode[];
  containsCurrent: boolean;
}

function escHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderPRBadges(info: PullRequestInfo | undefined): string {
  if (!info) return "";
  const stateBadge = (() => {
    if (info.state === "MERGED") return '<span class="badge badge-merged">merged</span>';
    if (info.state === "CLOSED") return '<span class="badge badge-closed">closed</span>';
    if (info.isDraft) return '<span class="badge badge-draft">draft</span>';
    return '<span class="badge badge-open">open</span>';
  })();
  const ciBadge = (() => {
    switch (info.checkState) {
      case "PASS":
        return '<span class="badge badge-ci-pass" title="CI passing">CI ✓</span>';
      case "FAILURE":
        return '<span class="badge badge-ci-fail" title="CI failing">CI ✗</span>';
      case "PENDING":
        return '<span class="badge badge-ci-pending" title="CI pending">CI …</span>';
      default:
        return "";
    }
  })();
  const reviewBadge = (() => {
    switch (info.reviewDecision) {
      case "APPROVED":
        return '<span class="badge badge-rev-approved" title="approved">approved</span>';
      case "CHANGES_REQUESTED":
        return '<span class="badge badge-rev-changes" title="changes requested">changes</span>';
      case "REVIEW_REQUIRED":
        return '<span class="badge badge-rev-pending" title="review required">review</span>';
      default:
        return "";
    }
  })();
  const threadsBadge = info.openReviewThreads > 0
    ? `<span class="badge badge-threads" title="open review threads">${info.openReviewThreads} thread${info.openReviewThreads === 1 ? "" : "s"}</span>`
    : "";
  const prLink = `<a class="badge badge-pr" href="${escHtml(info.url)}" target="_blank" rel="noopener" title="${escHtml(info.title)}">#${info.number}</a>`;
  return `<span class="badges">${prLink}${stateBadge}${ciBadge}${reviewBadge}${threadsBadge}</span>`;
}

function renderTreeNode(
  node: StackTreeNode,
  currentBranch: string,
  depth: number,
  prs: Map<string, PullRequestInfo>,
): string {
  const isCurrent = node.name === currentBranch;
  const cls = `tree-node${isCurrent ? " tree-node-current" : ""}`;
  const indent = `padding-left:${depth * 18}px`;
  const badges = renderPRBadges(prs.get(node.name));
  const children = node.children
    .map((c) => renderTreeNode(c, currentBranch, depth + 1, prs))
    .join("");
  return `<div class="${cls}" style="${indent}">
    <span class="tree-bullet">${depth === 0 ? "●" : "└"}</span>
    <span class="tree-branch">${escHtml(node.name)}</span>
    ${badges}
  </div>${children}`;
}

function renderProjectSection(
  view: ProjectView,
  currentBranch: string,
  prs: Map<string, PullRequestInfo>,
): string {
  const openAttr = view.containsCurrent ? " open" : "";
  const memoryLine = view.memory
    ? `<div class="project-memory">memory: <code>${escHtml(view.memory)}</code></div>`
    : "";
  const tree = view.forest.map((n) => renderTreeNode(n, currentBranch, 0, prs)).join("");
  const branchCount = view.branches.length;
  return `<details class="project"${openAttr}>
    <summary class="project-summary">
      <span class="project-name">${escHtml(view.name)}</span>
      <span class="project-count">${branchCount} branch${branchCount === 1 ? "" : "es"}</span>
      ${view.containsCurrent ? '<span class="project-here">you are here</span>' : ""}
    </summary>
    ${memoryLine}
    <div class="project-tree">${tree}</div>
  </details>`;
}

function renderHeader(currentBranch: string, projectsForCurrent: string[]): string {
  const chips = projectsForCurrent.length === 0
    ? '<span class="chip chip-empty">(no project)</span>'
    : projectsForCurrent.map((p) => `<span class="chip">${escHtml(p)}</span>`).join("");
  return `<header class="page-header">
    <div class="here-label">You are here</div>
    <div class="here-branch">${escHtml(currentBranch || "(detached)")}</div>
    <div class="here-chips">${chips}</div>
  </header>`;
}

function renderHtml(
  currentBranch: string,
  projects: ProjectView[],
  prs: Map<string, PullRequestInfo>,
  triage: Triage,
): string {
  const projectsForCurrent = projects.filter((p) => p.containsCurrent).map((p) => p.name);
  const projectSections = projects.length === 0
    ? '<div class="empty">No projects defined. Create one with <code>stack project create &lt;name&gt;</code>.</div>'
    : projects.map((p) => renderProjectSection(p, currentBranch, prs)).join("\n");
  const triageHtml = renderTriageSection(triage);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Stack Home</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d1117;
      color: #c9d1d9;
      min-height: 100vh;
      padding: 32px 48px 64px;
    }
    code { font-family: ui-monospace, monospace; font-size: 12px; color: #79c0ff; }
    .page-header {
      padding: 20px 24px;
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      margin-bottom: 24px;
    }
    .here-label {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.8px;
      color: #8b949e;
      margin-bottom: 6px;
    }
    .here-branch {
      font-size: 24px;
      font-weight: 700;
      font-family: ui-monospace, monospace;
      color: #f0f6fc;
      margin-bottom: 12px;
    }
    .here-chips { display: flex; gap: 8px; flex-wrap: wrap; }
    .chip {
      background: #1f6feb;
      color: #fff;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-family: ui-monospace, monospace;
    }
    .chip-empty { background: #30363d; color: #8b949e; }
    .project {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      margin-bottom: 16px;
      overflow: hidden;
    }
    .project[open] { border-color: #58a6ff44; }
    .project-summary {
      padding: 14px 20px;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 12px;
      font-size: 14px;
      list-style: none;
    }
    .project-summary::-webkit-details-marker { display: none; }
    .project-summary::before {
      content: "▶";
      font-size: 10px;
      color: #8b949e;
      transition: transform 0.15s;
    }
    .project[open] > .project-summary::before { transform: rotate(90deg); }
    .project-name {
      font-weight: 600;
      font-family: ui-monospace, monospace;
      color: #f0f6fc;
    }
    .project-count {
      font-size: 12px;
      color: #8b949e;
      background: #21262d;
      padding: 2px 8px;
      border-radius: 10px;
    }
    .project-here {
      font-size: 11px;
      background: #1f6feb;
      color: #fff;
      padding: 2px 8px;
      border-radius: 10px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .project-memory {
      padding: 0 20px 8px;
      font-size: 12px;
      color: #8b949e;
    }
    .project-tree {
      padding: 12px 20px 20px;
      border-top: 1px solid #21262d;
    }
    .tree-node {
      padding: 4px 8px;
      font-family: ui-monospace, monospace;
      font-size: 13px;
      display: flex;
      align-items: center;
      gap: 8px;
      border-radius: 4px;
    }
    .tree-node-current {
      background: rgba(31, 111, 235, 0.18);
      color: #79c0ff;
    }
    .tree-bullet { color: #484f58; min-width: 12px; }
    .tree-branch { flex: 1; overflow: hidden; text-overflow: ellipsis; }
    .badges { display: inline-flex; gap: 6px; align-items: center; flex-shrink: 0; }
    .badge {
      font-size: 10px;
      font-weight: 600;
      padding: 2px 7px;
      border-radius: 10px;
      font-family: ui-monospace, monospace;
      letter-spacing: 0.3px;
      white-space: nowrap;
      text-decoration: none;
    }
    .badge-pr { background: #21262d; color: #79c0ff; }
    .badge-pr:hover { background: #30363d; }
    .badge-open { background: rgba(63, 185, 80, 0.18); color: #3fb950; }
    .badge-merged { background: rgba(163, 113, 247, 0.2); color: #a371f7; }
    .badge-closed { background: rgba(248, 81, 73, 0.18); color: #f85149; }
    .badge-draft { background: #21262d; color: #8b949e; }
    .badge-ci-pass { background: rgba(63, 185, 80, 0.15); color: #3fb950; }
    .badge-ci-fail { background: rgba(248, 81, 73, 0.18); color: #f85149; }
    .badge-ci-pending { background: rgba(210, 153, 34, 0.18); color: #d29922; }
    .badge-rev-approved { background: rgba(63, 185, 80, 0.15); color: #3fb950; }
    .badge-rev-changes { background: rgba(248, 81, 73, 0.18); color: #f85149; }
    .badge-rev-pending { background: rgba(210, 153, 34, 0.15); color: #d29922; }
    .badge-threads { background: rgba(88, 166, 255, 0.15); color: #58a6ff; }
    .empty {
      padding: 32px;
      text-align: center;
      color: #8b949e;
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
    }
    .triage {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      padding: 16px 20px 20px;
      margin-bottom: 24px;
    }
    .triage-heading {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.8px;
      color: #8b949e;
      margin-bottom: 12px;
    }
    .triage-empty-msg { color: #8b949e; font-size: 13px; }
    .triage-cat { margin-bottom: 16px; }
    .triage-cat:last-child { margin-bottom: 0; }
    .triage-cat-title {
      font-size: 13px;
      font-weight: 600;
      color: #f0f6fc;
      margin-bottom: 6px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .triage-ready .triage-cat-title { color: #3fb950; }
    .triage-review .triage-cat-title { color: #f85149; }
    .triage-rebase .triage-cat-title { color: #d29922; }
    .triage-ci .triage-cat-title { color: #f85149; }
    .triage-cat-count {
      background: #21262d;
      color: #8b949e;
      font-size: 10px;
      padding: 1px 7px;
      border-radius: 10px;
      font-weight: 600;
    }
    .triage-list { list-style: none; }
    .triage-row {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 6px 10px;
      border-radius: 6px;
      font-family: ui-monospace, monospace;
      font-size: 12px;
      transition: background 0.1s;
    }
    .triage-row:hover { background: #21262d; }
    .triage-pr {
      color: #79c0ff;
      font-weight: 600;
      text-decoration: none;
      min-width: 50px;
    }
    .triage-pr:hover { text-decoration: underline; }
    .triage-branch { flex: 1; color: #c9d1d9; overflow: hidden; text-overflow: ellipsis; }
    .triage-project {
      color: #8b949e;
      background: #21262d;
      padding: 1px 8px;
      border-radius: 10px;
      font-size: 10px;
    }
    .triage-reason { color: #8b949e; font-size: 11px; }
  </style>
</head>
<body>
  ${renderHeader(currentBranch, projectsForCurrent)}
  ${triageHtml}
  <div class="projects">
    ${projectSections}
  </div>
</body>
</html>`;
}

export function home(args: string[]): void {
  const skipPRs = args.includes("--no-prs");
  const currentBranch = getCurrentBranch();
  const projectNames = getProjects();

  const projects: ProjectView[] = projectNames.map((name) => {
    const branches = getProjectBranches(name);
    return {
      name,
      branches,
      memory: getProjectMemory(name),
      forest: buildProjectForest(branches),
      containsCurrent: branches.includes(currentBranch),
    };
  });

  // Sort: containsCurrent first, then alpha
  projects.sort((a, b) => {
    if (a.containsCurrent !== b.containsCurrent) return a.containsCurrent ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const prs = new Map<string, PullRequestInfo>();
  if (!skipPRs) {
    const uniqueBranches = new Set<string>();
    for (const p of projects) {
      for (const b of p.branches) uniqueBranches.add(b);
    }
    const branchList = [...uniqueBranches];
    if (branchList.length > 0) {
      console.log(`Resolving PR repo...`);
      const repo = detectPRRepo(branchList.slice(0, 3));
      if (repo) console.log(`  Using ${repo}.`);
      console.log(`Fetching PR data for ${branchList.length} branches...`);
      const fetched = fetchPullRequestsForBranches(branchList, { repo });
      for (const [k, v] of fetched) prs.set(k, v);
      console.log(`  Found ${prs.size} PR(s).`);
    }
  }

  const trunk = getTrunkBranch();
  const triage = buildTriage(projects, prs, trunk);
  const html = renderHtml(currentBranch, projects, prs, triage);
  const outPath = join(tmpdir(), "stack-home.html");
  writeFileSync(outPath, html);
  console.log(`Opening ${outPath}`);
  execSync(`open "${outPath}"`);
}
