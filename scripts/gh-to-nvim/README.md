# GitHub → nvim (Chrome extension)

Routes a GitHub PR into the local forest viewer's warm nvim. Backend is the
viewer's `POST /from-github` (import the PR → optionally open a file at a line).
See `../design-github-to-nvim-extension.md` for the full design.

## Status — feature-complete (steps 1–5)

- **Floating buttons (bottom-right):** `→ nvim` imports the current PR;
  `→ viewer` imports it and opens the node in the forest viewer (new tab).
- **Per-file `nvim` button** in each diff file header — opens that file at line 1.
- **⌥-click a diff line number** (right/new side) → opens that exact file+line in
  the warm nvim. A blue outline appears on hover while ⌥ is held to advertise it.
- A toast (bottom-right) reports the file:line result of a line-click.

All paths hit the viewer's `POST /from-github`.

## Load it

1. Make sure the viewer is serving the new endpoint (restart it so `/from-github`
   is live), then smoke-test:
   ```
   curl -s localhost:62497/from-github -d '{"number":"__nope__"}'
   # → {"ok": false, "err": "no pr number"}   (400)
   ```
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
   pick this `gh-to-nvim/` directory.
3. Open any PR on github.com and try:
   - the `→ nvim` / `→ viewer` pills (bottom-right),
   - the `nvim` button in any file's header (opens at line 1),
   - **⌥-click** a line number on the new/right side (opens that file+line).
## Dev loop (toolbar icon)

The toolbar icon is the dev console — no `chrome://extensions` trip:

- **green** → loaded copy matches disk.
- **amber ●** → you edited a source file; the loaded copy is stale.
- **grey ×** → the viewer isn't reachable on `:62497` (its `/ext-mtime` is the
  staleness signal; a service worker can't read disk itself).

**Click the icon to open the menu** (`popup.html`): current status + a **Reload
extension** button + a link to the forest viewer. Reload from there, then refresh
the GitHub tab to re-inject `content.js`. Staleness is computed against the
viewer's `/ext-mtime`; the baseline lives in `storage.session`, which Chrome
wipes on a real reload — so a fresh reload re-baselines to "green" automatically.

## Launch the viewer from the popup (native messaging)

When the viewer is **offline (grey ×)** the popup shows a **▶ Launch viewer**
button. An extension can't run a shell command, so a registered native-messaging
host (`../gh-to-nvim-host`) does it: Chrome spawns it on demand, it runs
`stack-review-serve` in `~/coding/loops`, and the popup polls until the viewer is
reachable. Nothing stays resident — the host exits as soon as the server is detached.

One-time install (registers the host + whitelists the extension's pinned ID):

```
~/.dotfiles/scripts/gh-to-nvim-install   # writes the NativeMessagingHosts manifest
```

The ID is pinned by the `"key"` in `manifest.json` (derived from `.ext-key.pem`,
git-ignored), so it survives reloads and matches what the host whitelists. Reload
the extension after the first install so Chrome picks up the `key` + `nativeMessaging`.

## Notes

- The floating pills are fixed-position on purpose — robust to GitHub's
  virtualized React diff DOM. Per-file/line affordances live inside the diff and
  are (re)attached via a `MutationObserver` as rows mount on scroll.
- ⌥-click is the line trigger so we don't hijack GitHub's own click-to-select-line.
- `host_permissions` is `http://localhost/*` (any port) so the per-repo viewer
  port can move without re-permissioning; the viewer URL itself is pinned to
  `:62497` (the loops repo's hash). Nothing leaves the machine.
