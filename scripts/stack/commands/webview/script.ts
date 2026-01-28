// Embedded JavaScript for the stack viewer HTML page.
// This is injected into a <script> tag - it runs in the browser, not Node.

export function getScript(): string {
  return `
    const branches = BRANCHES_JSON;
    const churns = CHURNS_JSON;
    let idx = 0;
    let expanded = new Set();

    // Build churn counts per branch
    const churnByBranch = {};
    for (const c of churns) {
      churnByBranch[c.addedIn] = (churnByBranch[c.addedIn] || 0) + c.lines.length;
    }

    function escHtml(s) {
      return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    // --- Review state (localStorage) ---

    function hashStr(s) {
      let h = 0;
      for (let i = 0; i < s.length; i++) {
        h = ((h << 5) - h + s.charCodeAt(i)) | 0;
      }
      return h.toString(36);
    }

    function reviewKey(branch, file) {
      return 'stack-review:' + branch + ':' + file;
    }

    function isReviewed(branch, file, diff) {
      const stored = localStorage.getItem(reviewKey(branch, file));
      return stored === hashStr(diff);
    }

    function wasReviewed(branch, file) {
      return localStorage.getItem(reviewKey(branch, file)) !== null;
    }

    function getStoredDiff(branch, file) {
      return localStorage.getItem(reviewKey(branch, file) + ':diff');
    }

    function setReviewed(branch, file, diff, reviewed) {
      const key = reviewKey(branch, file);
      if (reviewed) {
        localStorage.setItem(key, hashStr(diff));
        localStorage.setItem(key + ':diff', diff);
      } else {
        localStorage.removeItem(key);
        localStorage.removeItem(key + ':diff');
      }
    }

    // Auto-store baseline: on first load, record every file's diff so we can
    // detect future changes without requiring a manual check/uncheck cycle.
    function ensureBaselines() {
      for (const b of branches) {
        for (const f of b.files) {
          const key = reviewKey(b.name, f.name);
          if (localStorage.getItem(key) === null) {
            // No review state at all — store just the diff snapshot (not the
            // hash) so "wasReviewed" remains false but showDelta has data.
            localStorage.setItem(key + ':diff', f.diff);
          }
        }
      }
    }
    ensureBaselines();

    function computeDelta(oldDiff, newDiff) {
      const oldLines = new Set(oldDiff.split('\\n'));
      const newLines = newDiff.split('\\n');
      const added = newLines.filter(l => !oldLines.has(l) && (l.startsWith('+') || l.startsWith('-') || l.startsWith('@@')));
      return added;
    }

    function getReviewedCount() {
      const b = branches[idx];
      return b.files.filter(f => isReviewed(b.name, f.name, f.diff)).length;
    }

    function branchReviewStatus(br) {
      if (br.files.length === 0) return 'empty';
      const reviewed = br.files.filter(f => isReviewed(br.name, f.name, f.diff)).length;
      const changed = br.files.some(f => !isReviewed(br.name, f.name, f.diff) && wasReviewed(br.name, f.name));
      if (reviewed === br.files.length) return 'done';
      if (changed) return 'changed';
      if (reviewed > 0) return 'partial';
      return 'none';
    }

    // --- Diff parsing ---

    function parseDiff(diff) {
      if (!diff) return [];
      const lines = diff.split('\\n');
      const hunks = [];
      let currentHunk = null;

      for (const line of lines) {
        if (line.startsWith('@@')) {
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
            leftHtml = '<div class="diff-line"><span class="line-num">' + oldLineNum + '</span><span class="line-content">' + escHtml(oldLine.content) + '</span></div>';
            rightHtml = '<div class="diff-line"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
            oldIdx++; newIdx++; oldLineNum++; newLineNum++;
          } else if (oldLine && oldLine.type === 'del') {
            leftHtml = '<div class="diff-line line-del"><span class="line-num">' + oldLineNum + '</span><span class="line-content">' + escHtml(oldLine.content) + '</span></div>';
            oldIdx++; oldLineNum++;
            if (newLine && newLine.type === 'add') {
              rightHtml = '<div class="diff-line line-add"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
              newIdx++; newLineNum++;
            } else {
              rightHtml = '<div class="diff-line line-empty"><span class="line-num"></span><span class="line-content"></span></div>';
            }
          } else if (newLine && newLine.type === 'add') {
            leftHtml = '<div class="diff-line line-empty"><span class="line-num"></span><span class="line-content"></span></div>';
            rightHtml = '<div class="diff-line line-add"><span class="line-num">' + newLineNum + '</span><span class="line-content">' + escHtml(newLine.content) + '</span></div>';
            newIdx++; newLineNum++;
          } else {
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

    // --- Rendering ---

    function render() {
      const b = branches[idx];

      // Sidebar
      document.getElementById('branchList').innerHTML = branches.map((br, i) => {
        const cc = churnByBranch[br.name] || 0;
        const churnBadge = cc > 0 ? '<span class="churn-badge" title="' + cc + ' churned lines">~' + cc + '</span>' : '';
        const status = branchReviewStatus(br);
        const statusIcon = status === 'done' ? '<span class="branch-done" title="All files reviewed">✓</span>'
          : status === 'changed' ? '<span class="branch-changed" title="Files changed since review">!</span>'
          : status === 'partial' ? '<span class="branch-partial" title="Partially reviewed">·</span>'
          : '';
        return '<div class="branch-item ' + (i === idx ? 'active' : '') + ' branch-' + status + '" onclick="go(' + i + ')">'
          + '<span class="branch-num">' + String(i + 1).padStart(2, '0') + '</span>'
          + statusIcon
          + '<span class="branch-label">' + br.name.replace(/^goals-v2-\\d+-/, '') + '</span>'
          + churnBadge
          + '<span class="branch-stats">+' + br.insertions + '/-' + br.deletions + '</span>'
          + '</div>';
      }).join('');

      // Header
      document.getElementById('branchName').textContent = b.name;
      document.getElementById('filesChanged').textContent = b.filesChanged;
      document.getElementById('insertions').textContent = '+' + b.insertions;
      document.getElementById('deletions').textContent = '-' + b.deletions;
      document.getElementById('parentName').textContent = b.parent;
      document.getElementById('commitMsg').textContent = b.message || '(no commit message)';
      document.getElementById('prevBtn').disabled = idx === 0;
      document.getElementById('nextBtn').disabled = idx === branches.length - 1;

      // Review counter
      updateReviewCounter();

      // Files - expanded by default unless reviewed
      expanded.clear();
      b.files.forEach((f, i) => {
        if (!isReviewed(b.name, f.name, f.diff)) {
          expanded.add(i);
        }
      });

      document.getElementById('files').innerHTML = b.files.map((f, i) => {
        const hunks = parseDiff(f.diff);
        const reviewed = isReviewed(b.name, f.name, f.diff);
        const changed = !reviewed && wasReviewed(b.name, f.name);
        const isExpanded = expanded.has(i);
        const changedBadge = changed
          ? '<span class="changed-badge" title="Changed since last review">changed</span>'
          + '<button class="delta-btn" onclick="event.stopPropagation(); showDelta(' + i + ')" title="Show only what changed since last review">delta</button>'
          : '';
        return '<div class="file' + (reviewed ? ' reviewed' : '') + (changed ? ' changed-since-review' : '') + '">'
          + '<div class="file-header" onclick="toggle(' + i + ')">'
          + '<span class="file-header-left">'
          + '<input type="checkbox" class="review-check" ' + (reviewed ? 'checked' : '')
          + ' onclick="event.stopPropagation(); toggleReview(' + i + ', this.checked)" />'
          + '<span class="file-name">' + f.name + '</span>'
          + changedBadge
          + '</span>'
          + '<span class="file-stats">'
          + '<span class="additions">+' + f.adds + '</span>'
          + '<span class="deletions">-' + f.dels + '</span>'
          + '</span>'
          + '</div>'
          + '<div class="diff ' + (isExpanded ? 'expanded' : '') + '" id="diff-' + i + '">'
          + renderSideBySide(hunks)
          + '</div>'
          + '</div>';
      }).join('');

      renderChurnPanel();
    }

    function updateReviewCounter() {
      const b = branches[idx];
      const reviewed = getReviewedCount();
      const total = b.files.length;
      const el = document.getElementById('reviewCounter');
      if (el) {
        el.textContent = reviewed + '/' + total + ' reviewed';
        el.style.color = reviewed === total ? '#3fb950' : '#8b949e';
      }
    }

    function toggleReview(i, checked) {
      const b = branches[idx];
      const f = b.files[i];
      setReviewed(b.name, f.name, f.diff, checked);

      const fileEl = document.getElementById('diff-' + i).parentElement;
      if (checked) {
        fileEl.classList.add('reviewed');
        expanded.delete(i);
        document.getElementById('diff-' + i).classList.remove('expanded');
      } else {
        fileEl.classList.remove('reviewed');
        expanded.add(i);
        document.getElementById('diff-' + i).classList.add('expanded');
      }
      updateReviewCounter();
      updateSidebarStatus();
    }

    function updateSidebarStatus() {
      const items = document.querySelectorAll('.branch-item');
      items.forEach((el, i) => {
        const br = branches[i];
        const status = branchReviewStatus(br);
        el.className = el.className.replace(/branch-(done|changed|partial|none|empty)/g, '').trim();
        el.classList.add('branch-' + status);
        // Update the status icon
        const existing = el.querySelector('.branch-done, .branch-changed, .branch-partial');
        if (existing) existing.remove();
        const icon = status === 'done' ? '<span class="branch-done" title="All files reviewed">✓</span>'
          : status === 'changed' ? '<span class="branch-changed" title="Files changed since review">!</span>'
          : status === 'partial' ? '<span class="branch-partial" title="Partially reviewed">·</span>'
          : '';
        if (icon) {
          const num = el.querySelector('.branch-num');
          if (num) num.insertAdjacentHTML('afterend', icon);
        }
      });
    }

    function showDelta(i) {
      const b = branches[idx];
      const f = b.files[i];
      const oldDiff = getStoredDiff(b.name, f.name);
      if (!oldDiff) return;
      const oldHunkLines = new Set(oldDiff.split('\\n'));
      const newDiffLines = f.diff.split('\\n');

      // Build a filtered diff: keep headers and lines not in old diff
      const deltaLines = [];
      let inHunk = false;
      let hunkHeader = '';
      let hunkHasNew = false;
      let hunkBuffer = [];

      for (const line of newDiffLines) {
        if (line.startsWith('@@')) {
          if (hunkHasNew && hunkBuffer.length > 0) {
            deltaLines.push(hunkHeader);
            deltaLines.push(...hunkBuffer);
          }
          hunkHeader = line;
          hunkBuffer = [];
          hunkHasNew = false;
          inHunk = true;
        } else if (inHunk) {
          if (!oldHunkLines.has(line)) {
            hunkHasNew = true;
            hunkBuffer.push(line);
          } else if (line.startsWith(' ') || (!line.startsWith('+') && !line.startsWith('-'))) {
            hunkBuffer.push(line);
          } else {
            hunkBuffer.push(line);
          }
        }
      }
      if (hunkHasNew && hunkBuffer.length > 0) {
        deltaLines.push(hunkHeader);
        deltaLines.push(...hunkBuffer);
      }

      const deltaDiff = deltaLines.join('\\n');
      const deltaHunks = parseDiff(deltaDiff);
      const diffEl = document.getElementById('diff-' + i);

      if (deltaHunks.length === 0) {
        diffEl.innerHTML = '<div class="hunk-header" style="color:#3fb950;padding:12px">No meaningful changes since last review — safe to re-check</div>';
      } else {
        diffEl.innerHTML = '<div class="hunk-header" style="color:#d29922;padding:8px">Showing only changes since last review</div>' + renderSideBySide(deltaHunks);
      }
      expanded.add(i);
      diffEl.classList.add('expanded');
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

    // --- Churn panel ---

    function renderChurnPanel() {
      const btn = document.getElementById('churnBtn');
      const panel = document.getElementById('churnPanel');

      const branchName = branches[idx].name;
      const relevant = churns.filter(c => c.addedIn === branchName || c.removedIn === branchName);

      if (relevant.length === 0 && churns.length === 0) {
        btn.style.display = 'none';
        panel.classList.remove('visible');
        return;
      }

      btn.style.display = '';
      btn.textContent = 'Churn (' + churns.length + ' hunks)';

      const items = (relevant.length > 0 ? relevant : churns).map(c => {
        const fromShort = c.addedIn.replace(/^goals-v2-\\d+-/, '');
        const toShort = c.removedIn.replace(/^goals-v2-\\d+-/, '');
        const preview = c.lines.slice(0, 3).map(l => escHtml(l.length > 80 ? l.slice(0, 77) + '...' : l)).join('\\n');
        const more = c.lines.length > 3 ? '\\n... +' + (c.lines.length - 3) + ' more' : '';
        return '<div class="churn-item">'
          + '<div class="churn-file">' + c.file + '</div>'
          + '<div class="churn-flow">'
          + '<span class="from">+ ' + fromShort + '</span>'
          + '<span class="arrow">→</span>'
          + '<span class="to">- ' + toShort + '</span>'
          + '<span>(' + c.lines.length + ' lines)</span>'
          + '</div>'
          + '<div class="churn-lines">' + preview + more + '</div>'
          + '</div>';
      }).join('');

      panel.innerHTML = '<div class="churn-panel-header">'
        + '<span>' + (relevant.length > 0 ? 'Churn for ' + branchName.replace(/^goals-v2-\\d+-/, '') : 'All churn')
        + ' (' + (relevant.length || churns.length) + ' hunks)</span>'
        + '<button class="nav-btn" onclick="toggleChurn()" style="padding:2px 8px;font-size:11px">×</button>'
        + '</div>' + items;
    }

    function toggleChurn() {
      document.getElementById('churnPanel').classList.toggle('visible');
    }

    document.addEventListener('keydown', e => {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') nav(-1);
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') nav(1);
      if (e.key === 'e') expandAll();
      if (e.key === 'c') collapseAll();
    });

    render();
  `;
}
