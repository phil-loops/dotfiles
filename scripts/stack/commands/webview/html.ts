import type { BranchData, ChurnHunk } from "./data.ts";
import { escapeJs } from "./data.ts";
import { getScript } from "./script.ts";

function serializeBranches(branches: BranchData[]): string {
  return branches
    .map(
      (b) => `{
      name: "${b.name}",
      parent: "${b.parent}",
      filesChanged: ${b.filesChanged},
      insertions: ${b.insertions},
      deletions: ${b.deletions},
      message: "${escapeJs(b.message)}",
      files: [${b.files.map((f) => `{name:"${f.name}",adds:${f.adds},dels:${f.dels},diff:"${f.diff}"}`).join(",")}]
    }`
    )
    .join(",\n");
}

function serializeChurns(churns: ChurnHunk[]): string {
  return churns
    .map(
      (c) => `{
      file: "${escapeJs(c.file)}",
      addedIn: "${escapeJs(c.addedIn)}",
      removedIn: "${escapeJs(c.removedIn)}",
      addedIdx: ${c.addedIdx},
      removedIdx: ${c.removedIdx},
      lines: [${c.lines.map((l) => `"${escapeJs(l)}"`).join(",")}]
    }`
    )
    .join(",\n");
}

export function generateHtml(branches: BranchData[], churns: ChurnHunk[]): string {
  const script = getScript()
    .replace("BRANCHES_JSON", `[${serializeBranches(branches)}]`)
    .replace("CHURNS_JSON", `[${serializeChurns(churns)}]`);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Stack Viewer</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d1117;
      color: #c9d1d9;
      height: 100vh;
      overflow: hidden;
    }
    .container {
      display: grid;
      grid-template-columns: 280px 1fr;
      height: 100vh;
    }
    .sidebar {
      background: #161b22;
      border-right: 1px solid #30363d;
      overflow-y: auto;
      padding: 16px;
    }
    .sidebar h1 {
      font-size: 14px;
      color: #8b949e;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 16px;
      padding-bottom: 12px;
      border-bottom: 1px solid #30363d;
    }
    .branch-item {
      padding: 10px 12px;
      margin: 3px 0;
      border-radius: 6px;
      cursor: pointer;
      font-size: 12px;
      font-family: ui-monospace, monospace;
      transition: all 0.15s;
      display: flex;
      align-items: center;
      gap: 8px;
      border: 1px solid transparent;
    }
    .branch-item:hover { background: #21262d; }
    .branch-item.active {
      background: #1f6feb;
      border-color: #58a6ff;
    }
    .branch-num {
      background: #30363d;
      padding: 2px 6px;
      border-radius: 4px;
      font-size: 10px;
      font-weight: 600;
      min-width: 24px;
      text-align: center;
    }
    .branch-item.active .branch-num { background: rgba(255,255,255,0.2); }
    .branch-label {
      flex: 1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .branch-stats {
      font-size: 10px;
      color: #8b949e;
    }
    .branch-item.active .branch-stats { color: rgba(255,255,255,0.7); }
    .branch-done .branch-num { background: #238636; color: #fff; }
    .branch-changed .branch-num { background: #9e6a03; color: #fff; }
    .branch-partial .branch-num { background: #30363d; }
    .branch-done { color: #3fb950; }
    .branch-done .branch-label { color: #3fb950; }
    .branch-item.active.branch-done .branch-label { color: #fff; }
    .branch-done-icon, .branch-changed-icon, .branch-partial-icon { font-size: 11px; min-width: 14px; text-align: center; }
    .branch-done { font-size: 11px; }
    .branch-changed { font-size: 11px; }
    .branch-partial { font-size: 11px; }

    .main {
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .header {
      padding: 16px 20px;
      border-bottom: 1px solid #30363d;
      background: #161b22;
    }
    .header-top {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
    }
    .branch-name {
      font-size: 18px;
      font-weight: 600;
      font-family: ui-monospace, monospace;
    }
    .nav-buttons { display: flex; gap: 8px; align-items: center; }
    .nav-btn {
      background: #21262d;
      border: 1px solid #30363d;
      color: #c9d1d9;
      padding: 6px 12px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 12px;
      transition: all 0.15s;
    }
    .nav-btn:hover:not(:disabled) { background: #30363d; border-color: #8b949e; }
    .nav-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .meta {
      display: flex;
      gap: 20px;
      align-items: center;
      font-size: 13px;
    }
    .meta-item { display: flex; align-items: baseline; gap: 4px; }
    .meta-value { font-size: 18px; font-weight: 600; }
    .meta-label { color: #8b949e; font-size: 12px; }
    .additions { color: #3fb950; }
    .deletions { color: #f85149; }
    .parent-info { margin-left: auto; color: #8b949e; font-size: 12px; }
    .parent-info span { color: #58a6ff; font-family: ui-monospace, monospace; }
    .commit-msg {
      margin-top: 10px;
      padding: 10px;
      background: #0d1117;
      border-radius: 6px;
      font-size: 12px;
      color: #8b949e;
    }

    .content {
      flex: 1;
      overflow-y: auto;
      padding: 16px 20px;
    }
    .file {
      margin-bottom: 16px;
      border: 1px solid #30363d;
      border-radius: 8px;
      overflow: hidden;
    }
    .file.focused {
      border-color: #58a6ff;
      box-shadow: 0 0 0 1px #58a6ff;
    }
    .file.reviewed {
      border-color: #238636;
      opacity: 0.7;
    }
    .file.reviewed.focused {
      border-color: #58a6ff;
      box-shadow: 0 0 0 1px #58a6ff;
      opacity: 1;
    }
    .file.reviewed .file-header { background: rgba(35, 134, 54, 0.1); }
    .file-header {
      background: #161b22;
      padding: 10px 14px;
      font-family: ui-monospace, monospace;
      font-size: 12px;
      cursor: pointer;
      display: flex;
      justify-content: space-between;
      align-items: center;
      transition: background 0.15s;
    }
    .file-header:hover { background: #21262d; }
    .file-header-left {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .review-check {
      width: 16px;
      height: 16px;
      cursor: pointer;
      accent-color: #238636;
    }
    .file-name { color: #58a6ff; }
    .copy-ref-btn {
      background: transparent;
      border: 1px solid #30363d;
      color: #8b949e;
      font-size: 11px;
      padding: 0 4px;
      border-radius: 3px;
      cursor: pointer;
      margin-left: 4px;
      line-height: 1.4;
    }
    .copy-ref-btn:hover { border-color: #58a6ff; color: #58a6ff; }
    .file.reviewed .file-name { color: #3fb950; }
    .file.changed-since-review { border-color: #d29922; }
    .file.changed-since-review .file-header { background: rgba(210, 153, 34, 0.08); }
    .changed-badge {
      background: #d29922;
      color: #0d1117;
      font-size: 9px;
      font-weight: 700;
      padding: 1px 6px;
      border-radius: 10px;
      margin-left: 8px;
    }
    .delta-btn {
      background: transparent;
      border: 1px solid #d29922;
      color: #d29922;
      font-size: 9px;
      font-weight: 600;
      padding: 1px 6px;
      border-radius: 4px;
      cursor: pointer;
      margin-left: 4px;
      font-family: ui-monospace, monospace;
    }
    .delta-btn:hover { background: rgba(210, 153, 34, 0.15); }
    .file-stats { display: flex; gap: 10px; font-size: 11px; }
    .review-counter {
      font-size: 12px;
      font-family: ui-monospace, monospace;
      padding: 4px 10px;
      border-radius: 12px;
      background: #21262d;
    }

    .diff {
      display: none;
      background: #0d1117;
      font-family: ui-monospace, monospace;
      font-size: 11px;
      line-height: 1.5;
      overflow-x: auto;
    }
    .diff.expanded { display: block; }

    .diff-table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    .diff-table td {
      vertical-align: top;
      padding: 0;
    }
    .diff-side {
      width: 50%;
      border-right: 1px solid #30363d;
    }
    .diff-side:last-child { border-right: none; }
    .diff-line {
      display: flex;
      min-height: 1.5em;
    }
    .line-num {
      width: 45px;
      min-width: 45px;
      padding: 0 8px;
      text-align: right;
      color: #484f58;
      background: #161b22;
      user-select: none;
      border-right: 1px solid #30363d;
    }
    .line-content {
      flex: 1;
      padding: 0 10px;
      white-space: pre;
      overflow-x: auto;
    }
    .line-add { background: rgba(46, 160, 67, 0.15); }
    .line-add .line-content { color: #3fb950; }
    .line-del { background: rgba(248, 81, 73, 0.15); }
    .line-del .line-content { color: #f85149; }
    .line-empty { background: #161b22; }
    .line-empty .line-content { background: repeating-linear-gradient(45deg, transparent, transparent 4px, #21262d 4px, #21262d 8px); }

    .hunk-header {
      background: rgba(56, 139, 253, 0.1);
      color: #58a6ff;
      padding: 6px 12px;
      font-size: 11px;
    }

    .expand-all {
      margin-bottom: 12px;
      display: flex;
      gap: 8px;
    }
    .churn-badge {
      background: #d29922;
      color: #0d1117;
      font-size: 9px;
      font-weight: 700;
      padding: 1px 5px;
      border-radius: 10px;
      white-space: nowrap;
    }
    .branch-item.active .churn-badge { background: #f0c040; }
    .churn-panel {
      display: none;
      background: #161b22;
      border: 1px solid #d29922;
      border-radius: 8px;
      margin-bottom: 16px;
      overflow: hidden;
    }
    .churn-panel.visible { display: block; }
    .churn-panel-header {
      background: rgba(210, 153, 34, 0.15);
      color: #d29922;
      padding: 10px 14px;
      font-size: 13px;
      font-weight: 600;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .churn-item {
      padding: 8px 14px;
      border-top: 1px solid #30363d;
      font-size: 12px;
      font-family: ui-monospace, monospace;
    }
    .churn-file { color: #58a6ff; margin-bottom: 4px; }
    .churn-flow {
      display: flex;
      align-items: center;
      gap: 6px;
      color: #8b949e;
      font-size: 11px;
    }
    .churn-flow .from { color: #3fb950; }
    .churn-flow .to { color: #f85149; }
    .churn-flow .arrow { color: #d29922; }
    .churn-lines {
      margin-top: 4px;
      padding: 4px 8px;
      background: #0d1117;
      border-radius: 4px;
      font-size: 10px;
      color: #8b949e;
      max-height: 60px;
      overflow-y: auto;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="sidebar">
      <h1>Stack &middot; ${branches.length} branches</h1>
      <div id="branchList"></div>
    </div>
    <div class="main">
      <div class="header">
        <div class="header-top">
          <div class="branch-name" id="branchName"></div>
          <div class="nav-buttons">
            <span class="review-counter" id="reviewCounter"></span>
            <button class="nav-btn" id="prevBtn" onclick="nav(-1)">&larr; Prev</button>
            <button class="nav-btn" id="nextBtn" onclick="nav(1)">Next &rarr;</button>
          </div>
        </div>
        <div class="meta">
          <div class="meta-item">
            <span class="meta-value" id="filesChanged"></span>
            <span class="meta-label">files</span>
          </div>
          <div class="meta-item">
            <span class="meta-value additions" id="insertions"></span>
            <span class="meta-label">additions</span>
          </div>
          <div class="meta-item">
            <span class="meta-value deletions" id="deletions"></span>
            <span class="meta-label">deletions</span>
          </div>
          <div class="parent-info">
            parent: <span id="parentName"></span>
          </div>
        </div>
        <div class="commit-msg" id="commitMsg"></div>
      </div>
      <div class="content">
        <div class="expand-all">
          <button class="nav-btn" onclick="expandAll()">Expand All</button>
          <button class="nav-btn" onclick="collapseAll()">Collapse All</button>
          <button class="nav-btn" id="churnBtn" onclick="toggleChurn()" style="display:none;border-color:#d29922;color:#d29922">Show Churn</button>
        </div>
        <div class="churn-panel" id="churnPanel"></div>
        <div id="files"></div>
      </div>
    </div>
  </div>

  <script>${script}</script>
</body>
</html>`;
}
