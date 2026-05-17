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
      // Hash only content lines, not @@ headers (which change when line
      // numbers shift even though the actual diff content is identical).
      const content = s.split('\\n').filter(l => !l.startsWith('@@')).join('\\n');
      let h = 0;
      for (let i = 0; i < content.length; i++) {
        h = ((h << 5) - h + content.charCodeAt(i)) | 0;
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

    function safeSetItem(key, value) {
      try {
        localStorage.setItem(key, value);
        return true;
      } catch (e) {
        console.warn('stack-view: localStorage write failed (quota?)', key, e.message);
        return false;
      }
    }

    function setReviewed(branch, file, diff, reviewed) {
      const key = reviewKey(branch, file);
      if (reviewed) {
        safeSetItem(key, hashStr(diff));
        // :diff baseline powers showDelta; best-effort, OK if quota refuses.
        safeSetItem(key + ':diff', diff);
      } else {
        localStorage.removeItem(key);
        localStorage.removeItem(key + ':diff');
      }
    }

    // One-time nuke: clear stale review state. v3 cleared the original hash
    // format; v4 evicts the auto-baseline :diff entries that the removed
    // ensureBaselines() used to pour in (these were bloating quota across
    // multi-project sessions and crashing page-load).
    (function nukeStaleState() {
      if (localStorage.getItem('stack-review:v4-reset')) return;
      const toRemove = [];
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith('stack-review:')) toRemove.push(k);
      }
      toRemove.forEach(k => localStorage.removeItem(k));
      localStorage.setItem('stack-review:v4-reset', '1');
    })();

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
          + '<button class="copy-ref-btn" onclick="event.stopPropagation(); copyRef(' + i + ')" title="Copy filepath@branch">⧉</button>'
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
      const diffEl = document.getElementById('diff-' + i);
      if (!oldDiff) {
        diffEl.innerHTML = '<div class="hunk-header" style="color:#d29922;padding:12px">No blessed version stored — check the box to bless the current state</div>';
        expanded.add(i);
        diffEl.classList.add('expanded');
        return;
      }
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

      if (deltaHunks.length === 0) {
        diffEl.innerHTML = '<div class="hunk-header" style="color:#3fb950;padding:12px">No meaningful changes since last review — safe to re-check</div>';
      } else {
        diffEl.innerHTML = '<div class="hunk-header" style="color:#d29922;padding:8px">Showing only changes since last review</div>' + renderSideBySide(deltaHunks);
      }
      expanded.add(i);
      diffEl.classList.add('expanded');
    }

    function copyRef(i) {
      const b = branches[idx];
      const f = b.files[i];
      const ref = f.name + '@' + b.name;
      navigator.clipboard.writeText(ref);
      const btn = document.querySelectorAll('.copy-ref-btn')[i];
      if (btn) { btn.textContent = '✓'; setTimeout(() => btn.textContent = '⧉', 1000); }
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
    function go(i) { idx = i; expanded.clear(); setMode('BRANCH'); render(); }
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

    // --- State machine: BRANCH mode vs FILES mode ---
    let mode = 'BRANCH'; // 'BRANCH' | 'FILES'
    let focusedFile = -1;

    function setMode(m) {
      mode = m;
      updateModeIndicator();
      if (m === 'BRANCH') clearFileFocus();
    }

    function updateModeIndicator() {
      let el = document.getElementById('modeIndicator');
      if (!el) return;
      el.textContent = mode === 'BRANCH' ? 'BRANCH' : 'FILES';
      el.style.color = mode === 'BRANCH' ? '#58a6ff' : '#3fb950';
    }

    function setFileFocus(i) {
      const b = branches[idx];
      if (!b.files.length) return;
      const prev = document.querySelector('.file.focused');
      if (prev) prev.classList.remove('focused');
      focusedFile = Math.max(0, Math.min(i, b.files.length - 1));
      const fileEls = document.querySelectorAll('#files > .file');
      const el = fileEls[focusedFile];
      if (el) {
        el.classList.add('focused');
        el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
    }

    function clearFileFocus() {
      const prev = document.querySelector('.file.focused');
      if (prev) prev.classList.remove('focused');
      focusedFile = -1;
    }

    function showHelp() {
      let overlay = document.getElementById('helpOverlay');
      if (overlay) { overlay.remove(); return; }
      overlay = document.createElement('div');
      overlay.id = 'helpOverlay';
      overlay.innerHTML = ''
        + '<div class="help-content">'
        + '<div class="help-title">Keyboard Shortcuts</div>'
        + '<div class="help-section">BRANCH mode <span style="color:#58a6ff">(default)</span></div>'
        + '<div class="help-row"><kbd>j</kbd> <kbd>↓</kbd> next branch</div>'
        + '<div class="help-row"><kbd>k</kbd> <kbd>↑</kbd> prev branch</div>'
        + '<div class="help-row"><kbd>l</kbd> <kbd>Enter</kbd> enter FILES mode</div>'
        + '<div class="help-section">FILES mode <span style="color:#3fb950">(per-file nav)</span></div>'
        + '<div class="help-row"><kbd>j</kbd> <kbd>↓</kbd> next file</div>'
        + '<div class="help-row"><kbd>k</kbd> <kbd>↑</kbd> prev file</div>'
        + '<div class="help-row"><kbd>x</kbd> <kbd>Space</kbd> toggle reviewed</div>'
        + '<div class="help-row"><kbd>o</kbd> <kbd>Enter</kbd> toggle expand</div>'
        + '<div class="help-row"><kbd>d</kbd> show delta</div>'
        + '<div class="help-row"><kbd>y</kbd> copy filepath@branch</div>'
        + '<div class="help-row"><kbd>h</kbd> <kbd>Esc</kbd> back to BRANCH mode</div>'
        + '<div class="help-section">Global</div>'
        + '<div class="help-row"><kbd>e</kbd> expand all</div>'
        + '<div class="help-row"><kbd>c</kbd> collapse all</div>'
        + '<div class="help-row"><kbd>?</kbd> toggle this help</div>'
        + '<div class="help-dismiss">Press any key to dismiss</div>'
        + '</div>';
      document.body.appendChild(overlay);
    }

    document.addEventListener('keydown', e => {
      // Dismiss help overlay on any key
      const helpEl = document.getElementById('helpOverlay');
      if (helpEl && e.key !== '?') { helpEl.remove(); return; }

      // Toggle help
      if (e.key === '?') { showHelp(); return; }

      if (mode === 'BRANCH') {
        if (e.key === 'j' || e.key === 'ArrowDown') { e.preventDefault(); nav(1); return; }
        if (e.key === 'k' || e.key === 'ArrowUp') { e.preventDefault(); nav(-1); return; }
        if (e.key === 'l' || e.key === 'ArrowRight' || e.key === 'Enter') {
          e.preventDefault();
          if (branches[idx].files.length > 0) {
            setMode('FILES');
            setFileFocus(0);
          }
          return;
        }
        if (e.key === 'h' || e.key === 'ArrowLeft') return; // no-op at top level
      }

      if (mode === 'FILES') {
        if (e.key === 'j' || e.key === 'ArrowDown') {
          e.preventDefault();
          setFileFocus(focusedFile + 1);
          return;
        }
        if (e.key === 'k' || e.key === 'ArrowUp') {
          e.preventDefault();
          setFileFocus(focusedFile - 1);
          return;
        }
        if (e.key === 'Escape' || e.key === 'h' || e.key === 'ArrowLeft') {
          e.preventDefault();
          setMode('BRANCH');
          return;
        }
        if ((e.key === ' ' || e.key === 'x') && focusedFile >= 0) {
          e.preventDefault();
          const b = branches[idx];
          const f = b.files[focusedFile];
          const reviewed = isReviewed(b.name, f.name, f.diff);
          toggleReview(focusedFile, !reviewed);
          const checkbox = document.querySelectorAll('.review-check')[focusedFile];
          if (checkbox) checkbox.checked = !reviewed;
          return;
        }
        if ((e.key === 'Enter' || e.key === 'o') && focusedFile >= 0) {
          e.preventDefault();
          toggle(focusedFile);
          return;
        }
        if (e.key === 'd' && focusedFile >= 0) {
          showDelta(focusedFile);
          return;
        }
        if (e.key === 'y' && focusedFile >= 0) {
          copyRef(focusedFile);
          return;
        }
      }

      // Global
      if (e.key === 'e') expandAll();
      if (e.key === 'c') collapseAll();
    });

    render();
    updateModeIndicator();
  `;
}
