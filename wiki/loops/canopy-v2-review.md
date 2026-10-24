---
title: Review, the GitHub way, faster
section: Canopy v2
order: 58
project: canopy-v2
lede: The branch page is GitHub's pull-request review, rebuilt local — same nouns, same moves, so nothing new to learn — plus what GitHub can't do: types, your unpushed commits, and a second reader.
---

**GitHub's model, kept whole.** Files changed with inline threads; a file tree with *viewed* checkboxes; a conversation view for the PR. On any line: *add single comment* or *start a review* (pending comments, submitted at once as **Comment / Approve / Request changes**). On a thread: reply, **resolve conversation**, *show outdated*. Suggestion blocks with **apply suggestion**. Same for your PRs and teammates' (`review/pr-N`). Keys follow GitHub's where it has them.

**What local adds:**

- **Threads follow your commits.** GitHub anchors a thread to the pushed head; the viewer maps it onto your local tip, and a thread whose line your new commit changed says *addressed by `<sha>`?*
- **Apply suggestion makes a local commit**, not a push — no bot re-run until you push.
- **Replies ride the push.** "Addressed in `<sha>`" only means something once the sha is on GitHub, so a reply that names an unpushed commit waits for the push. Everything else posts on your keypress, like GitHub.
- **Types** (`K`, `gd`) on both halves, as everywhere.

**The second reader.** On each new review it reads every thread against the code, the packet and the forest, and leaves a note under it: is the comment right (with `file:line`), the same issue elsewhere in this branch or the forest, the cause behind a symptom, and a draft reply. It also says what nobody flagged. It never posts.

**Data.** Threads are a `/state` domain (full chains, ids, diff side, original line), refreshed with PR state; writes are optimistic commands that reconcile against GitHub.
