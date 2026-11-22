---
name: closeup
description: Close out this Claude session — check nothing is left outstanding (uncommitted work, claimed tracker items, unlanded patches, running background tasks, questions or offers still waiting on Phil), and if it's all clear, close this session's tmux pane. Use when Phil says "/closeup", "close up", "wrap up and close", or "are we done here? close the pane". If anything is outstanding it lists it and leaves the pane open.
disable-model-invocation: true
---

# Closeup — done? then close the pane

Closing the pane ends this session, so it only happens when every check below comes back clean.
Any doubt → list it and stop; Phil decides.

## 1 · What's on disk

```bash
~/.dotfiles/scripts/closeup check
```

It reports uncommitted changes in this session's checkout, dirty files inside the dotfiles lanes
this session holds, canopy-todo items it still has `doing`, and patches written since it started
that haven't landed. Exit 1 = something's outstanding.

It then prints a **handoffs table**: every branch this session made, with local vs origin SHA,
open PR, gates verdict and a status (`not pushed`, `N commit(s) to push`, `pushed, nothing to
push`, `diverged`…), all read at that moment. The table never changes the exit code.

## 2 · What only the conversation knows

Go over this session yourself — the script can't see these:

- **Background work still running**: Bash tasks, subagents, gates you started and haven't seen finish.
- **Waiting on Phil**: a question you asked, an offer you made ("want me to…?"), a choice left open.
- **Promised and not done**: a follow-up you said you'd do, a result you haven't relayed.
- **Handoffs worth a line**: what Phil still has to push, post or run — these don't block
  closing, but name them so they aren't lost with the pane. **Branch state comes from the §1
  table, never from memory of earlier turns**: quote its status column, and leave a `pushed,
  nothing to push` branch out. A branch the table doesn't list gets a state only from a check run
  in the same turn. (2026-11-22: listed #11734's commits as "to push" from memory when they were
  already on origin.) Drafted text — PR bodies, review replies — still comes from the conversation.

## 3 · Decide

- **Anything from 1 or the first three bullets of 2** → don't close. List each item, one line
  apiece, with what it needs (finish it, or Phil's call). Stop.
- **All clear** → one short closing message (handoffs from 2, if any, branch state quoted from the
  §1 table — that's the last thing Phil reads from this pane), then:

```bash
~/.dotfiles/scripts/closeup close
```

It releases this session's `own` lanes and kills the session's own tmux pane a second later. It
refuses unless the pane's process is an ancestor of this session's claude process, so it can't
close another session's pane. Outside tmux it says so and closes nothing.
