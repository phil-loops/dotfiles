# Canopy around the branch

*2026-11-25 · draft for Phil · nothing built*

## The problem

Canopy has grown a workspace per feature (Canopy, Learn, Machine, Inbox, Plans, Bench on the rail; Forest,
Review, Runs routed), and they don't hand off to each other. Phil: "a whole bunch of stuff going on… it feels
like it's not really clicking… not cohesive, not seamlessly moving between each other."

## What's actually used

`events.jsonl`, 2026-10-31 → 11-25, documents Phil opened vs. ones sessions sent:

| Workspace | Opened | Arrived | Last |
|---|---|---|---|
| Canopy (branch `/v2/b` 779, forest `/v2/p` 770, home 239) | **1790** | 73 | today |
| Review (decks) | 67 | 30 | 11-24 |
| Inbox | 27 | **68** | today |
| Forest | 5 | 11 | 11-17 |
| Plans | 4 | 3 | 11-08 |
| Learn | 3 | 0 | 11-24 |
| Runs | 1 | 0 | 11-04 |
| Machine, Bench | — | — | never logged |

The branch and forest pages are the product. Sessions talk to Phil through the Inbox far more than he reads it.

## The principle

**The branch is the unit of navigation; everything about a branch is on its page or one key from it.** A
feature earns a place by attaching to a branch (or a forest), not by owning a workspace. Corollary: a message,
a deck or a run that concerns a branch arrives *on that branch* — never in a place Phil has to go and check.

## The target

One window, Canopy (with Learn and Machine still on the rail), with three levels Phil already navigates: **home → forest → branch.** On a branch page:

- **What changed** — the diff and review (today's page).
- **What sessions said** — the messages, decks and evidence a session filed for this branch, newest first,
  unread marked. Replaces the Inbox for anything branch-scoped.
- **Who's working on it** — the tmux pane on this branch, one key away (Ctrl-Space today; GitHub's ⌃⇧O lands
  there too).
- **Spoken review** — already built this way (wt-121940): ⌘⇧R records, notes are filed per branch/file under
  the commit on screen and delivered to the forest's owner session; the owner's reply pins up to five
  attention items per forest (`stack-attention.json`), which the canopy owner renders as one word per row on
  the forest page (`]d` to the next) and as a four-part card on the branch page. That card is the template for
  everything else a session says about a branch.

Home keeps the cross-branch view: what's waiting on Phil, by forest, with the unread count per branch replaced
by a single quiet mark (no counts).

## Fate of each surface

| Surface | Fate |
|---|---|
| Canopy | stays — becomes the main workspace |
| Inbox | branch-scoped messages move onto their branch; the rest (no branch) shows on home; the tab goes |
| Review decks | open in place on their branch; the Review workspace goes |
| Forest decks | open on the forest page; the Forest workspace goes |
| Plans, Runs | retire (4 and 1 opens); a run that belongs to a branch shows on it |
| Learn | stays on the rail for now (Phil, 11-25) |
| Machine | stays on the rail for now (Phil, 11-25) |
| Bench | retires (Phil, 11-25) |

## How it would land

Dark-additive first: (1) messages and decks carry the branch they concern (most already link one);
(2) the branch page shows them; (3) home shows the branch-less rest; (4) keystone — the rail loses the
workspaces the branch page replaced. Each step is its own branch; 1–3 change nothing visible until 4.

Status: (1) landed 11-25 as `show-note --branch <repo>/<branch> | --forest <repo>/<project>` → the message's
`about` field (fce0f06c); wt-121940 moves spoken review onto it. (2) — canopy's pages reading `about` — is next.

## Messages with no branch

Phil (11-25): these shouldn't be prominent. Proposal: the Dock icon's badge is their only signal (one quiet
mark, no count), and they sit at the foot of home, read in place. Nothing interrupts a branch page for them.
Not settled — revisit once branch-scoped messages have moved and it's clear how many are left.

## Open questions for Phil

1. Does Canopy stay one window, or should the branch page open as its own window per branch? (Default: one
   window.)

## Coordination

Synced with wt-121940 (Show lane, spoken review) on 2026-11-25 — no conflict, same direction: review replies
already left the Inbox for the branch and forest pages, with the Inbox kept as a record plus one notification.
Folded in from that sync:

- The spoken-review notes and the reply still post an Inbox message. Under this model they become the branch
  page's record, and the one notification deep-links to the forest page.
- ⌘⇧R is a Show menu binding scoped to the Canopy workspace; when the rail collapses into canopy, the key moves
  into canopy's own keymap.
- Scope Phil set for spoken review holds here too: delivery to the owner, one verdict notification, marks and
  items in canopy — no threads, approvals or per-note bookkeeping.

Code owners: Show lane (wt-121940) for the rail and routing; canopy owner (6e455e9a) for the forest and
branch pages.
