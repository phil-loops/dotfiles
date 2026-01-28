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

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
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

function getBranchesFromGitTown(prefix?: string): { name: string; parent: string }[] {
  // Get all branches with git-town parents
  const config = git("config --get-regexp git-town-branch");
  const branches: { name: string; parent: string }[] = [];

  for (const line of config.split("\n")) {
    const match = line.match(/git-town-branch\.(.+)\.parent\s+(.+)/);
    if (match) {
      const name = match[1];
      // Filter by prefix if provided
      if (prefix && !name.startsWith(prefix)) continue;
      branches.push({ name, parent: match[2] });
    }
  }

  // Sort by finding the chain from main
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
  const stat = git(`diff ${parent}..${name} --stat`);
  const lastLine = stat.split("\n").pop() || "";

  const filesMatch = lastLine.match(/(\d+) file/);
  const insertMatch = lastLine.match(/(\d+) insertion/);
  const deleteMatch = lastLine.match(/(\d+) deletion/);

  const filesChanged = filesMatch ? parseInt(filesMatch[1]) : 0;
  const insertions = insertMatch ? parseInt(insertMatch[1]) : 0;
  const deletions = deleteMatch ? parseInt(deleteMatch[1]) : 0;

  const message = git(`log ${parent}..${name} --format="%s" -1`);

  // Get files with their diffs
  const numstat = git(`diff ${parent}..${name} --numstat`);
  const files: BranchData["files"] = [];

  for (const line of numstat.split("\n")) {
    if (!line.trim()) continue;
    const [adds, dels, filename] = line.split("\t");
    if (!filename) continue;

    const diff = git(`diff ${parent}..${name} -- "${filename}"`);
    files.push({
      name: filename,
      adds: parseInt(adds) || 0,
      dels: parseInt(dels) || 0,
      diff: escapeJs(diff),
    });
  }

  return { name, parent, filesChanged, insertions, deletions, message, files };
}

