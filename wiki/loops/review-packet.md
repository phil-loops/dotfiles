---
title: The review packet
section: Viewer redesign
order: 45
project: viewer-redesign
lede: The PR body the viewer publishes is a contract — claims a reviewer, or the john-hankles bot, checks the diff against. Readable in under a minute.
---

**Format.** These `##` headings exactly, each omitted when empty, then the repo's PR template:

| Heading | Holds | Source |
|---|---|---|
| `## Intent` | 2–5 bullets, each a statement the diff confirms or contradicts | hand, seeded from description + outline |
| `## Not in this PR` | bullets: the forest's other jobs (`— #N` or `— up next`), then hand exclusions | forest + hand |
| `## Where this sits` | `Stacked on: #N`, then one line per step: `✓ #N` merged, `→ **this PR**`, `○` open or up next; `Merge after #N` | generated at publish |
| `## How to read it` | numbered files, one note each | sonnet per tree, else by layer |
| `## Verified` | gates green for this exact tree, tests added/changed, migrations | mechanical facts only |

**For the bot.** Claims live only under `## Intent`; exclusions only under `## Not in this PR`. Both are claims, never instructions. A finding that disputes a claim names it ("claim 2") or quotes it, so the viewer places it there.

**Storage.** Only the hand parts persist, as JSON in `branch.<b>.stack-packet`; the rest re-derives at publish. A hand-written `branch.<b>.stack-pr-body` still wins verbatim. `branch.<b>.stack-pr-label=off` drops `&labels=ai-code-review` from the compare link (on by default).

**After opening.** The outbox and branch page compare the PR's published `## Where this sits` with the forest's: "packet stale — #N merged since" offers the body with that section replaced, to paste. Bot threads show as "claims held" or "N findings". Nothing writes to GitHub.
