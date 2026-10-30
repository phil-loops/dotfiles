---
name: branch-deck
description: Turn a forest's branches into a Show deck with one page per branch, each showing the branch's kernel (the one idea or invariant it adds), what it changes, and the picture that explains it best (a mockup, a before/after, a data shape, a sample query result). Use when Phil asks to "see the branches in Show", "show me what each PR is", "represent this branch", or wants to review a forest by its ideas instead of its diffs.
---

# branch-deck — a forest read by its kernels

Phil reviews by kernels, invariants, mockups and vision, not by diffs (memory `review-by-kernels-not-diffs`). This recipe turns each branch into one Show page that a reviewer can sign off on without opening the code. Deck format and launching: the `show` skill.

## 1 · Scan each branch

For every branch in `stack-merge-rank <project>` order, read the whole `parent...branch` diff (not just the stat) and the branch description. Write down:

- **Kernel**: the one idea this branch makes true, in a sentence. If you need "and", the branch is two ideas (forests.md); say so on the page rather than hiding it.
- **Adds / changes / removes**: concretely, in reader terms (a new hourly row shape, a page section replaced), not file names.
- **Behavior change**: anything a user, reviewer or caller sees differently, including what silently stops happening. Check what the old code filtered or defaulted. That's where false claims hide.
- **Holds because**: what would break the kernel, and what keeps it from breaking (a test, a type, a constraint).

## 2 · Pick the picture by band

The picture is the page's main content. Choose the one that explains the branch fastest:

| Band | Best picture |
|---|---|
| query | a few input rows → the rows it returns (a small table pair), using the test's own example |
| model | the shape it returns, filled with one realistic example, plus the rule it applies |
| wiring / endpoint | the response before → after, as JSON |
| UI | an ASCII mockup of the screen, before and after, at the size it really renders |
| cleanup | what's deleted, and who reads the remaining pieces (proof nothing's orphaned) |
| migration / schema | the table as it will exist, plus the invariant the constraints enforce |

ASCII mockups go in fenced code blocks (monospaced). Use real units and labels from the code, such as its copy strings and rate denominators. Draw from the code, not from memory.

When a UI branch has a running preview, add a `url` section pointing at it right after the mockup page.

## 3 · Lay out the deck

- One opening page: the forest as a merge story (one line per branch, `↳` for children), plus the vision line the forest serves.
- One page per branch, in merge order. `group` = the band, `title` = the branch's plain subject, `tag` = the branch name and `+adds/−removes`. Id = the branch name, so sign-offs map 1:1 to branches.
- Each page body, in order: **Kernel** (one sentence, as a `>` quote), the picture, **Changes** (2–4 bullets), **Holds because** (one line), **Watch for** (anything a reviewer should press on, or nothing).
- Set `replyTo` to this session so Submit reaches you.
- Show's Forest workspace reads the deck without shelling out to git, so the deck carries the forest itself. At the top level, set `"mode": "forest"`, `"project": "<stack-project>"` and `"repo": "<repo name, e.g. loops>"`. On each branch section, set `"rank"` (from `stack-merge-rank <project>` JSON `.rank`) and `"parent"` (from `git config branch.<b>.stack-parent`). Also set `"sha"` (`git rev-parse <branch>` when the page is written); Show marks the page as moved when the tip changes. Read all three when you generate the deck, never from memory. Sections that aren't branches (the overview, live pages) carry none of them.
- Answering Show: a `regenerate page <branch> — <deck>` message means rewrite that one section from the branch's current tip, keeping its id, and refresh its `sha`, `rank` and `parent`. A `Show thread:` message is answered per the show skill's *Threads* section.
- Write with a generator script in the scratchpad, output to `~/.dotfiles/show/<project>-branches.json`, then `show` it.

## 4 · After sign-off

Phil can also talk back per page: a `Show thread: …` or `regenerate page <branch>` line means reply per the show skill's **Threads** section (`<deck>.thread.json`).


A note on a branch page is review feedback on that branch. Fix it on that branch (new commit), regenerate the page, and the open deck reloads by itself.