function generateHtml(branches: BranchData[]): string {
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
      grid-template-columns: 300px 1fr;
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
      padding: 12px;
      margin: 4px 0;
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
      font-family: ui-monospace, monospace;
      transition: all 0.15s;
      display: flex;
      align-items: center;
      gap: 10px;
      border: 1px solid transparent;
    }
    .branch-item:hover { background: #21262d; }
    .branch-item.active {
      background: #1f6feb;
      border-color: #58a6ff;
    }
    .branch-num {
      background: #30363d;
      padding: 3px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 600;
      min-width: 28px;
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
      font-size: 11px;
      color: #8b949e;
    }
    .branch-item.active .branch-stats { color: rgba(255,255,255,0.7); }

    .main {
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .header {
      padding: 20px 24px;
      border-bottom: 1px solid #30363d;
      background: #161b22;
    }
    .header-top {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 16px;
    }
    .branch-name {
      font-size: 20px;
      font-weight: 600;
      font-family: ui-monospace, monospace;
    }
    .nav-buttons { display: flex; gap: 8px; }
    .nav-btn {
      background: #21262d;
      border: 1px solid #30363d;
      color: #c9d1d9;
      padding: 8px 16px;
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
      transition: all 0.15s;
    }
    .nav-btn:hover:not(:disabled) { background: #30363d; border-color: #8b949e; }
    .nav-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .meta {
      display: flex;
      gap: 24px;
      align-items: center;
    }
    .meta-item {
      display: flex;
      align-items: baseline;
      gap: 6px;
    }
    .meta-value {
      font-size: 24px;
      font-weight: 600;
    }
    .meta-label { color: #8b949e; font-size: 13px; }
    .additions { color: #3fb950; }
    .deletions { color: #f85149; }
    .parent-info {
      margin-left: auto;
      color: #8b949e;
      font-size: 13px;
    }
    .parent-info span { color: #58a6ff; font-family: ui-monospace, monospace; }
    .commit-msg {
      margin-top: 12px;
      padding: 12px;
      background: #0d1117;
      border-radius: 6px;
      font-size: 13px;
      color: #8b949e;
    }

    .content {
      flex: 1;
      overflow-y: auto;
      padding: 16px 24px;
    }
    .file {
      margin-bottom: 16px;
      border: 1px solid #30363d;
      border-radius: 8px;
      overflow: hidden;
    }
    .file-header {
      background: #161b22;
      padding: 12px 16px;
      font-family: ui-monospace, monospace;
      font-size: 13px;
      cursor: pointer;
      display: flex;
      justify-content: space-between;
      align-items: center;
      transition: background 0.15s;
    }
    .file-header:hover { background: #21262d; }
    .file-name { color: #58a6ff; }
    .file-stats { display: flex; gap: 12px; }
    .diff {
      display: none;
      background: #0d1117;
      font-family: ui-monospace, monospace;
      font-size: 12px;
      line-height: 1.6;
      overflow-x: auto;
    }
    .diff.expanded { display: block; }
    .diff-line {
      padding: 0 16px;
      white-space: pre;
      min-height: 1.6em;
    }
    .diff-add { background: rgba(46, 160, 67, 0.15); color: #3fb950; }
    .diff-del { background: rgba(248, 81, 73, 0.15); color: #f85149; }
    .diff-hunk { background: rgba(56, 139, 253, 0.1); color: #58a6ff; padding-top: 8px; padding-bottom: 8px; }
    .diff-meta { color: #8b949e; }

    .expand-all {
      margin-bottom: 16px;
      display: flex;
      gap: 8px;
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
        </div>
        <div id="files"></div>
      </div>
    </div>
  </div>

  <script>
    const branches = [${branchesJson}];
    let idx = 0;
    let expanded = new Set();

    function render() {
      const b = branches[idx];
      document.getElementById('branchList').innerHTML = branches.map((br, i) =>
        \`<div class="branch-item \${i === idx ? 'active' : ''}" onclick="go(\${i})">
          <span class="branch-num">\${String(i + 1).padStart(2, '0')}</span>
          <span class="branch-label">\${br.name.replace(/^goals-v2-\\d+-/, '')}</span>
          <span class="branch-stats">+\${br.insertions}/-\${br.deletions}</span>
        </div>\`
      ).join('');

      document.getElementById('branchName').textContent = b.name;
      document.getElementById('filesChanged').textContent = b.filesChanged;
      document.getElementById('insertions').textContent = '+' + b.insertions;
      document.getElementById('deletions').textContent = '-' + b.deletions;
      document.getElementById('parentName').textContent = b.parent;
      document.getElementById('commitMsg').textContent = b.message || '(no commit message)';
      document.getElementById('prevBtn').disabled = idx === 0;
      document.getElementById('nextBtn').disabled = idx === branches.length - 1;

      document.getElementById('files').innerHTML = b.files.map((f, i) =>
        \`<div class="file">
          <div class="file-header" onclick="toggle(\${i})">
            <span class="file-name">\${f.name}</span>
            <span class="file-stats">
              <span class="additions">+\${f.adds}</span>
              <span class="deletions">-\${f.dels}</span>
            </span>
          </div>
          <div class="diff \${expanded.has(i) ? 'expanded' : ''}" id="diff-\${i}">\${formatDiff(f.diff)}</div>
        </div>\`
      ).join('');
    }

    function formatDiff(diff) {
      if (!diff) return '<div class="diff-line diff-meta">(no diff)</div>';
      return diff.split('\\n').map(line => {
        const escaped = line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        if (line.startsWith('+') && !line.startsWith('+++'))
          return '<div class="diff-line diff-add">' + escaped + '</div>';
        if (line.startsWith('-') && !line.startsWith('---'))
          return '<div class="diff-line diff-del">' + escaped + '</div>';
        if (line.startsWith('@@'))
          return '<div class="diff-line diff-hunk">' + escaped + '</div>';
        if (line.startsWith('diff ') || line.startsWith('index ') || line.startsWith('---') || line.startsWith('+++'))
          return '<div class="diff-line diff-meta">' + escaped + '</div>';
        return '<div class="diff-line">' + escaped + '</div>';
      }).join('');
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
  const prefix = args[0]; // Optional prefix filter, e.g., "goals-v2"

  console.log("Gathering branch data...");
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

  const html = generateHtml(branchData);
  const outPath = join(tmpdir(), "stack-view.html");
  writeFileSync(outPath, html);

  console.log(`\nOpening ${outPath}`);
  execSync(`open "${outPath}"`);
}
