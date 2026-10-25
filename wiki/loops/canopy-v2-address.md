---
title: Address a thread with a commit
section: Canopy v2
order: 62
project: canopy-v2
lede: A review thread asks for a change; you say which commit makes it, the commit carries that link in its own message, both ends show it, and the reply naming it is drafted to go out with the push. Decided 2026-10-25.
---

**Today.** `a` only applies a GitHub suggestion block. For a plain question, say nalanj on #11132 at `queries/sending-domain.test.ts:599`, asking "should this test ensure the sending domain is enabled after the function is called?", the path is: `o` into Helix, commit there, come back, `r`, and type the sha by hand. Nothing ties the commit to the thread.

**The link is declared, and it lives in the commit.** A commit that addresses a thread carries a trailer naming it by the URL of the thread's first comment:

```
add the enabled check to the re-enable test

Addresses: https://github.com/Loops-so/loops/pull/11132#discussion_r2456789
```

- **Nothing is guessed.** You say which commit fixes which thread, either typed in the message yourself or set by `E`'s pick.
- **It's durable:** rewording, rebasing and restacking carry the message, so the link follows the commit with no patch-id matching.
- **It's readable:** on the PR's commits tab the trailer is a link back to the conversation.
- **It never reaches main:** the squash takes the PR's title and body, not commit messages.
- **One commit can address several threads** (several trailer lines), **and one thread can be addressed by several commits.**

**`E` on a thread:**
1. **First press:** opens the thread's spot in Helix (as `o` does) and marks the thread as being addressed. Nothing is linked yet.
2. **Back in the viewer, `E` again:** lists the branch's unpushed commits, newest first. Picking one adds the trailer to that commit through the words' guarded rewrite (`/outline`: same tree, refuses if the branch moved, `u` undoes).
3. **With no commit to pick,** `E` just cancels. Write the reply with `r`.
4. **A pushed commit can't take a trailer** without force-pushing, so it isn't offered. Address in a new commit.

**Shown on both ends,** read from the trailers of the branch's own commits:
- **The thread:** "addressed by `abc1234` — add the enabled check".
- **The commit in the words (`e`):** "addresses nalanj on sending-domain.test.ts:599" in place of the raw trailer line.

The existing "addressed by `<sha>`?" hint, a commit that changed the thread's lines, stays a question until a trailer declares it.

**The reply.** Picking drafts a reply in the ledger, **"done in `<sha>`"**, editable like any draft.
- **Its sha is filled in when it sends,** from whichever commit carries the trailer then. A reword or rebase between drafting and pushing can't leave it naming a sha that no longer exists.
- **It waits for that commit to be on GitHub,** as replies already do, so it goes out with the push.
- **The hankles gate still applies:** for now only replies on john-hankles threads leave the machine, so a reply to nalanj stays a draft until `github-scope-all`.

**Decided** (Phil, 2026-10-25):
1. The key is `E`; `a` stays "apply suggestion".
2. Declarative, not implicit: the trailer in the commit is the link, chosen over a pick stored in the ledger.
3. The reply is "done in `<sha>`".
4. No "no change needed" offer; with no commit, `E` cancels.

**Build.**
1. `review/diff.ts`-style pure helpers: parse and add `Addresses:` trailers. Test: several per commit, kept through a reword of the subject.
2. Server: the review domain's thread entity gains `fixedBy` ({sha, subject}) from the trailers of the branch's own commits (`srv/reviewdesk.py`). A reply draft can name `{fix}`, resolved at send.
3. Client: `E` (open + mark, then pick list), the thread and words displays, the drafted reply.
