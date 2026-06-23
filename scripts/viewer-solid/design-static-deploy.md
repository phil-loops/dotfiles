# Static deploy — publication (design note, NOT built)

The static snapshot itself is built (`npm run build:static` → `dist/` + `dist/data/*.json`;
see `provider.ts` / `bake.mjs`). What's deferred is **publishing** it somewhere on a
schedule. Notes for when we pick that up.

## The load-bearing constraint: bake is local-only

`bake.mjs` snapshots the **live viewer server**, which only exists on the dev Mac — it
reads local worktrees, dirty working-tree state, the blessing ledger, and `gh` auth.
GitHub Actions / any CI has none of that, so **the bake cannot run in CI**. This is a
**local cron that builds + pushes**, not a CI-driven deploy. Everything below follows
from that.

## Shape: a `viewer-deploy` script

1. Ensure the viewer server is up (or have bake spin a throwaway one).
2. `npm run build:static`.
3. Push `dist/` to the host.

## Scheduling it (later)

- macOS-native = **launchd** (a `.plist` with `StartCalendarInterval`), not classic
  crontab — survives sleep/wake better. It just runs `viewer-deploy` on a schedule.
- **Cadence: don't run it tight.** The bake walks every project→branch (~130+ requests
  for the current forest) and the output is a deliberate slice-in-time. Prefer
  **on-demand** (run it / hit a button when you want to share) over a blind cron; if
  scheduled, hourly or work-hours-only is plenty. Event-driven (after a bless/restack)
  is an option too.

## Host: this is a privacy decision, not a mechanics one

The viewer exposes **private-repo diffs, file contents, branch names, PR data**. So the
host MUST be access-controlled — a public site would leak Loops' private source.
- **Private GitHub Pages** — mechanically easy (push `dist/` to a `gh-pages` branch via a
  git worktree), but needs a paid plan; access is GitHub-org-gated.
- **Netlify / Vercel with password or SSO** — easy, good auth.
- **Tailscale-internal static serve** — zero public exposure, just your own devices.
  Likely the best fit if this is for your own review / sharing-with-self.

## Recommendation

Skip the cron at first. Start with a **manual `viewer-deploy` script** targeting a
private / Tailscale host; get the privacy + auth story right; *then* wrap it in a launchd
timer once the output is trusted. Don't reach for GH Pages reflexively — the public-leak
risk makes it the wrong default here.
