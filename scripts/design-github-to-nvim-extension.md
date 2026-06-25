# GitHub → nvim Chrome extension

**Goal:** from a GitHub PR page, one click on a file/line lands the cursor on that
exact line in the warm review-nvim (tmux `loops` session), full LSP. The viewer
is an optional hop, not a required one.

**v1 decisions (locked):**
- Destination: **straight to nvim, carrying file + line** (the cursor is the point).
- Port: **hardcode `http://localhost:62333`**. Discovery is a later concern.
- The viewer server stays the single backend; the extension is dumb glue.

## Why an extension (not a bookmarklet)

A page on `https://github.com` cannot `fetch('http://localhost:62333')` — browsers
block it as mixed content. An MV3 **background service worker** with
`host_permissions: ["http://localhost:62333/*"]` can, and **needs no server CORS
change**. That mixed-content wall is the whole reason this must be an extension.
Content script scrapes the DOM and posts a message; the worker does the localhost
fetch.

## Backend: one new endpoint

Everything downstream already exists and is verified:

- `POST /review-import {number}` → `{ok, branch}` — runs `stack-review-import`,
  fetches `pull/N/head` → local `review/pr-N` parented at `origin/<base>` (diff
  matches GitHub), seeds description, pins to watch list. **Idempotent.**
- `POST /open {branch, path, pos?}` → `{ok, out, err}` — runs
  `stack-open <branch> <path> <pos>`; `pos` is forwarded verbatim and stack-open
  owns the grammar: `"<line>"` or `"<line>:<col>"`. Opens in the warm review-nvim,
  8s timeout, kills wedged probes.

The only new code is a convenience endpoint that chains them so the extension makes
**one** call and the "already imported" path is free:

```
POST /from-github  { repo, number, path?, line? }
  → import_pr(number)              # idempotent; returns branch "review/pr-N"
  → if path: open_file(branch, path, line)   # line forwarded as pos
  → { ok, branch, opened: bool }
```

Add to `srv/reviews.py` (sits next to `import_pr`), wire one line into `do_POST`:
```python
if self.path == "/from-github":
    return reviews.from_github(self, raw)
```
`from_github` reuses `stack-review-import` + `stack-open` exactly as the existing
two handlers do — no new git logic. `repo` is carried for the future multi-repo
port-discovery story; v1 ignores it (single hardcoded viewer).

## Extension layout (MV3)

```
gh-to-nvim/
  manifest.json          # MV3; host_permissions github.com + localhost:62333
  content.js             # scrape PR DOM, inject buttons, postMessage to worker
  background.js          # relay → fetch('http://localhost:62333/from-github')
  content.css            # button styling that survives GitHub's CSS
```

**manifest.json** essentials:
```json
{
  "manifest_version": 3,
  "name": "GitHub → nvim",
  "host_permissions": ["http://localhost:62333/*"],
  "content_scripts": [{
    "matches": ["https://github.com/*/*/pull/*"],
    "js": ["content.js"], "css": ["content.css"]
  }],
  "background": { "service_worker": "background.js" }
}
```

## DOM scraping (confirmed against the live new-diff view)

From the URL: `https://github.com/{owner}/{repo}/pull/{number}/files`
→ `repo = "{owner}/{repo}"`, `number`.

**The PR diff is GitHub's new React view, and it is virtualized** (`role="grid"`,
`focusable-grid-cell`, `data-grid-cell-id`, managed `tabindex`) — rows mount and
unmount as you scroll. So per-row button injection is wrong; it would vanish on
scroll and need constant re-injection. **Use event delegation**: one listener on
the diff container, resolve the target with `closest()`. Robust to scroll, zero
re-injection.

Confirmed stable, semantic anchors (these survive GitHub redesigns; never use the
generated `*-module__*` class hashes):

- **File path** → on the table: `table[aria-label^="Diff for: "]`, value
  `"Diff for: components/admin/SettingsTab.tsx"`. Strip the `"Diff for: "` prefix.
  The table's `data-diff-anchor` is the same `diff-<sha>` that prefixes every line
  anchor below it.
- **Line number** → on each gutter cell:
  `td.new-diff-line-number[data-diff-side="right"][data-line-number]`, whose
  `data-line-anchor` ends in `R<line>`. The **right** side is the new-file line —
  exactly what we open on the PR branch. (Text cells `td.diff-text-cell` also
  carry `data-line-number`, so scope to the gutter cell or accept either.)
