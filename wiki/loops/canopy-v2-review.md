---
title: Review, the GitHub way, faster
section: Canopy v2
order: 58
project: canopy-v2
lede: The branch page is GitHub's pull-request review, rebuilt local — same nouns, same moves, so nothing new to learn — plus what GitHub can't do: types, your unpushed commits, and a second reader.
---

**GitHub's model, kept whole.** Files changed with inline threads; a file tree with *viewed* checkboxes; a conversation view for the PR. On any line (or an `x`-range): *start a review* / *add review comment*. On a thread: reply, *show outdated*. Suggestion blocks with **apply suggestion**. Same for your PRs and teammates' (`review/pr-N`). Keys follow GitHub's where it has them.

**You submit on GitHub.** What you write goes into your **pending review** on GitHub — private to you until you press Submit there. The viewer never submits, approves, requests changes, resolves, or posts a standalone comment: **S** opens the PR's files on GitHub with the pending count, and **R** opens a thread there to resolve it. It can send exactly three things — create your pending review, add a thread to it, add a reply to it — and a structure test holds it to those. Sending to the real GitHub stays off until `git config stack.viewer-github-pending true`; until then everything is kept as a draft.

**What local adds:**

- **Threads follow your commits.** GitHub anchors a thread to the pushed head; the viewer maps it onto your local tip, and a thread whose line your new commit changed says *addressed by `<sha>`?*
- **Apply suggestion makes a local commit**, not a push — no bot re-run until you push.
- **A ledger keeps every word.** Each comment and reply is a ledger item with an idempotency key, durable across reloads: *draft* (only here; ⌘⇧↵ saves one, `P` sends them) → *pending* (in your pending review; ⌘↵ goes straight there) → *submitted*. Pending and submitted are read off GitHub, never assumed; a failed send stays a draft, with its error, until you retry.
- **Replies ride the push.** "Addressed in `<sha>`" only means something once the sha is on GitHub, so a reply that names an unpushed commit stays a draft until the push puts it on origin, then joins your pending review.
- **Types** (`K`, `gd`) on both halves, as everywhere.

**The second reader.** On each new review it reads every thread against the code, the packet and the forest, and leaves a note under it: is the comment right (with `file:line`), the same issue elsewhere in this branch or the forest, the cause behind a symptom, and a draft reply. It also says what nobody flagged. It never posts; its draft reply becomes yours only when you insert it (`i`).

**Data.** Threads, the PR's conversation and the ledger are the `review` domain of `/state` (full chains, ids, diff side, original line, each thread's line followed to your tip), refreshed with PR state; writes are optimistic commands that reconcile against GitHub. Code: `srv/ghreview.py` (the only GitHub writer), `srv/reviewdesk.py` (ledger, domain, apply), `srv/linemap.py`; the client in `viewer-solid/src/v2/review/`. Tested against a fake GitHub (`viewer-sandbox <dir> --github`, `npm run review-walkthrough`).
