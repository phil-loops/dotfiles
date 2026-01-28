import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}

function escapeJs(text: string): string {
  return text
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r");
}

interface BranchData {
  name: string;
  parent: string;
  filesChanged: number;
  insertions: number;
  deletions: number;
  message: string;
  files: { name: string; adds: number; dels: number; diff: string }[];
}

interface ChurnHunk {
  file: string;
  addedIn: string;
  removedIn: string;
  addedIdx: number;
  removedIdx: number;
  lines: string[];
}

function detectChurn(branches: BranchData[]): ChurnHunk[] {
  // For each branch, collect added/removed lines per file
  const branchAdds: Map<string, Map<string, Set<string>>>[] = []; // idx -> file -> Set<trimmedLine>

  for (let i = 0; i < branches.length; i++) {
    const adds = new Map<string, Set<string>>();
    const b = branches[i];

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

  // Cross-reference: for each removed line in branch[j], check earlier branches
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
            // Found churn - check if we can merge with existing
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

function getBranchesFromGitTown(prefix?: string): { name: string; parent: string }[] {
  const config = git("config --get-regexp git-town-branch");
  const branches: { name: string; parent: string }[] = [];

  for (const line of config.split("\n")) {
    const match = line.match(/git-town-branch\.(.+)\.parent\s+(.+)/);
    if (match) {
      const name = match[1];
      if (prefix && !name.startsWith(prefix)) continue;
      branches.push({ name, parent: match[2] });
    }
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

function getBranchData(name: string, parent: string): BranchData {
  // Use -w to ignore whitespace
  const stat = git(`diff -w ${parent}..${name} --stat`);
  const lastLine = stat.split("\n").pop() || "";

  const filesMatch = lastLine.match(/(\d+) file/);
  const insertMatch = lastLine.match(/(\d+) insertion/);
  const deleteMatch = lastLine.match(/(\d+) deletion/);

  const filesChanged = filesMatch ? parseInt(filesMatch[1]) : 0;
  const insertions = insertMatch ? parseInt(insertMatch[1]) : 0;
  const deletions = deleteMatch ? parseInt(deleteMatch[1]) : 0;

  const message = git(`log ${parent}..${name} --format="%s" -1`);

  // Get files with their diffs (ignoring whitespace)
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

function generateHtml(branches: BranchData[], churns: ChurnHunk[]): string {
  const churnsJson = churns
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

  const branchesJson = branches
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
    .nav-buttons { display: flex; gap: 8px; }
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
    .file-name { color: #58a6ff; }
    .file-stats { display: flex; gap: 10px; font-size: 11px; }

    .diff {
      display: none;
      background: #0d1117;
      font-family: ui-monospace, monospace;
      font-size: 11px;
      line-height: 1.5;
      overflow-x: auto;
    }
    .diff.expanded { display: block; }

    /* Side-by-side layout */
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
      <h1>Stack · ${branches.length} branches</h1>
      <div id="branchList"></div>
    </div>
    <div class="main">
      <div class="header">
        <div class="header-top">
          <div class="branch-name" id="branchName"></div>
          <div class="nav-buttons">
            <button class="nav-btn" id="prevBtn" onclick="nav(-1)">← Prev</button>
            <button class="nav-btn" id="nextBtn" onclick="nav(1)">Next →</button>
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

  <script>
    const branches = [${branchesJson}];
    const churns = [${churnsJson}];
    let idx = 0;
    let expanded = new Set();

    // Build churn counts per branch (where lines were added)
    const churnByBranch = {};
    for (const c of churns) {
      churnByBranch[c.addedIn] = (churnByBranch[c.addedIn] || 0) + c.lines.length;
    }

    function escHtml(s) {
      return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function parseDiff(diff) {
      if (!diff) return [];
      const lines = diff.split('\\n');
      const hunks = [];
      let currentHunk = null;

      for (const line of lines) {
        if (line.startsWith('@@')) {
          // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
          const match = line.match(/@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@(.*)$/);
          if (match) {
            currentHunk = {
              oldStart: parseInt(match[1]),
              newStart: parseInt(match[2]),
              context: match[3] || '',
              oldLines: [],
              newLines: []
            };
            hunks.push(currentHunk);
          }
        } else if (currentHunk) {
          if (line.startsWith('+') && !line.startsWith('+++')) {
            currentHunk.newLines.push({ type: 'add', content: line.slice(1) });
          } else if (line.startsWith('-') && !line.startsWith('---')) {
            currentHunk.oldLines.push({ type: 'del', content: line.slice(1) });
          } else if (!line.startsWith('diff ') && !line.startsWith('index ') && !line.startsWith('---') && !line.startsWith('+++')) {
            // Context line - goes in both
            const content = line.startsWith(' ') ? line.slice(1) : line;
            currentHunk.oldLines.push({ type: 'ctx', content });
            currentHunk.newLines.push({ type: 'ctx', content });
          }
        }
      }
      return hunks;
    }

    function renderSideBySide(hunks) {
      if (hunks.length === 0) return '<div class="hunk-header">(no changes)</div>';

      let html = '<table class="diff-table">';

      for (const hunk of hunks) {
        html += '<tr><td colspan="2" class="hunk-header">@@ -' + hunk.oldStart + ' +' + hunk.newStart + ' @@' + escHtml(hunk.context) + '</td></tr>';

        // Pair up deletions and additions where possible
        const oldLines = [...hunk.oldLines];
        const newLines = [...hunk.newLines];

        let oldIdx = 0, newIdx = 0;
        let oldLineNum = hunk.oldStart;
        let newLineNum = hunk.newStart;

        while (oldIdx < oldLines.length || newIdx < newLines.length) {
          const oldLine = oldLines[oldIdx];
          const newLine = newLines[newIdx];

          let leftHtml = '', rightHtml = '';

          if (oldLine && newLine && oldLine.type === 'ctx' && newLine.type === 'ctx') {
            // Both context - show side by side
            leftHtml = '<div class="diff-line"><span class="line-num">' + oldLineNum + '</span><span class="line-content">' + escHtml(oldLine.content) + '</span></div>';
            rightHtml = '<div class="diff-line"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
            oldIdx++; newIdx++; oldLineNum++; newLineNum++;
          } else if (oldLine && oldLine.type === 'del') {
            // Deletion on left, check if there's a matching addition
            leftHtml = '<div class="diff-line line-del"><span class="line-num">' + oldLineNum + '</span><span class="line-content">' + escHtml(oldLine.content) + '</span></div>';
            oldIdx++; oldLineNum++;

            if (newLine && newLine.type === 'add') {
              rightHtml = '<div class="diff-line line-add"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
              newIdx++; newLineNum++;
            } else {
              rightHtml = '<div class="diff-line line-empty"><span class="line-num"></span><span class="line-content"></span></div>';
            }
          } else if (newLine && newLine.type === 'add') {
            // Addition on right only
            leftHtml = '<div class="diff-line line-empty"><span class="line-num"></span><span class="line-content"></span></div>';
            rightHtml = '<div class="diff-line line-add"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
            newIdx++; newLineNum++;
          } else {
            // Shouldn't happen but handle anyway
            if (oldLine) { oldIdx++; oldLineNum++; }
            if (newLine) { newIdx++; newLineNum++; }
            continue;
          }

          html += '<tr><td class="diff-side">' + leftHtml + '</td><td class="diff-side">' + rightHtml + '</td></tr>';
        }
      }

      html += '</table>';
      return html;
    }

    function render() {
      const b = branches[idx];
      document.getElementById('branchList').innerHTML = branches.map((br, i) => {
        const cc = churnByBranch[br.name] || 0;
        const churnBadge = cc > 0 ? \`<span class="churn-badge" title="\${cc} churned lines">~\${cc}</span>\` : '';
        return \`<div class="branch-item \${i === idx ? 'active' : ''}" onclick="go(\${i})">
          <span class="branch-num">\${String(i + 1).padStart(2, '0')}</span>
          <span class="branch-label">\${br.name.replace(/^goals-v2-\\d+-/, '')}</span>
          \${churnBadge}
          <span class="branch-stats">+\${br.insertions}/-\${br.deletions}</span>
        </div>\`;
      }).join('');

      document.getElementById('branchName').textContent = b.name;
      document.getElementById('filesChanged').textContent = b.filesChanged;
      document.getElementById('insertions').textContent = '+' + b.insertions;
      document.getElementById('deletions').textContent = '-' + b.deletions;
      document.getElementById('parentName').textContent = b.parent;
      document.getElementById('commitMsg').textContent = b.message || '(no commit message)';
      document.getElementById('prevBtn').disabled = idx === 0;
      document.getElementById('nextBtn').disabled = idx === branches.length - 1;

      document.getElementById('files').innerHTML = b.files.map((f, i) => {
        const hunks = parseDiff(f.diff);
        return \`<div class="file">
          <div class="file-header" onclick="toggle(\${i})">
            <span class="file-name">\${f.name}</span>
            <span class="file-stats">
              <span class="additions">+\${f.adds}</span>
              <span class="deletions">-\${f.dels}</span>
            </span>
          </div>
          <div class="diff \${expanded.has(i) ? 'expanded' : ''}" id="diff-\${i}">\${renderSideBySide(hunks)}</div>
        </div>\`;
      }).join('');

      renderChurnPanel();
    }

    function toggle(i) {
      expanded.has(i) ? expanded.delete(i) : expanded.add(i);
      document.getElementById('diff-' + i).classList.toggle('expanded');
    }
    function expandAll() {
      branches[idx].files.forEach((_, i) => {
        expanded.add(i);
        document.getElementById('diff-' + i)?.classList.add('expanded');
      });
    }
    function collapseAll() {
      expanded.clear();
      document.querySelectorAll('.diff').forEach(el => el.classList.remove('expanded'));
    }
    function go(i) { idx = i; expanded.clear(); render(); }
    function nav(d) { if (idx + d >= 0 && idx + d < branches.length) go(idx + d); }

    function renderChurnPanel() {
      const btn = document.getElementById('churnBtn');
      const panel = document.getElementById('churnPanel');

      // Filter churns relevant to current branch
      const branchName = branches[idx].name;
      const relevant = churns.filter(c => c.addedIn === branchName || c.removedIn === branchName);

      if (relevant.length === 0 && churns.length === 0) {
        btn.style.display = 'none';
        panel.classList.remove('visible');
        return;
      }

      btn.style.display = '';
      const total = churns.length;
      btn.textContent = 'Churn (' + total + ' hunks)';

      const items = (relevant.length > 0 ? relevant : churns).map(c => {
        const fromShort = c.addedIn.replace(/^goals-v2-\\d+-/, '');
        const toShort = c.removedIn.replace(/^goals-v2-\\d+-/, '');
        const preview = c.lines.slice(0, 3).map(l => escHtml(l.length > 80 ? l.slice(0, 77) + '...' : l)).join('\\n');
        const more = c.lines.length > 3 ? '\\n... +' + (c.lines.length - 3) + ' more' : '';
        return \`<div class="churn-item">
          <div class="churn-file">\${c.file}</div>
          <div class="churn-flow">
            <span class="from">+ \${fromShort}</span>
            <span class="arrow">→</span>
            <span class="to">- \${toShort}</span>
            <span>(\${c.lines.length} lines)</span>
          </div>
          <div class="churn-lines">\${preview}\${more}</div>
        </div>\`;
      }).join('');

      panel.innerHTML = \`
        <div class="churn-panel-header">
          <span>\${relevant.length > 0 ? 'Churn for ' + branchName.replace(/^goals-v2-\\d+-/, '') : 'All churn'} (\${(relevant.length || churns.length)} hunks)</span>
          <button class="nav-btn" onclick="toggleChurn()" style="padding:2px 8px;font-size:11px">×</button>
        </div>
        \${items}\`;
    }

    function toggleChurn() {
      const panel = document.getElementById('churnPanel');
      panel.classList.toggle('visible');
    }

    document.addEventListener('keydown', e => {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') nav(-1);
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') nav(1);
      if (e.key === 'e') expandAll();
      if (e.key === 'c') collapseAll();
    });

    render();
  </script>
</body>
</html>`;
}

export function webview(args: string[]) {
  const prefix = args[0];

  console.log("Gathering branch data (ignoring whitespace)...");
  if (prefix) console.log(`Filtering branches with prefix: ${prefix}`);

  const branches = getBranchesFromGitTown(prefix);
  if (branches.length === 0) {
    console.error("No branches found with git-town parent config.");
    if (prefix) {
      console.error(`No branches found matching prefix: ${prefix}`);
    }
    console.error("Make sure branches have parents set via: git config git-town-branch.<branch>.parent <parent>");
    process.exit(1);
  }

  console.log(`Found ${branches.length} branches in stack`);

  const branchData = branches.map((b) => {
    process.stdout.write(`  ${b.name}...`);
    const data = getBranchData(b.name, b.parent);
    console.log(` ${data.filesChanged} files, +${data.insertions}/-${data.deletions}`);
    return data;
  });

  console.log("Detecting churn...");
  const churnData = detectChurn(branchData);
  if (churnData.length > 0) {
    console.log(`  Found ${churnData.length} churn hunks`);
  } else {
    console.log("  No churn detected");
  }

  const html = generateHtml(branchData, churnData);
  const outPath = join(tmpdir(), "stack-view.html");
  writeFileSync(outPath, html);

  console.log(`\nOpening ${outPath}`);
  execSync(`open "${outPath}"`);
}
