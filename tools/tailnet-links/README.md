# Loops links: open on the tailnet, share as app.loops.so

Staff read Loops on the tailnet admin host (`admin.your-tailnet.ts.net`), which has the internal tools. Customers only know `app.loops.so`. Links move between the two by copy and paste, so the fix sits exactly there:

- **Opening a link** — a customer's `app.loops.so/...` link opens as the same page on the tailnet.
- **Copying a link** — a tailnet link you copy becomes `app.loops.so/...`, ready to send to anyone.

The app itself is untouched: no proxy, no rewriting inside pages. Once you're on a page, it's just the app.

## The two pieces

| | Chrome extension (`extension/`) | Clipboard watcher (`bin/tailnet-link-clip`, `tailnet-link-clip.swift`) |
|---|---|---|
| Acts when | a top-level `app.loops.so` page loads | the clipboard changes |
| Rule | `https://app.loops.so/<path>` → `https://admin.your-tailnet.ts.net/<path>` | a copy that is exactly one `https://admin.your-tailnet.ts.net/<path>` URL → `https://app.loops.so/<path>` |
| Leaves alone | `/api/...` (login callbacks and webhooks must reach the real app) | `/admin...` (only exists on the tailnet), URLs inside other text, password-manager copies |
| Escape | click the toolbar icon to turn it off (badge shows "off") | copy the same link again within 2s to keep the tailnet form |
| When broken | Loops links fail to load — turn it off | posts a note to Show's Inbox, once a day (Phil's setup; swap `show-note` for your own alert) |

Why two pieces: Chrome lets an extension redirect page loads, but not change what's copied from the address bar, so the copy side has to run outside Chrome.

### How each works

**Extension.** `rules.json` holds two `declarativeNetRequest` rules that Chrome runs itself — an `allow` for `/api/` at higher priority, and a regex `redirect` for everything else on `app.loops.so`, top-level pages only. `background.js` only toggles the ruleset from the toolbar icon. Host permission is limited to `https://app.loops.so/*`.

**Watcher.** A small Swift program kept alive by launchd. macOS has no "clipboard changed" event, so it reads the pasteboard's change counter every 100ms (with timer tolerance so macOS batches the wakeups; ~0.1% CPU). On a change, if the plain text — trimmed — is one tailnet URL outside `/admin`, it replaces that exact URL in the plain-text, HTML, RTF and URL representations (so a pasted link keeps its title) and copies every other representation back byte-for-byte. The wrapper script recompiles the binary when the source changes.

## Install

Requires Tailscale on the Loops tailnet and a staff login on the admin host.

1. **Extension**: `chrome://extensions` → Developer mode → Load unpacked → `extension/`. Open any `app.loops.so` link to check it lands on `admin.your-tailnet.ts.net`; log in there once.
2. **Watcher** (needs Xcode command line tools for `swiftc`):
   ```bash
   tools/tailnet-links/bin/tailnet-link-clip "https://admin.your-tailnet.ts.net/campaigns/x"   # builds, prints https://app.loops.so/campaigns/x
   ```
   Then copy `launchd/com.philbrockman.tailnet-link-clip.plist` into `~/Library/LaunchAgents/` — edit the label and the `/Users/philbrockman/...` paths to yours first; launchd doesn't expand `~` — and run:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<your-label>.plist
   ```
   Check: copy a tailnet campaign URL, paste it — it should read `app.loops.so`.

## Known limits

- It's a workaround, not a single URL. The clean fix is the admin deployment also answering at `app.loops.so` for tailnet users (its `BASE_URL`/`NEXTAUTH_URL`, Google sign-in callback, certificate and DNS) — an infra change.
- Only clipboard copies are caught: a screenshot of the address bar or a typed URL isn't.
- A paste within ~150ms of copying can still get the tailnet form.
- With the extension on, this browser profile can't use the real `app.loops.so` as a customer — turn it off or use another profile.
- Hostnames are hard-coded; staging (`admin-staging`) isn't covered.