- **Rows** `tr.diff-line-row`; **hunk headers** `td.diff-hunk-cell`;
  **deletion-only** lines carry a left `…L<n>` anchor with an empty right cell
  (`td.empty-diff-line`) → no new-file line, so fall back to file top.

No path translation needed — GitHub paths are repo-relative, exactly what
stack-open wants.

The line-precision resolver (the whole magic, scroll-proof):
```js
diffContainer.addEventListener('click', (e) => {
  const cell = e.target.closest(
    'td.new-diff-line-number[data-diff-side="right"][data-line-number]');
  if (!cell) return;
  const table = cell.closest('table[aria-label^="Diff for: "]');
  const path = table.getAttribute('aria-label').replace(/^Diff for: /, '');
  const line = cell.getAttribute('data-line-number');
  send({ repo, number, path, line });   // → background → POST /from-github
});
```
Trigger: bare-click on a line number is GitHub's own select-line gesture, so the
open is gated on **⌥-click** (Alt) to avoid hijacking it. Add `if (!e.altKey)
return;` at the top of the handler; a small hover hint on the gutter advertises it.

- **Per file (Zone A) — confirmed:** mount point is
  `div[data-diff-header-wrapper="true"]` (one per file, semantic attribute). Path
  is `button[data-file-path]`'s attribute — clean, no parsing (the filename
  `<code>` is wrapped in invisible bidi marks `‎…‎`, so never read its
  textContent). Insert the **"⬚ nvim"** button (opens at line 1) right before
  `button[aria-label$="Viewed"]` in the trailing action cluster (Viewed →
  Comment → kebab). GitHub's own Copilot "Ask about this diff" button lives in
  this cluster, so a tooling action here is idiomatic.
  ```js
  for (const wrap of document.querySelectorAll('div[data-diff-header-wrapper="true"]')) {
    if (wrap.querySelector('.gh-nvim-btn')) continue;       // idempotent
    const path = wrap.querySelector('button[data-file-path]')?.getAttribute('data-file-path');
    const viewed = wrap.querySelector('button[aria-label$="Viewed"]');
    viewed?.before(makeNvimButton(path));
  }
  ```
- **PR header (Zone C):** a single **"→ nvim"** (first changed file / just
  import) and **"→ viewer"** (`window.open('http://localhost:62333/review/pr-N')`,
  already path-routes).

A `MutationObserver` still watches the diff container for the file-list mounting
and PJAX/Turbo navigations — but only to (re)attach the *container-level*
delegated listeners and the Zone A/C buttons, never per-row.

## Click flow

1. Content script reads `{repo, number, path, line}` from the clicked element +
   URL.
2. `chrome.runtime.sendMessage({repo, number, path, line})`.
3. Background worker → `POST http://localhost:62333/from-github`.
4. On `{ok}`, flash the button green; on error, red + tooltip with `err`
   (e.g. the 504 "review-nvim is unresponsive" message surfaces verbatim).
5. nvim is already focused by `stack-open`'s tmux/`open -a` path.

## Gotchas / open questions

- **Port discovery (deferred):** per-repo viewers can land on an ephemeral port,
  not always `:62333`. v1 hardcodes; the `repo` field in `/from-github` is the
  seam for a later `/whoami`-probe across a port range or a registry file.
- **Server is unauthenticated** — fine, localhost-bound + single user, and the
  extension origin is just another localhost client.
- **Renamed files:** `data-path` is the new path; opens on the branch tip where it
  exists. Fine.
- **Conversation tab inline comments:** v1 only handles the *Files changed* tab.
  Inline-on-Conversation is a later add.

## Build order — ALL LANDED (dotfiles main)

1. ✅ `from_github` handler + `do_POST` wire-up — `srv/reviews.py`,
   `srv/picker.py` (`open_on_branch` seam), `stack-review-server.py`.
2. ✅ Extension skeleton: manifest + background relay + floating `→ nvim` button.
3. ✅ Per-file `nvim` buttons (`button[data-file-path]` + MutationObserver).
4. ✅ ⌥-click line → file+line via capture-phase delegation + toast.
5. ✅ `→ viewer` floating button (`window.open` the imported branch node).

Extension lives in `scripts/gh-to-nvim/`. Remaining is verification (load
unpacked + restart viewer) and future polish: Conversation-tab inline comments,
port discovery beyond hardcoded :62333.
