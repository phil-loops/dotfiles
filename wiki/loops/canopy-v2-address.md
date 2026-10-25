---
title: Address a thread with a commit
section: Canopy v2
order: 62
project: canopy-v2
lede: A review thread asks for a change; you say which commit makes it, the commit carries that link in its own message, both ends show it, and the reply naming it is drafted to go out with the push. Built 2026-10-25.
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

**`E` on a thread opens a chooser.** Who writes the fix?
1. **Hand it to Claude** (`↵`/`c`, the main path). A fresh Claude opens in the branch's worktree (`stack-claude`, its own tmux window), with a prompt typed into its composer and **not sent**. The prompt carries the conversation, the second reader's note (verdict, evidence, elsewhere, cause), the branch, the `path:line`, and the instruction: one commit, a subject in your voice, the `Addresses:` trailer as its last line, no push, no GitHub reply. The reply is drafted at the same moment and waits until a commit declares the thread.
2. **Fix it yourself in Helix** (`o`). Opens the spot, as `o` does. Commit, then `E` again to pick it.
3. **Pick the commit** (`p`, then `1`–`9`). Lists the branch's unpushed commits, newest first. Picking one adds the trailer through the words' guarded rewrite (`/outline`: same tree, refuses if the branch moved) and drafts the reply. `u` takes both back.

A pushed commit can't take a trailer without force-pushing, so it isn't offered: address in a new commit. With nothing to pick, `esc` and write the reply with `r`.

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

**Built** (dotfiles, 2026-10-25; tested in `viewer-sandbox --github`, end to end through the push).
1. `srv/reviewdesk.py`: `add_trailer` and `fixes_between` (git parses the trailers). Tested in `test-review-threads`: several per commit, kept through a reword, your real fix `14adf15` as a fixture.
2. Server: the review domain's thread entity gains `fixedBy` ({sha, subject}) from the trailers of the branch's own commits (`srv/reviewdesk.py`). A reply draft can name `{fix}`, resolved at send.
3. Server: `POST /review-address` (trailer + reply in one step, undo; or `claude: true`, the handoff through `stack-claude` in draft mode).
4. Client: `E`'s chooser (`AddressSheet`), the thread and words displays, the reply's live sha.
