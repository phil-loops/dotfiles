---
title: Address a thread with a commit
section: Canopy v2
order: 62
project: canopy-v2
lede: A review thread asks for a change; the commit that makes it is linked to the thread, shown on both, and the reply naming it is drafted to go out with the push. Spec, not built.
---

**Today.** `a` only applies a GitHub suggestion block. For a plain question, say nalanj on #11132 at `queries/sending-domain.test.ts:599`, asking "should this test ensure the sending domain is enabled after the function is called?", the path is: `o` into Helix, commit there, come back, `r`, and type the sha by hand. Nothing ties the commit to the thread.

**The move.** On a thread, **address**:
1. **Opens the spot to edit.** The thread's line goes into Helix, as `o` does today.
2. **The thread starts waiting for its fix.** It shows "addressing — the next commit on this branch is its fix".
3. **The next commit adopts it.** When the branch tip moves past where it was, the first new commit that touches the thread's file becomes the fix. If none touches the file, the first new commit does. Pressing the key again on an addressing thread instead picks from the branch's unpushed commits.
4. **The link shows on both ends.** On the thread: "fixed by `abc1234` — add the enabled check". In the words (`e`), on the commit: "addresses nalanj on sending-domain.test.ts:599".
5. **The reply is drafted.** A short reply in the ledger, in your voice ("added in abc1234"), editable like any draft. It already waits for the sha to be on GitHub, so it goes out with the push.

**Storage.** The review ledger (`srv/reviewdesk.py`) gains a `fix` item per thread: `{thread, state: addressing|fixed, since: tip, sha, patchId, subject, how: next|picked}`.
- **Rewording or a rebase changes the sha but not the patch,** so the link follows the patch-id, then the subject.
- **A fix squashed away** shows "its fix commit is gone" rather than a stale sha.

**What stays as it is.**
- **Resolving stays GitHub's:** `R` opens the thread there.
- **The hankles gate stays:** today only replies on john-hankles threads leave the machine. A reply to nalanj stays a draft until that scope opens (`github-scope-all`).
- **Suggestion blocks keep `a`.**

**Decisions:**
1. **The key.** `a` stays "apply suggestion". The free letters that mean nothing on any page are `q y Y E H J M Q U V W Z`. Proposed: **`E`** (edit to address it).
2. **The adoption rule:** first new commit touching the thread's file, else the first new commit (proposed). Or always the first new commit, or always ask.
3. **The default reply:** "added in `<sha>`" (proposed), "done in `<sha>`", or the commit's subject.
4. **What happens without a commit:** if the edit turns out unnecessary, pressing the key again with no new commits offers "no change needed" as the reply. Proposed: yes.

**Build, once decided.** A `fix` item and its adoption in `reviewdesk` (adoption runs on the tip moving, which the review domain already sees each tick), tested on the fake GitHub. Then the thread and words displays, the command and its pick list, and the drafted reply.
