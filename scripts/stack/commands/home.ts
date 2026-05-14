import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  getCurrentBranch,
  getProjectBranches,
  getProjectMemory,
  getProjects,
  getProjectsForBranch,
  type StackTreeNode,
} from "../lib/stack-config.ts";
import { buildProjectForest } from "./project.ts";

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

function renderTreeNode(node: StackTreeNode, currentBranch: string, depth: number): string {
  const isCurrent = node.name === currentBranch;
  const cls = `tree-node${isCurrent ? " tree-node-current" : ""}`;
  const indent = `padding-left:${depth * 18}px`;
  const children = node.children
    .map((c) => renderTreeNode(c, currentBranch, depth + 1))
    .join("");
  return `<div class="${cls}" style="${indent}">
    <span class="tree-bullet">${depth === 0 ? "●" : "└"}</span>
    <span class="tree-branch">${escHtml(node.name)}</span>
  </div>${children}`;
}

function renderProjectSection(view: ProjectView, currentBranch: string): string {
  const openAttr = view.containsCurrent ? " open" : "";
  const memoryLine = view.memory
    ? `<div class="project-memory">memory: <code>${escHtml(view.memory)}</code></div>`
    : "";
  const tree = view.forest.map((n) => renderTreeNode(n, currentBranch, 0)).join("");
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

function renderHtml(currentBranch: string, projects: ProjectView[]): string {
  const projectsForCurrent = projects.filter((p) => p.containsCurrent).map((p) => p.name);
  const projectSections = projects.length === 0
    ? '<div class="empty">No projects defined. Create one with <code>stack project create &lt;name&gt;</code>.</div>'
    : projects.map((p) => renderProjectSection(p, currentBranch)).join("\n");

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
    .empty {
      padding: 32px;
      text-align: center;
      color: #8b949e;
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
    }
  </style>
</head>
<body>
  ${renderHeader(currentBranch, projectsForCurrent)}
  <div class="projects">
    ${projectSections}
  </div>
</body>
</html>`;
}

export function home(_args: string[]): void {
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

  const html = renderHtml(currentBranch, projects);
  const outPath = join(tmpdir(), "stack-home.html");
  writeFileSync(outPath, html);
  console.log(`Opening ${outPath}`);
  execSync(`open "${outPath}"`);
}
