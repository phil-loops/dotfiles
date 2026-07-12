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

## Install it (self-healing force-install)

An unpacked extension lives only in the profile's HMAC-signed Secure Preferences;
a hard shutdown mid-write corrupts the entry and Chrome silently discards it —
"the extension uninstalled itself after restart." So the daily-driver copy is
**policy force-installed from a local CRX** instead: Chrome reconciles policy on
every launch and reinstalls from the local server if the record ever rots.

```
~/.dotfiles/scripts/gh-to-nvim-forceinstall
```

sets up all of it (idempotent): a launchd static server on `127.0.0.1:62530`
serving this dir, the `ExtensionInstallForcelist` policy pointing at
`dist/updates.xml`, and the native-messaging allowlist for both ids. Relaunch
Chrome afterwards; the extension appears on its own. Costs the "Managed by your
organization" badge in Chrome's menu.

Two ids, both derived, both whitelisted for the native host:

- **prod** — from `../gh-to-nvim-key.pem` (git-ignored — this repo is PUBLIC and
  the native host trusts the id the key signs, so it never goes in git; losing
  it just means a rerun of `gh-to-nvim-forceinstall`, which rotates the id
  everywhere): `gh-to-nvim-ext-id prod`
- **dev** — what "Load unpacked" assigns this directory (path-derived; the
  manifest deliberately carries no `"key"`): `gh-to-nvim-ext-id dev`

## Dev loop (toolbar icon)

The toolbar icon is the dev console — no `chrome://extensions` trip:

- **green** → loaded copy matches disk.
- **amber ●** → you edited a source file; the loaded copy is stale.
- **grey ×** → the viewer isn't reachable on `:62497` (its `/ext-mtime` is the
  staleness signal; a service worker can't read disk itself).

What stale does next depends on which copy is running (`installType`):

- **unpacked dev copy** → self-reloads once the source goes quiet for 5s —
  `runtime.reload()` re-reads from disk, so this is the live-edit loop.
- **force-installed copy** → reloading would rerun the same installed bytes and
  lie "fresh", so it asks the updater instead (at most once a minute). Run
  `gh-to-nvim-pack` to publish your edits — it bumps the patch version, signs a
  new CRX into `dist/`, and the installed copy hot-swaps on its next ask. Until
  you pack, the amber ● is truthfully saying "installed ≠ disk".

For heavy hacking sessions, load the unpacked copy (`chrome://extensions` →
Load unpacked → this dir), toggle the forced copy off while you work (two copies
means duplicate toolbar icons and one of them loses the keyboard chords), and
`gh-to-nvim-pack` when done.

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

`gh-to-nvim-forceinstall` runs the host registration; to re-run just that part
(e.g. after moving the checkout, which changes the dev id):

```
~/.dotfiles/scripts/gh-to-nvim-install   # writes the NativeMessagingHosts manifest
```

## Notes

- `host_permissions` is `http://localhost/*` (any port) so the per-repo viewer
  port can move without re-permissioning; the viewer URL itself is pinned to
  `:62497` (see `config.js`). Nothing leaves the machine.
- Lost with the content script, deliberately: page-load pre-warm (first open of a
  PR eats the cold ~3s; the ↻ warming retry covers it), the bare `o` key, ⌥-click,
  the floating pills/per-file buttons, and in-page toasts. The forest chip
  survived by moving into the popup.
