---
title: Five change domains, three events
section: Viewer
order: 17
project: viewer-derived-state
lede: The server already computes four independent fingerprints and then collapses two of them into one event, one line apart. Routing by domain is a six-line change that removes most of the twenty-key fan-out.
---

Mechanism: [[viewer-derived-state-mechanism]]. Baseline: [[viewer-derived-state-measurements]].

Every derived view depends on exactly one of these, and they move on wildly different clocks:

| domain | source | the keys that depend on it |
|---|---|---|
| **git** | refs, config, worktrees | model, projects, forest-branches, commits |
| **dirt** | per-worktree `git status` | the dirty overlay only |
| **remote** | origin tips, PR states, fetch health | sync, push-preview, prep-route, branch-prs, myprs, review-requests |
| **machine** | tmux, docker, chat jobs, restack files | previews, processes, chat-jobs, restack-* |
| **bundle** | `dist/` mtimes | a full reload |

`_pulse_refresh` already computes four of the five: `sig`, `world`, `procs`, `asset`. Then
`stack-review-server.py:384` and `:389` emit **the same `event: update`** for `sig` and
`world`, five lines apart. So a PR state flip invalidates `/model`, which depends on no remote
fact, and a commit on any of 1,564 branches invalidates `/sync`, which barely depends on
local ones. The partition exists in the server and is discarded on the wire.

**Routing by domain is the cheap first move** — one event name per domain, and each query key
subscribes to its own. That is most of the fan-out win without any per-slice delta machinery;
"which forest moved" becomes an optional later refinement, not a prerequisite.

**Two things it exposes.** `pulse_nonce` is folded into `_pulse["sig"]`, so a background model
rebuild wakes every tab's whole fan-out — and under churn the rebuild it triggers bumps the
nonce again. And **dirt has no change source at all** today, which is why it rides inside a
payload it makes uncacheable; as an overlay it can key on each worktree's `.git/index` mtime,
so a clean tree costs a stat instead of a subprocess.
