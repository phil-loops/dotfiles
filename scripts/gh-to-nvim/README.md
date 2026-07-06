# GitHub → nvim (Chrome extension)

Opens the current GitHub page (PR, blob, or commit) in the local forest viewer's
warm nvim, or the PR's node in the viewer itself.

**URL-only by design.** There is no content script and no github.com host access:
the extension can never read or mutate a GitHub page. A user gesture (keyboard
shortcut or the popup button) grants `activeTab` just long enough to read the tab's
URL string, which is POSTed verbatim to the viewer's `POST /open-url`. The server
owns all parsing — PR vs blob vs commit, and resolving GitHub's
`#diff-<sha256(path)>R<n>` selected-line hash against the branch's changed files.

## Use it

- **⌘⇧O — open in nvim.** On a PR: the selected line if one is in the URL (click a
  line number first — GitHub writes it into the hash), else the whole-PR `gm`
  Diffview. On a blob view: that file at `#L<n>` in the working checkout. On a
  commit page: the selected line's file (commit must exist locally).
- **⌘⇧U — open in the forest viewer** (imports the PR if needed, opens its node).
- **Toolbar popup → "→ nvim this page"** — same as ⌘⇧O, for the shortcut-averse.
- **Toolbar popup on a PR** also shows the **forest chip**: which forest the PR's
  branch belongs to, its review decision, and children (orphans flagged) — click
  it to open the node in the viewer. Opening the popup is the activeTab gesture,
  so this needs no page access either.

Rebind either chord at `chrome://extensions/shortcuts` (bare single keys aren't
possible — Chrome commands require a modifier chord; that's the price of not
having a page-level key listener).

Feedback is the toolbar badge (… working, ⏻ launching, ◷ waiting, ↻ warming,
✓/⚠/✗ result) plus a notification on failures and cursor-placement warnings.

## Load it

1. Make sure the viewer serves the endpoint (restart it so `/open-url` is live),
   then smoke-test:
   ```
   curl -s localhost:62497/open-url -d '{"url":"https://example.com/nope"}'
   # → {"ok": false, "err": "unsupported GitHub URL …"}   (400)
   ```
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
   pick this `gh-to-nvim/` directory.
3. Open any PR on github.com, click a line number, hit **⌘⇧O**.

## Dev loop (toolbar icon)

The toolbar icon is the dev console — no `chrome://extensions` trip:

- **green** → loaded copy matches disk.
- **amber ●** → you edited a source file; the loaded copy is stale (it self-reloads
  once the source goes quiet for 5s).
- **grey ×** → the viewer isn't reachable on `:62497` (its `/ext-mtime` is the
  staleness signal; a service worker can't read disk itself).

Staleness is computed against the viewer's `/ext-mtime`; the baseline lives in
`storage.session`, which Chrome wipes on a real reload — so a fresh reload
re-baselines to "green" automatically.

## Launch the viewer from the popup (native messaging)

When the viewer is **offline (grey ×)** the popup shows a **▶ Launch viewer**
button. An extension can't run a shell command, so a registered native-messaging
host (`../gh-to-nvim-host`) does it: Chrome spawns it on demand, it runs
`stack-review-serve` in `~/coding/loops`, and the popup polls until the viewer is
reachable. Nothing stays resident — the host exits as soon as the server is
detached. The nvim/viewer commands run the same launch automatically when the
viewer is down, so the button is mostly a manual fallback.

One-time install (registers the host + whitelists the extension's pinned ID):

```
~/.dotfiles/scripts/gh-to-nvim-install   # writes the NativeMessagingHosts manifest
```

The ID is pinned by the `"key"` in `manifest.json` (derived from `.ext-key.pem`,
git-ignored), so it survives reloads and matches what the host whitelists. Reload
the extension after the first install so Chrome picks up the `key` + permissions.

## Notes

- `host_permissions` is `http://localhost/*` (any port) so the per-repo viewer
  port can move without re-permissioning; the viewer URL itself is pinned to
  `:62497` (see `config.js`). Nothing leaves the machine.
- Lost with the content script, deliberately: page-load pre-warm (first open of a
  PR eats the cold ~3s; the ↻ warming retry covers it), the bare `o` key, ⌥-click,
  the floating pills/per-file buttons, and in-page toasts. The forest chip
  survived by moving into the popup.
